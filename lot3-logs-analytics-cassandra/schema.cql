-- =============================================================================
--  Refonte LDLC — Lot 3 : Logs de navigation et historique de commandes
--  (Apache Cassandra)
--  schema.cql — Keyspace, types et tables
--
--  Exécution :  cqlsh -f schema.cql
-- =============================================================================
--
--  Pourquoi Cassandra ?
--  --------------------
--  - Écritures massives et continues : chaque page vue, clic ou recherche
--    produit un événement → plusieurs millions d'écritures par jour, avec des
--    pics (soldes, Black Friday). Cassandra écrit en append-only (commit log
--    + memtable), sans lecture préalable : le débit d'écriture croît
--    linéairement en ajoutant des nœuds.
--  - Rétention longue (mois / années) sur des volumes qui ne tiennent pas sur
--    un seul serveur : données réparties sur l'anneau par la partition key.
--  - Pas de maître : un nœud qui tombe ne bloque ni les écritures ni les
--    lectures (réplication RF = 3, niveau de cohérence réglable).
--
--  Méthode : modélisation PILOTÉE PAR LES REQUÊTES (query-driven)
--  ---------------------------------------------------------------
--  Cassandra n'a ni jointure ni GROUP BY libre : on part des requêtes de
--  l'application et on crée UNE TABLE PAR REQUÊTE, quitte à dupliquer les
--  données (le stockage est bon marché, les lectures doivent toucher UNE
--  seule partition).
--
--    Requête                                         Table
--    ----------------------------------------------  ---------------------------
--    Rejouer / analyser les événements d'une heure   events_by_hour
--    « Combien de vues pour ce produit aujourd'hui ? »  product_views_by_day
--    Compteurs de tous les produits pour un jour      daily_product_views
--    Statistiques globales du site par jour           daily_site_stats
--    « Top des produits vus cette semaine ? »         top_products_by_week
--    « Historique de commandes d'un client »          orders_by_customer
--    « Détail d'une commande (n° de commande) »       orders_by_id
--
--  Règles de dimensionnement d'une partition (repères usuels) :
--    < 100 Mo et < 100 000 lignes, sans « partition chaude » qui
--    concentrerait les écritures sur 3 nœuds seulement.
--
--  Hypothèses de volume :
--    ~10 M visites/mois ≈ 330 000 visites/jour × ~15 événements
--    ≈ 5 M événements/jour en moyenne ; heure de pointe ≈ 10 % du jour
--    ≈ 500 000 événements/h ; Black Friday ≈ ×4 → 2 M événements/h.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  Keyspace
-- -----------------------------------------------------------------------------
--  NetworkTopologyStrategy : stratégie de production (sensible aux racks et
--  datacenters). RF = 3 : on tolère la perte d'un nœud en lisant/écrivant en
--  LOCAL_QUORUM (2 réplicas sur 3).
--  Sur un nœud unique de TP, cqlsh (cohérence ONE par défaut) fonctionne
--  quand même ; on peut aussi mettre 'datacenter1': 1.
CREATE KEYSPACE IF NOT EXISTS ldlc_analytics
  WITH replication = { 'class': 'NetworkTopologyStrategy', 'datacenter1': 3 }
  AND durable_writes = true;

USE ldlc_analytics;

-- =============================================================================
--  1. ÉVÉNEMENTS BRUTS — events_by_hour
-- =============================================================================
--  Usage : écriture de chaque événement ; lecture séquentielle d'une heure
--  complète par les jobs d'agrégation (Spark) et pour les investigations.
--
--  Partition key : (bucket_hour, shard)
--    - bucket_hour : l'horodatage tronqué à l'heure. Partitionner par
--      période borne la taille de la partition (elle ne grossit plus une
--      fois l'heure écoulée) et regroupe les données qui expirent ensemble.
--    - shard (0 à 15) : sans lui, TOUTES les écritures d'une heure iraient
--      sur une seule partition, donc sur les 3 mêmes nœuds (partition
--      chaude) pendant que le reste du cluster ne fait rien. Le shard est
--      calculé par l'application : hash(session_id) % 16. Les 16 partitions
--      d'une heure se répartissent sur tout l'anneau.
--      Contrepartie : lire une heure = 16 lectures (lancées en parallèle).
--
--  Clustering column : event_id (timeuuid, DESC)
--    - timeuuid = horodatage + unicité : deux événements à la même
--      milliseconde ne s'écrasent pas (une clé primaire Cassandra identique
--      = un UPSERT silencieux).
--    - DESC : les événements les plus récents en premier ; les tranches de
--      temps se lisent avec minTimeuuid()/maxTimeuuid().
--
--  Taille d'une partition :
--    heure normale  : 500 000 / 16 ≈ 31 000 lignes × ~400 o ≈ 12 Mo
--    Black Friday   : 2 M / 16     ≈ 125 000 lignes × ~400 o ≈ 50 Mo
--    → sous la barre des 100 Mo même en pic. Au-delà, on passerait à 32 shards.
--
--  Rétention : TTL de 13 mois (34 128 000 s), durée maximale recommandée
--  par la CNIL pour les données de mesure d'audience. Ce qu'on garde plus
--  longtemps, ce sont les AGRÉGATS anonymes (tables de compteurs).
--
--  Compaction : TimeWindowCompactionStrategy (TWCS), fenêtres d'1 jour.
--    Les données arrivent dans l'ordre chronologique et ne sont jamais
--    modifiées : TWCS ne compacte ensemble que les SSTables d'une même
--    journée. Quand toute une journée a expiré, la SSTable entière est
--    supprimée d'un coup, sans réécriture ni tombstones à purger une à une.
--    Corollaire : AUCUN DELETE ni UPDATE sur cette table, seulement le TTL.
--  gc_grace_seconds réduit à 3 h : pas de suppression explicite, donc pas de
--  risque de « résurrection » de données ; les SSTables expirées sont
--  libérées plus tôt. (Doit rester ≥ max_hint_window, 3 h par défaut.)
CREATE TABLE IF NOT EXISTS events_by_hour (
    bucket_hour   timestamp,      -- ex. '2026-11-18 14:00:00+0000'
    shard         tinyint,        -- 0..15 = hash(session_id) % 16
    event_id      timeuuid,
    event_type    text,           -- 'page_view' | 'click' | 'search' | 'add_to_cart'
    session_id    text,           -- même sid que la session Redis (lot 2)
    customer_id   text,           -- 'user:42' si connecté, sinon null
    sku           text,           -- produit concerné (SKU du catalogue, lot 1)
    page_url      text,
    referrer      text,
    search_query  text,           -- renseigné pour event_type = 'search'
    results_count int,
    element       text,           -- élément cliqué pour event_type = 'click'
    device        text,           -- 'desktop' | 'mobile' | 'tablet'
    user_agent    text,
    PRIMARY KEY ((bucket_hour, shard), event_id)
) WITH CLUSTERING ORDER BY (event_id DESC)
  AND default_time_to_live = 34128000
  AND gc_grace_seconds = 10800
  AND compaction = {
        'class': 'TimeWindowCompactionStrategy',
        'compaction_window_unit': 'DAYS',
        'compaction_window_size': 1
      }
  AND comment = 'Événements de navigation bruts, 13 mois';

-- =============================================================================
--  2. COMPTEURS — vues par produit et par jour
-- =============================================================================
--  Les tables de type COUNTER ne contiennent que des clés et des colonnes
--  counter, incrémentées par UPDATE ... SET c = c + n (pas d'INSERT, pas de TTL).
--  Les incréments ne sont pas idempotents (un retry peut compter deux fois) :
--  acceptable pour des statistiques ; les chiffres exacts peuvent toujours être
--  recalculés à partir des événements bruts.
--  Pour limiter le nombre d'écritures, le consumer d'ingestion (Kafka)
--  agrège les incréments par minute : un « + 37 » au lieu de 37 « + 1 ».

-- --- 2a. « Combien de vues pour ce produit aujourd'hui ? » --------------------
--  Partition key : sku → toutes les journées d'un produit dans la même
--  partition : « aujourd'hui », « 7 derniers jours » ou « 30 derniers
--  jours » se lisent en UNE requête sur une seule partition.
--  Clustering column : day DESC → les jours récents d'abord, tranches de
--  dates possibles (day >= ...).
--  Taille : 1 ligne par jour → 365 lignes/an × ~50 o ≈ 18 Ko/an. Même après
--  10 ans, la partition reste minuscule.
CREATE TABLE IF NOT EXISTS product_views_by_day (
    sku          text,
    day          date,
    views        counter,
    clicks       counter,
    add_to_cart  counter,
    PRIMARY KEY ((sku), day)
) WITH CLUSTERING ORDER BY (day DESC)
  AND comment = 'Compteurs quotidiens par produit, conservés sans limite';

-- --- 2b. Compteurs de TOUS les produits pour un jour ---------------------------
--  Usage : source du calcul du top hebdomadaire (job nocturne) et des
--  tableaux de bord « produits vus aujourd'hui ».
--  Partition key : (day, shard) — le jour seul ferait une partition CHAUDE :
--  toutes les vues du site d'une journée incrémenteraient la même partition
--  (3 nœuds). shard = hash(sku) % 8 répartit la charge sur 8 partitions.
--  Clustering column : sku → une ligne par produit.
--  Taille : 27 000 produits / 8 ≈ 3 400 lignes par partition, ~200 Ko.
CREATE TABLE IF NOT EXISTS daily_product_views (
    day     date,
    shard   tinyint,              -- 0..7 = hash(sku) % 8
    sku     text,
    views   counter,
    PRIMARY KEY ((day, shard), sku)
) WITH comment = 'Vues de chaque produit pour un jour, réparties sur 8 shards';

-- --- 2c. Statistiques globales du site par jour -------------------------------
--  Partition key : day ; clustering : event_type (4 à 10 lignes par jour).
--  Volume d'écriture élevé sur une petite partition : grâce à la
--  pré-agrégation par minute du consumer, c'est ~1 incrément/min/type.
CREATE TABLE IF NOT EXISTS daily_site_stats (
    day         date,
    event_type  text,
    total       counter,
    PRIMARY KEY ((day), event_type)
) WITH comment = 'Nombre d''événements par type et par jour';

-- =============================================================================
--  3. TOP DES PRODUITS DE LA SEMAINE — top_products_by_week (pré-calculé)
-- =============================================================================
--  Cassandra ne sait pas trier par la valeur d'un compteur ni faire de
--  GROUP BY sur 7 jours × 27 000 produits à la volée. Le classement est donc
--  CALCULÉ par un job nocturne (Spark ou script) à partir de
--  daily_product_views (7 jours × 8 shards = 56 lectures de partition), puis
--  écrit déjà trié dans cette table. Le site ne fait qu'une lecture.
--
--  Partition key : (week, category_id)
--    - week : semaine ISO, ex. '2026-W47' ;
--    - category_id : 'all' pour le top global, sinon un id de catégorie du
--      lot 1 ('processeurs', 'cartes-graphiques'...) → un top par rayon.
--  Clustering column : rank ASC → la lecture renvoie directement le
--  classement dans l'ordre ; LIMIT 10 = top 10.
--  Taille : 100 lignes par partition (top 100) → quelques Ko.
--  Le job réécrit la semaine en cours chaque nuit : même clé primaire =
--  écrasement (upsert), aucune suppression nécessaire.
--  Les données dénormalisées (name, brand) évitent un appel au catalogue.
CREATE TABLE IF NOT EXISTS top_products_by_week (
    week          text,
    category_id   text,
    rank          int,
    sku           text,
    name          text,
    brand         text,
    views         bigint,
    computed_at   timestamp,
    PRIMARY KEY ((week, category_id), rank)
) WITH CLUSTERING ORDER BY (rank ASC)
  AND comment = 'Classement hebdomadaire pré-calculé par un job nocturne';

-- =============================================================================
--  4. COMMANDES — types utilisateur (UDT)
-- =============================================================================
--  Une ligne de commande est une « photo » au moment de l'achat : nom et prix
--  FIGÉS (le prix du catalogue peut changer ensuite, la facture non).
--  frozen<…> : la valeur est sérialisée comme un bloc unique, lue et écrite
--  en entier. C'est exactement le cas d'une ligne de commande, immuable une
--  fois la commande passée.
CREATE TYPE IF NOT EXISTS order_line (
    sku         text,
    name        text,
    unit_price  decimal,
    quantity    int,
    line_total  decimal
);

CREATE TYPE IF NOT EXISTS postal_address (
    recipient    text,
    street       text,
    postal_code  text,
    city         text,
    country      text
);

-- =============================================================================
--  5. « Historique de commandes d'un client » — orders_by_customer
-- =============================================================================
--  Partition key : customer_id → tout l'historique d'un client dans une
--  seule partition : la page « Mes commandes » = 1 lecture.
--  Clustering columns : (order_date DESC, order_id ASC)
--    - order_date DESC : les commandes les plus récentes d'abord, pagination
--      naturelle (LIMIT 20, puis order_date < dernière date affichée) ;
--    - order_id : départage deux commandes passées à la même milliseconde
--      et rend la clé primaire unique.
--  Taille : un particulier passe quelques commandes par an ; même un compte
--  professionnel à 2 000 commandes × ~2 Ko ≈ 4 Mo. Pour d'éventuels très
--  gros comptes B2B, on ajouterait l'année à la partition key
--  ((customer_id, year)).
--  Rétention : PAS de TTL. Les commandes sont des pièces comptables, à
--  conserver 10 ans (Code de commerce) ; l'archivage se fait par un job.
--  Compaction : LeveledCompactionStrategy, adaptée aux tables lues souvent
--  et dont les lignes sont mises à jour (changement de statut) : une ligne
--  est lue dans un minimum de SSTables.
CREATE TABLE IF NOT EXISTS orders_by_customer (
    customer_id       text,
    order_date        timestamp,
    order_id          text,
    status            text,                 -- 'payee' | 'preparation' | 'expediee' | 'livree' | 'annulee'
    total_amount      decimal,
    shipping_fee      decimal,
    currency          text,
    items_count       int,
    lines             list<frozen<order_line>>,
    shipping_address  frozen<postal_address>,
    carrier           text,
    tracking_number   text,
    PRIMARY KEY ((customer_id), order_date, order_id)
) WITH CLUSTERING ORDER BY (order_date DESC, order_id ASC)
  AND compaction = { 'class': 'LeveledCompactionStrategy' }
  AND comment = 'Historique des commandes par client (page Mes commandes)';

-- =============================================================================
--  6. « Détail d'une commande » — orders_by_id
-- =============================================================================
--  Même donnée que ci-dessus, organisée pour une autre requête : accès par le
--  numéro de commande (service client, suivi de colis, liens dans les e-mails).
--  Partition key : order_id seul → partition d'UNE ligne, répartition
--  parfaite sur l'anneau ; 25 000 commandes/jour ≈ 9 M lignes/an sans
--  aucune partition chaude.
--  customer_id et order_date y sont stockés : ils servent à retrouver la
--  ligne correspondante dans orders_by_customer lors d'un changement de
--  statut (voir le BATCH dans queries.cql).
CREATE TABLE IF NOT EXISTS orders_by_id (
    order_id          text,
    customer_id       text,
    order_date        timestamp,
    status            text,
    total_amount      decimal,
    shipping_fee      decimal,
    currency          text,
    items_count       int,
    lines             list<frozen<order_line>>,
    shipping_address  frozen<postal_address>,
    billing_address   frozen<postal_address>,
    payment_method    text,
    carrier           text,
    tracking_number   text,
    PRIMARY KEY ((order_id))
) WITH compaction = { 'class': 'LeveledCompactionStrategy' }
  AND comment = 'Commande complète, accès par numéro';
