// =============================================================================
//  Refonte LDLC — Lot 4 : Recommandations et compatibilités (Neo4j)
//  01-schema.cypher — Contraintes et index
//
//  Exécution (Neo4j 5) :  cypher-shell -u neo4j -p <mdp> -f 01-schema.cypher
// =============================================================================
//
//  Pourquoi une base graphe ?
//  --------------------------
//  Les questions de ce lot portent sur les RELATIONS, pas sur les entités :
//    - « les clients qui ont acheté ce processeur ont aussi acheté cette
//      carte mère » = Produit ← Client → Produit (2 sauts) ;
//    - « produits compatibles avec ce boîtier » = Boîtier → Format ← Carte mère ;
//    - « les amis de mes amis ont acheté... » = 3 à 4 sauts.
//  En SQL, chaque saut est une jointure (ou une auto-jointure) dont le coût
//  augmente avec la taille des tables. Dans Neo4j, une relation est un
//  pointeur physique entre deux nœuds (« index-free adjacency ») : le coût
//  d'un parcours dépend du nombre de voisins visités, pas de la taille
//  totale du graphe.
//
//  Modèle
//  ------
//    (:Product)-[:IN_CATEGORY]->(:Category)-[:SUBCATEGORY_OF]->(:Category)
//    (:Product)-[:MADE_BY]->(:Brand)
//    (:Product)-[:PART_OF]->(:Range)-[:OF_BRAND]->(:Brand)
//    (:Customer)-[:BOUGHT {order_id, date, quantity, unit_price}]->(:Product)
//    (:Customer)-[:VIEWED {count, last_seen}]->(:Product)
//    (:Customer)-[:FRIEND_OF]->(:Customer)                (parrainage / communauté)
//    (:Product)-[:BOUGHT_WITH {customers, confidence}]->(:Product)  (matérialisé la nuit)
//
//  Caractéristiques PARTAGÉES (nœuds « Spec ») :
//    (:Product)-[:HAS_SOCKET]->(:Socket)
//    (:Product)-[:SUPPORTS_MEMORY]->(:MemoryType)      CPU, carte mère
//    (:Product)-[:HAS_MEMORY_TYPE]->(:MemoryType)      barrette de RAM
//    (:Product)-[:HAS_FORM_FACTOR]->(:FormFactor)      carte mère
//    (:Product)-[:ACCEPTS_FORM_FACTOR]->(:FormFactor)  boîtier
//
//  La compatibilité n'est donc JAMAIS saisie produit par produit (ce qui
//  donnerait N × M relations à maintenir à la main) : elle est DÉDUITE par
//  un parcours. Un nouveau processeur AM5 relié au nœud Socket AM5 devient
//  automatiquement compatible avec toutes les cartes mères AM5.
//
//  Les identifiants sont ceux des autres lots : sku du catalogue (lot 1),
//  ids de catégories du lot 1, customer id « user:… » des lots 2 et 3.
//  Le graphe ne contient que ce qui sert aux parcours (pas les avis, ni
//  les descriptions) ; la fiche complète reste dans MongoDB.
// =============================================================================

// -----------------------------------------------------------------------------
//  Contraintes d'unicité (créent aussi un index sur la propriété)
// -----------------------------------------------------------------------------
//  Elles garantissent qu'un MERGE ne crée jamais de doublon et donnent un
//  point d'entrée indexé à chaque requête (MATCH (p:Product {sku: …})).
CREATE CONSTRAINT product_sku     IF NOT EXISTS FOR (p:Product)    REQUIRE p.sku  IS UNIQUE;
CREATE CONSTRAINT category_id     IF NOT EXISTS FOR (c:Category)   REQUIRE c.id   IS UNIQUE;
CREATE CONSTRAINT brand_id        IF NOT EXISTS FOR (b:Brand)      REQUIRE b.id   IS UNIQUE;
CREATE CONSTRAINT range_id        IF NOT EXISTS FOR (r:Range)      REQUIRE r.id   IS UNIQUE;
CREATE CONSTRAINT customer_id     IF NOT EXISTS FOR (c:Customer)   REQUIRE c.id   IS UNIQUE;
CREATE CONSTRAINT socket_name     IF NOT EXISTS FOR (s:Socket)     REQUIRE s.name IS UNIQUE;
CREATE CONSTRAINT formfactor_name IF NOT EXISTS FOR (f:FormFactor) REQUIRE f.name IS UNIQUE;
CREATE CONSTRAINT memorytype_name IF NOT EXISTS FOR (m:MemoryType) REQUIRE m.name IS UNIQUE;

//  Avec Neo4j Enterprise, on ajouterait des contraintes d'existence :
//    CREATE CONSTRAINT product_name_exists IF NOT EXISTS
//      FOR (p:Product) REQUIRE p.name IS NOT NULL;
//  (non disponibles en édition Community, donc laissées en commentaire).

// -----------------------------------------------------------------------------
//  Index secondaires
// -----------------------------------------------------------------------------
//  Filtrage fréquent par type de produit (« toutes les cartes mères »).
CREATE INDEX product_type  IF NOT EXISTS FOR (p:Product) ON (p.type);
//  Tri / filtre par prix dans les recommandations.
CREATE INDEX product_price IF NOT EXISTS FOR (p:Product) ON (p.price);
//  Index sur une propriété de relation : retrouver les achats d'une commande.
CREATE INDEX bought_order  IF NOT EXISTS FOR ()-[b:BOUGHT]-() ON (b.order_id);

SHOW CONSTRAINTS YIELD name, labelsOrTypes, properties;
