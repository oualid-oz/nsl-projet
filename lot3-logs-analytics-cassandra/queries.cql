-- =============================================================================
--  Refonte LDLC — Lot 3 : Logs de navigation et historique de commandes
--  (Apache Cassandra)
--  queries.cql — Écritures types (jeu d'essai) et requêtes de lecture
--
--  Exécution (après schema.cql) :  cqlsh -f queries.cql
--
--  Les SKU sont ceux du catalogue (lot 1), les identifiants de session et de
--  client ceux du lot 2 (sess:{sid}, user:42).
--  « Aujourd'hui » = 2026-11-18, semaine ISO 2026-W47.
--
--  Attention : les compteurs ne sont pas idempotents. Relancer ce fichier
--  ADDITIONNE à nouveau les incréments ; pour repartir de zéro, relancer
--  d'abord : DROP KEYSPACE ldlc_analytics;  puis schema.cql.
-- =============================================================================

USE ldlc_analytics;

-- =============================================================================
--  PARTIE A — ÉCRITURES (ce que fait le pipeline d'ingestion)
-- =============================================================================

-- -----------------------------------------------------------------------------
--  A1. Événements bruts
-- -----------------------------------------------------------------------------
--  L'application calcule bucket_hour (heure tronquée) et shard
--  (hash(session_id) % 16), et génère le timeuuid. Ici now() pour la démo.
--  Le TTL de 13 mois est appliqué automatiquement (default_time_to_live).
INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, customer_id, sku, page_url, referrer, device)
VALUES ('2026-11-18 14:00:00+0000', 3, now(), 'page_view', 'f3a9c2e1b7d84e0c9a6b5d4c3e2f1a0b', 'user:42',
        'CPU-AMD-R7-7800X3D', '/fiche/CPU-AMD-R7-7800X3D.html', 'https://www.google.fr/', 'desktop');

INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, customer_id, search_query, results_count, page_url, device)
VALUES ('2026-11-18 14:00:00+0000', 3, now(), 'search', 'f3a9c2e1b7d84e0c9a6b5d4c3e2f1a0b', 'user:42',
        'carte mere am5 ddr5', 42, '/recherche/carte%20mere%20am5%20ddr5', 'desktop');

INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, customer_id, sku, page_url, element, device)
VALUES ('2026-11-18 14:00:00+0000', 3, now(), 'click', 'f3a9c2e1b7d84e0c9a6b5d4c3e2f1a0b', 'user:42',
        'CM-ASUS-B650A-WIFI', '/informatique/composants/cartes-meres.html', 'carte-produit', 'desktop');

INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, customer_id, sku, page_url, element, device)
VALUES ('2026-11-18 14:00:00+0000', 3, now(), 'add_to_cart', 'f3a9c2e1b7d84e0c9a6b5d4c3e2f1a0b', 'user:42',
        'CM-ASUS-B650A-WIFI', '/fiche/CM-ASUS-B650A-WIFI.html', 'bouton-ajout-panier', 'desktop');

-- Visiteur anonyme sur mobile, autre shard
INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, sku, page_url, referrer, device)
VALUES ('2026-11-18 14:00:00+0000', 11, now(), 'page_view', '7b2e9d0c4a1f48e3b6c5d8a7e9f0b1c2',
        'GPU-ASUS-RTX4070S-12', '/fiche/GPU-ASUS-RTX4070S-12.html', 'https://www.ldlc.com/', 'mobile');

-- Écriture explicite avec un TTL plus court (ex. événements de debug : 7 jours)
INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, page_url, device)
VALUES ('2026-11-18 14:00:00+0000', 11, now(), 'page_view', '7b2e9d0c4a1f48e3b6c5d8a7e9f0b1c2', '/debug/healthcheck', 'bot')
USING TTL 604800;

-- -----------------------------------------------------------------------------
--  A2. Compteurs (incréments pré-agrégés par minute par le consumer)
-- -----------------------------------------------------------------------------
--  Vues par produit et par jour (table de la requête « vues aujourd'hui »)
UPDATE product_views_by_day SET views = views + 1840, clicks = clicks + 212, add_to_cart = add_to_cart + 97
 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day = '2026-11-18';
UPDATE product_views_by_day SET views = views + 2310, clicks = clicks + 260, add_to_cart = add_to_cart + 88
 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day = '2026-11-17';
UPDATE product_views_by_day SET views = views + 2075, clicks = clicks + 231, add_to_cart = add_to_cart + 91
 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day = '2026-11-16';
UPDATE product_views_by_day SET views = views + 1502, clicks = clicks + 170, add_to_cart = add_to_cart + 64
 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day = '2026-11-12';
UPDATE product_views_by_day SET views = views + 1 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day = '2026-11-18';

UPDATE product_views_by_day SET views = views + 3120, clicks = clicks + 405, add_to_cart = add_to_cart + 75
 WHERE sku = 'GPU-ASUS-RTX4070S-12' AND day = '2026-11-18';
UPDATE product_views_by_day SET views = views + 960, clicks = clicks + 101, add_to_cart = add_to_cart + 58
 WHERE sku = 'CM-ASUS-B650A-WIFI' AND day = '2026-11-18';

--  Même événement, autre table (une table par requête = une écriture par table).
--  shard = hash(sku) % 8, calculé par l'application.
UPDATE daily_product_views SET views = views + 1841 WHERE day = '2026-11-18' AND shard = 3 AND sku = 'CPU-AMD-R7-7800X3D';
UPDATE daily_product_views SET views = views + 3120 WHERE day = '2026-11-18' AND shard = 5 AND sku = 'GPU-ASUS-RTX4070S-12';
UPDATE daily_product_views SET views = views + 960  WHERE day = '2026-11-18' AND shard = 6 AND sku = 'CM-ASUS-B650A-WIFI';
UPDATE daily_product_views SET views = views + 1415 WHERE day = '2026-11-18' AND shard = 1 AND sku = 'RAM-CORSAIR-DDR5-32-6000';
UPDATE daily_product_views SET views = views + 1270 WHERE day = '2026-11-18' AND shard = 2 AND sku = 'CPU-AMD-R5-7600X';
UPDATE daily_product_views SET views = views + 690  WHERE day = '2026-11-18' AND shard = 0 AND sku = 'BOI-FRACTAL-NORTH';

--  Statistiques globales
UPDATE daily_site_stats SET total = total + 5123400 WHERE day = '2026-11-18' AND event_type = 'page_view';
UPDATE daily_site_stats SET total = total + 1987200 WHERE day = '2026-11-18' AND event_type = 'click';
UPDATE daily_site_stats SET total = total + 402800  WHERE day = '2026-11-18' AND event_type = 'search';
UPDATE daily_site_stats SET total = total + 118900  WHERE day = '2026-11-18' AND event_type = 'add_to_cart';

-- -----------------------------------------------------------------------------
--  A3. Top hebdomadaire (écrit par le job nocturne, déjà trié)
-- -----------------------------------------------------------------------------
--  Le job lit daily_product_views sur les 7 jours de la semaine (8 shards
--  par jour), additionne les vues par SKU, trie, puis écrit le top 100.
--  Réécrire la même (week, category_id, rank) écrase l'ancienne valeur.
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'all', 1, 'GPU-ASUS-RTX4070S-12', 'ASUS Dual GeForce RTX 4070 SUPER OC Edition 12 Go', 'ASUS', 21480, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'all', 2, 'CPU-AMD-R7-7800X3D', 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)', 'AMD', 14790, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'all', 3, 'RAM-CORSAIR-DDR5-32-6000', 'Corsair Vengeance DDR5 32 Go (2 x 16 Go) 6000 MHz CL30', 'Corsair', 9935, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'all', 4, 'CPU-AMD-R5-7600X', 'AMD Ryzen 5 7600X (4.7 GHz / 5.3 GHz)', 'AMD', 8810, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'all', 5, 'CM-ASUS-B650A-WIFI', 'ASUS ROG STRIX B650-A GAMING WIFI', 'ASUS', 6720, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'all', 6, 'BOI-FRACTAL-NORTH', 'Fractal Design North Charcoal Black TG Dark', 'Fractal Design', 4830, '2026-11-18 03:00:00+0000');

--  Top par rayon : même table, autre category_id
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'processeurs', 1, 'CPU-AMD-R7-7800X3D', 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)', 'AMD', 14790, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'processeurs', 2, 'CPU-AMD-R5-7600X', 'AMD Ryzen 5 7600X (4.7 GHz / 5.3 GHz)', 'AMD', 8810, '2026-11-18 03:00:00+0000');
INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
VALUES ('2026-W47', 'processeurs', 3, 'CPU-INTEL-I5-14600K', 'Intel Core i5-14600K (3.5 GHz / 5.3 GHz)', 'Intel', 3650, '2026-11-18 03:00:00+0000');

-- -----------------------------------------------------------------------------
--  A4. Commandes — écriture dans les DEUX tables
-- -----------------------------------------------------------------------------
--  orders_by_customer et orders_by_id contiennent la même commande. Un BATCH
--  LOGGED garantit que les deux insertions finissent par être appliquées
--  toutes les deux (atomicité, pas isolation) même si le coordinateur tombe.
--  C'est le bon usage d'un batch : cohérence entre tables dénormalisées,
--  PAS l'optimisation de performances (un batch multi-partitions est plus lent).

BEGIN BATCH
  INSERT INTO orders_by_customer (customer_id, order_date, order_id, status, total_amount, shipping_fee, currency, items_count, lines, shipping_address, carrier, tracking_number)
  VALUES ('user:42', '2026-11-02 18:42:10+0000', 'LD2611020042', 'livree', 396.90, 6.95, 'EUR', 1,
          [ { sku: 'CPU-AMD-R7-7800X3D', name: 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)', unit_price: 389.95, quantity: 1, line_total: 389.95 } ],
          { recipient: 'Client 42', street: '12 rue de la République', postal_code: '69002', city: 'Lyon', country: 'FR' },
          'Colissimo', '6A12345678901');
  INSERT INTO orders_by_id (order_id, customer_id, order_date, status, total_amount, shipping_fee, currency, items_count, lines, shipping_address, billing_address, payment_method, carrier, tracking_number)
  VALUES ('LD2611020042', 'user:42', '2026-11-02 18:42:10+0000', 'livree', 396.90, 6.95, 'EUR', 1,
          [ { sku: 'CPU-AMD-R7-7800X3D', name: 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)', unit_price: 389.95, quantity: 1, line_total: 389.95 } ],
          { recipient: 'Client 42', street: '12 rue de la République', postal_code: '69002', city: 'Lyon', country: 'FR' },
          { recipient: 'Client 42', street: '12 rue de la République', postal_code: '69002', city: 'Lyon', country: 'FR' },
          'carte_bancaire', 'Colissimo', '6A12345678901');
APPLY BATCH;

BEGIN BATCH
  INSERT INTO orders_by_customer (customer_id, order_date, order_id, status, total_amount, shipping_fee, currency, items_count, lines, shipping_address, carrier, tracking_number)
  VALUES ('user:42', '2026-06-15 09:12:47+0000', 'LD2606150417', 'livree', 95.94, 5.99, 'EUR', 1,
          [ { sku: 'SOU-LOGI-G502X', name: 'Logitech G502 X (Noir)', unit_price: 89.95, quantity: 1, line_total: 89.95 } ],
          { recipient: 'Client 42', street: '12 rue de la République', postal_code: '69002', city: 'Lyon', country: 'FR' },
          'Chronopost', 'XY987654321FR');
  INSERT INTO orders_by_id (order_id, customer_id, order_date, status, total_amount, shipping_fee, currency, items_count, lines, shipping_address, billing_address, payment_method, carrier, tracking_number)
  VALUES ('LD2606150417', 'user:42', '2026-06-15 09:12:47+0000', 'livree', 95.94, 5.99, 'EUR', 1,
          [ { sku: 'SOU-LOGI-G502X', name: 'Logitech G502 X (Noir)', unit_price: 89.95, quantity: 1, line_total: 89.95 } ],
          { recipient: 'Client 42', street: '12 rue de la République', postal_code: '69002', city: 'Lyon', country: 'FR' },
          { recipient: 'Client 42', street: '12 rue de la République', postal_code: '69002', city: 'Lyon', country: 'FR' },
          'paypal', 'Chronopost', 'XY987654321FR');
APPLY BATCH;

--  Commande du jour, encore en préparation : la config PC de user:kevinfps
BEGIN BATCH
  INSERT INTO orders_by_customer (customer_id, order_date, order_id, status, total_amount, shipping_fee, currency, items_count, lines, shipping_address)
  VALUES ('user:kevinfps', '2026-11-18 08:03:55+0000', 'LD2611180118', 'preparation', 1504.75, 0.00, 'EUR', 5,
          [ { sku: 'CPU-AMD-R7-7800X3D',       name: 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)',                unit_price: 389.95, quantity: 1, line_total: 389.95 },
            { sku: 'CM-ASUS-B650A-WIFI',       name: 'ASUS ROG STRIX B650-A GAMING WIFI',                       unit_price: 249.95, quantity: 1, line_total: 249.95 },
            { sku: 'RAM-CORSAIR-DDR5-32-6000', name: 'Corsair Vengeance DDR5 32 Go (2 x 16 Go) 6000 MHz CL30', unit_price: 129.95, quantity: 1, line_total: 129.95 },
            { sku: 'GPU-ASUS-RTX4070S-12',     name: 'ASUS Dual GeForce RTX 4070 SUPER OC Edition 12 Go',      unit_price: 629.95, quantity: 1, line_total: 629.95 },
            { sku: 'BOI-CORSAIR-4000D',        name: 'Corsair 4000D Airflow Noir',                              unit_price: 104.95, quantity: 1, line_total: 104.95 } ],
          { recipient: 'Kevin M.', street: '5 avenue Jean Jaurès', postal_code: '31000', city: 'Toulouse', country: 'FR' });
  INSERT INTO orders_by_id (order_id, customer_id, order_date, status, total_amount, shipping_fee, currency, items_count, lines, shipping_address, billing_address, payment_method)
  VALUES ('LD2611180118', 'user:kevinfps', '2026-11-18 08:03:55+0000', 'preparation', 1504.75, 0.00, 'EUR', 5,
          [ { sku: 'CPU-AMD-R7-7800X3D',       name: 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)',                unit_price: 389.95, quantity: 1, line_total: 389.95 },
            { sku: 'CM-ASUS-B650A-WIFI',       name: 'ASUS ROG STRIX B650-A GAMING WIFI',                       unit_price: 249.95, quantity: 1, line_total: 249.95 },
            { sku: 'RAM-CORSAIR-DDR5-32-6000', name: 'Corsair Vengeance DDR5 32 Go (2 x 16 Go) 6000 MHz CL30', unit_price: 129.95, quantity: 1, line_total: 129.95 },
            { sku: 'GPU-ASUS-RTX4070S-12',     name: 'ASUS Dual GeForce RTX 4070 SUPER OC Edition 12 Go',      unit_price: 629.95, quantity: 1, line_total: 629.95 },
            { sku: 'BOI-CORSAIR-4000D',        name: 'Corsair 4000D Airflow Noir',                              unit_price: 104.95, quantity: 1, line_total: 104.95 } ],
          { recipient: 'Kevin M.', street: '5 avenue Jean Jaurès', postal_code: '31000', city: 'Toulouse', country: 'FR' },
          { recipient: 'Kevin M.', street: '5 avenue Jean Jaurès', postal_code: '31000', city: 'Toulouse', country: 'FR' },
          'carte_bancaire');
APPLY BATCH;


-- =============================================================================
--  PARTIE B — LECTURES (les requêtes demandées)
-- =============================================================================

-- -----------------------------------------------------------------------------
--  B1. « Combien de vues pour ce produit aujourd'hui ? »
-- -----------------------------------------------------------------------------
--  Clé primaire complète : 1 partition, 1 ligne. Temps constant.
SELECT sku, day, views, clicks, add_to_cart
  FROM product_views_by_day
 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day = '2026-11-18';

--  Variante : les 7 derniers jours, même partition, tranche sur la clustering column.
--  (La somme est faite par l'application.)
SELECT day, views
  FROM product_views_by_day
 WHERE sku = 'CPU-AMD-R7-7800X3D' AND day >= '2026-11-12' AND day <= '2026-11-18';

-- -----------------------------------------------------------------------------
--  B2. « Top des produits vus cette semaine ? »
-- -----------------------------------------------------------------------------
--  Lecture d'une partition pré-calculée, déjà triée par rank.
SELECT rank, sku, name, brand, views
  FROM top_products_by_week
 WHERE week = '2026-W47' AND category_id = 'all'
 LIMIT 10;

--  Top du rayon Processeurs
SELECT rank, sku, name, views
  FROM top_products_by_week
 WHERE week = '2026-W47' AND category_id = 'processeurs'
 LIMIT 3;

-- -----------------------------------------------------------------------------
--  B3. « Historique de commandes d'un client »
-- -----------------------------------------------------------------------------
--  Une seule partition, triée de la plus récente à la plus ancienne.
SELECT order_date, order_id, status, total_amount, items_count, lines
  FROM orders_by_customer
 WHERE customer_id = 'user:42'
 LIMIT 20;

--  Page suivante : on repart de la date de la dernière commande affichée
--  (pagination par clustering column, sans OFFSET).
SELECT order_date, order_id, status, total_amount
  FROM orders_by_customer
 WHERE customer_id = 'user:42' AND order_date < '2026-11-02 18:42:10+0000'
 LIMIT 20;

--  Commandes de l'année 2026 seulement
SELECT order_date, order_id, total_amount
  FROM orders_by_customer
 WHERE customer_id = 'user:42'
   AND order_date >= '2026-01-01 00:00:00+0000' AND order_date < '2027-01-01 00:00:00+0000';

-- -----------------------------------------------------------------------------
--  B4. Détail d'une commande (service client, suivi)
-- -----------------------------------------------------------------------------
SELECT * FROM orders_by_id WHERE order_id = 'LD2611180118';

-- -----------------------------------------------------------------------------
--  B5. Changement de statut : mise à jour des DEUX tables
-- -----------------------------------------------------------------------------
--  1) on lit orders_by_id pour connaître customer_id et order_date (nécessaires
--     pour adresser la ligne dans orders_by_customer) ;
--  2) BATCH LOGGED pour que les deux copies restent cohérentes.
BEGIN BATCH
  UPDATE orders_by_id
     SET status = 'expediee', carrier = 'Colissimo', tracking_number = '6A99887766554'
   WHERE order_id = 'LD2611180118';
  UPDATE orders_by_customer
     SET status = 'expediee', carrier = 'Colissimo', tracking_number = '6A99887766554'
   WHERE customer_id = 'user:kevinfps' AND order_date = '2026-11-18 08:03:55+0000' AND order_id = 'LD2611180118';
APPLY BATCH;

SELECT order_id, status, carrier, tracking_number FROM orders_by_id WHERE order_id = 'LD2611180118';

-- -----------------------------------------------------------------------------
--  B6. Événements bruts d'une heure (jobs d'analyse, investigation)
-- -----------------------------------------------------------------------------
--  Une partition = une heure × un shard. Le job interroge les 16 shards en
--  parallèle ; ici un seul pour l'exemple.
SELECT event_id, toTimestamp(event_id) AS ts, event_type, sku, search_query, device
  FROM events_by_hour
 WHERE bucket_hour = '2026-11-18 14:00:00+0000' AND shard = 3;

--  Tranche de temps dans l'heure grâce au timeuuid (clustering column)
SELECT toTimestamp(event_id) AS ts, event_type, page_url
  FROM events_by_hour
 WHERE bucket_hour = '2026-11-18 14:00:00+0000' AND shard = 3
   AND event_id >= minTimeuuid('2026-11-18 14:00:00+0000')
   AND event_id <  maxTimeuuid('2026-11-18 14:59:59+0000');
--  (Les lignes insérées par now() ont l'horodatage réel d'exécution du
--   script : en démo, cette tranche peut donc revenir vide.)

--  Durée de vie restante d'un événement (TTL appliqué automatiquement)
SELECT event_type, TTL(page_url) AS ttl_restant_s
  FROM events_by_hour
 WHERE bucket_hour = '2026-11-18 14:00:00+0000' AND shard = 11;

-- -----------------------------------------------------------------------------
--  B7. Entrée du job « top de la semaine » : vues de tous les produits d'un jour
-- -----------------------------------------------------------------------------
--  IN sur le shard = 8 partitions lues par le coordinateur (acceptable pour
--  un batch nocturne ; le site, lui, ne lit que top_products_by_week).
SELECT sku, views
  FROM daily_product_views
 WHERE day = '2026-11-18' AND shard IN (0, 1, 2, 3, 4, 5, 6, 7);

SELECT event_type, total FROM daily_site_stats WHERE day = '2026-11-18';

-- -----------------------------------------------------------------------------
--  B8. Anti-pattern (laissé en commentaire)
-- -----------------------------------------------------------------------------
--  « Toutes les vues du produit X » directement sur les événements bruts :
--    SELECT * FROM events_by_hour WHERE sku = 'CPU-AMD-R7-7800X3D';
--  → refusé par Cassandra (sku ne fait pas partie de la clé primaire).
--  Avec ALLOW FILTERING, la requête parcourrait TOUTES les partitions de
--  TOUS les nœuds : des milliards de lignes. D'où les tables de compteurs
--  dédiées à cette question : une table par requête.
