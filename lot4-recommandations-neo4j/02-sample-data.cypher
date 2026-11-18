// =============================================================================
//  Refonte LDLC — Lot 4 : Recommandations et compatibilités (Neo4j)
//  02-sample-data.cypher — Jeu de données
//
//  Exécution (après 01-schema.cypher) :
//    cypher-shell -u neo4j -p <mdp> -f 02-sample-data.cypher
//
//  Contenu : les 14 produits du catalogue (lot 1), leurs catégories, marques
//  et gammes, les nœuds de caractéristiques partagées (Socket, MemoryType,
//  FormFactor), 13 clients, leurs achats (mêmes n° de commande que dans
//  Cassandra, lot 3), quelques consultations et liens d'amitié.
//
//  En production, ce graphe est alimenté en continu :
//    - produits / specs : depuis MongoDB (Change Streams) ;
//    - achats : depuis le flux de commandes (Kafka) ;
//    - consultations : agrégées depuis les événements Cassandra (lot 3).
// =============================================================================

// Remise à zéro (script rejouable)
MATCH (n) DETACH DELETE n;

// -----------------------------------------------------------------------------
//  1. Catégories (même arbre et mêmes ids que le lot 1)
// -----------------------------------------------------------------------------
UNWIND [
  {id: 'informatique',          name: 'Informatique',            parent: null},
  {id: 'composants',            name: 'Composants',              parent: 'informatique'},
  {id: 'processeurs',           name: 'Processeurs',             parent: 'composants'},
  {id: 'cartes-meres',          name: 'Cartes mères',            parent: 'composants'},
  {id: 'memoire-pc',            name: 'Mémoire PC',              parent: 'composants'},
  {id: 'cartes-graphiques',     name: 'Cartes graphiques',       parent: 'composants'},
  {id: 'boitiers-pc',           name: 'Boîtiers PC',             parent: 'composants'},
  {id: 'peripheriques',         name: 'Périphériques',           parent: 'informatique'},
  {id: 'souris',                name: 'Souris',                  parent: 'peripheriques'},
  {id: 'logiciels',             name: 'Logiciels',               parent: 'informatique'},
  {id: 'systemes-exploitation', name: "Systèmes d'exploitation", parent: 'logiciels'}
] AS c
MERGE (cat:Category {id: c.id})
  SET cat.name = c.name
WITH cat, c
WHERE c.parent IS NOT NULL
MERGE (parent:Category {id: c.parent})
MERGE (cat)-[:SUBCATEGORY_OF]->(parent);

// -----------------------------------------------------------------------------
//  2. Marques et gammes
// -----------------------------------------------------------------------------
UNWIND [
  {id: 'amd',       name: 'AMD'},
  {id: 'intel',     name: 'Intel'},
  {id: 'asus',      name: 'ASUS'},
  {id: 'msi',       name: 'MSI'},
  {id: 'corsair',   name: 'Corsair'},
  {id: 'gskill',    name: 'G.Skill'},
  {id: 'sapphire',  name: 'Sapphire'},
  {id: 'fractal',   name: 'Fractal Design'},
  {id: 'logitech',  name: 'Logitech G'},
  {id: 'microsoft', name: 'Microsoft'}
] AS b
MERGE (:Brand {id: b.id, name: b.name});

//  Une gamme (Range) regroupe des produits d'une même marque : sert aux
//  recommandations « dans la même gamme » et à l'affinité de marque.
UNWIND [
  {id: 'ryzen-7',        name: 'Ryzen 7',         brand: 'amd'},
  {id: 'ryzen-5',        name: 'Ryzen 5',         brand: 'amd'},
  {id: 'core-i5',        name: 'Core i5',         brand: 'intel'},
  {id: 'rog-strix',      name: 'ROG Strix',       brand: 'asus'},
  {id: 'asus-dual',      name: 'ASUS Dual',       brand: 'asus'},
  {id: 'msi-pro',        name: 'MSI PRO',         brand: 'msi'},
  {id: 'msi-mag',        name: 'MSI MAG',         brand: 'msi'},
  {id: 'vengeance',      name: 'Vengeance',       brand: 'corsair'},
  {id: 'corsair-4000',   name: 'Corsair 4000',    brand: 'corsair'},
  {id: 'trident-z5',     name: 'Trident Z5',      brand: 'gskill'},
  {id: 'sapphire-pulse', name: 'PULSE',           brand: 'sapphire'},
  {id: 'fractal-north',  name: 'North',           brand: 'fractal'},
  {id: 'logitech-g502',  name: 'G502',            brand: 'logitech'},
  {id: 'windows-11',     name: 'Windows 11',      brand: 'microsoft'}
] AS r
MATCH (b:Brand {id: r.brand})
MERGE (rg:Range {id: r.id})
  SET rg.name = r.name
MERGE (rg)-[:OF_BRAND]->(b);

// -----------------------------------------------------------------------------
//  3. Caractéristiques partagées (nœuds Spec)
// -----------------------------------------------------------------------------
//  Un seul nœud par valeur : c'est ce partage qui rend la compatibilité
//  déductible par parcours.
UNWIND ['AM5', 'LGA1700']               AS s MERGE (:Socket {name: s});
UNWIND ['DDR4', 'DDR5']                 AS m MERGE (:MemoryType {name: m});
UNWIND ['ATX', 'Micro-ATX', 'Mini-ITX'] AS f MERGE (:FormFactor {name: f});

// -----------------------------------------------------------------------------
//  4. Produits (mêmes SKU, noms et prix que le lot 1)
// -----------------------------------------------------------------------------
//  Seules les propriétés utiles aux requêtes du graphe sont stockées
//  (ex. longueur de carte graphique / longueur max acceptée par un boîtier).
UNWIND [
  {sku: 'CPU-AMD-R7-7800X3D',       type: 'processeur',      price: 389.95, brand: 'amd',       cat: 'processeurs',           range: 'ryzen-7',
   name: 'AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)',               props: {cores: 8, tdp_w: 120}},
  {sku: 'CPU-AMD-R5-7600X',         type: 'processeur',      price: 199.95, brand: 'amd',       cat: 'processeurs',           range: 'ryzen-5',
   name: 'AMD Ryzen 5 7600X (4.7 GHz / 5.3 GHz)',                 props: {cores: 6, tdp_w: 105}},
  {sku: 'CPU-INTEL-I5-14600K',      type: 'processeur',      price: 279.95, brand: 'intel',     cat: 'processeurs',           range: 'core-i5',
   name: 'Intel Core i5-14600K (3.5 GHz / 5.3 GHz)',              props: {cores: 14, tdp_w: 125}},
  {sku: 'CM-ASUS-B650A-WIFI',       type: 'carte_mere',      price: 249.95, brand: 'asus',      cat: 'cartes-meres',          range: 'rog-strix',
   name: 'ASUS ROG STRIX B650-A GAMING WIFI',                     props: {chipset: 'AMD B650'}},
  {sku: 'CM-MSI-B650MA-WIFI',       type: 'carte_mere',      price: 159.95, brand: 'msi',       cat: 'cartes-meres',          range: 'msi-pro',
   name: 'MSI PRO B650M-A WIFI',                                  props: {chipset: 'AMD B650'}},
  {sku: 'CM-MSI-B760-TOMAHAWK',     type: 'carte_mere',      price: 199.95, brand: 'msi',       cat: 'cartes-meres',          range: 'msi-mag',
   name: 'MSI MAG B760 TOMAHAWK WIFI',                            props: {chipset: 'Intel B760'}},
  {sku: 'RAM-CORSAIR-DDR5-32-6000', type: 'memoire',         price: 129.95, brand: 'corsair',   cat: 'memoire-pc',            range: 'vengeance',
   name: 'Corsair Vengeance DDR5 32 Go (2 x 16 Go) 6000 MHz CL30', props: {capacity_gb: 32, frequency_mhz: 6000}},
  {sku: 'RAM-GSKILL-DDR5-32-6400',  type: 'memoire',         price: 149.95, brand: 'gskill',    cat: 'memoire-pc',            range: 'trident-z5',
   name: 'G.Skill Trident Z5 RGB 32 Go (2 x 16 Go) DDR5 6400 MHz CL32', props: {capacity_gb: 32, frequency_mhz: 6400}},
  {sku: 'GPU-ASUS-RTX4070S-12',     type: 'carte_graphique', price: 629.95, brand: 'asus',      cat: 'cartes-graphiques',     range: 'asus-dual',
   name: 'ASUS Dual GeForce RTX 4070 SUPER OC Edition 12 Go',     props: {vram_gb: 12, length_mm: 267, recommended_psu_w: 650}},
  {sku: 'GPU-SAPPHIRE-RX7800XT-16', type: 'carte_graphique', price: 529.95, brand: 'sapphire',  cat: 'cartes-graphiques',     range: 'sapphire-pulse',
   name: 'Sapphire PULSE Radeon RX 7800 XT 16 Go',                props: {vram_gb: 16, length_mm: 280, recommended_psu_w: 700}},
  {sku: 'BOI-FRACTAL-NORTH',        type: 'boitier',         price: 139.95, brand: 'fractal',   cat: 'boitiers-pc',           range: 'fractal-north',
   name: 'Fractal Design North Charcoal Black TG Dark',           props: {max_gpu_length_mm: 355, max_cpu_cooler_height_mm: 170}},
  {sku: 'BOI-CORSAIR-4000D',        type: 'boitier',         price: 104.95, brand: 'corsair',   cat: 'boitiers-pc',           range: 'corsair-4000',
   name: 'Corsair 4000D Airflow Noir',                            props: {max_gpu_length_mm: 360, max_cpu_cooler_height_mm: 170}},
  {sku: 'SOU-LOGI-G502X',           type: 'souris',          price: 89.95,  brand: 'logitech',  cat: 'souris',                range: 'logitech-g502',
   name: 'Logitech G502 X (Noir)',                                props: {dpi_max: 25600}},
  {sku: 'LOG-MS-WIN11-FAM',         type: 'logiciel',        price: 139.95, brand: 'microsoft', cat: 'systemes-exploitation', range: 'windows-11',
   name: 'Microsoft Windows 11 Famille 64 bits - OEM (DVD)',      props: {license_type: 'OEM'}}
] AS d
MATCH (b:Brand {id: d.brand}), (c:Category {id: d.cat}), (r:Range {id: d.range})
MERGE (p:Product {sku: d.sku})
  SET p.name = d.name, p.type = d.type, p.price = d.price, p.stock_status = 'en_stock'
  SET p += d.props
MERGE (p)-[:MADE_BY]->(b)
MERGE (p)-[:IN_CATEGORY]->(c)
MERGE (p)-[:PART_OF]->(r);

//  La carte mère micro-ATX MSI est en rupture (cf. lot 1) : les requêtes
//  de recommandation l'écartent.
MATCH (p:Product {sku: 'CM-MSI-B650MA-WIFI'}) SET p.stock_status = 'rupture';

// -----------------------------------------------------------------------------
//  5. Relations produits → caractéristiques partagées
// -----------------------------------------------------------------------------
//  Socket : processeurs et cartes mères
UNWIND [
  ['CPU-AMD-R7-7800X3D', 'AM5'], ['CPU-AMD-R5-7600X', 'AM5'], ['CPU-INTEL-I5-14600K', 'LGA1700'],
  ['CM-ASUS-B650A-WIFI', 'AM5'], ['CM-MSI-B650MA-WIFI', 'AM5'], ['CM-MSI-B760-TOMAHAWK', 'LGA1700']
] AS x
MATCH (p:Product {sku: x[0]}), (s:Socket {name: x[1]})
MERGE (p)-[:HAS_SOCKET]->(s);

//  Mémoire supportée : contrôleur mémoire du CPU, slots de la carte mère.
//  (Le 14600K accepte DDR4 et DDR5, la carte mère choisie décide.)
UNWIND [
  ['CPU-AMD-R7-7800X3D', 'DDR5'], ['CPU-AMD-R5-7600X', 'DDR5'],
  ['CPU-INTEL-I5-14600K', 'DDR4'], ['CPU-INTEL-I5-14600K', 'DDR5'],
  ['CM-ASUS-B650A-WIFI', 'DDR5'], ['CM-MSI-B650MA-WIFI', 'DDR5'], ['CM-MSI-B760-TOMAHAWK', 'DDR5']
] AS x
MATCH (p:Product {sku: x[0]}), (m:MemoryType {name: x[1]})
MERGE (p)-[:SUPPORTS_MEMORY]->(m);

//  Type de mémoire d'une barrette
UNWIND [['RAM-CORSAIR-DDR5-32-6000', 'DDR5'], ['RAM-GSKILL-DDR5-32-6400', 'DDR5']] AS x
MATCH (p:Product {sku: x[0]}), (m:MemoryType {name: x[1]})
MERGE (p)-[:HAS_MEMORY_TYPE]->(m);

//  Format de la carte mère
UNWIND [['CM-ASUS-B650A-WIFI', 'ATX'], ['CM-MSI-B650MA-WIFI', 'Micro-ATX'], ['CM-MSI-B760-TOMAHAWK', 'ATX']] AS x
MATCH (p:Product {sku: x[0]}), (f:FormFactor {name: x[1]})
MERGE (p)-[:HAS_FORM_FACTOR]->(f);

//  Formats acceptés par les boîtiers
UNWIND ['BOI-FRACTAL-NORTH', 'BOI-CORSAIR-4000D'] AS sku
UNWIND ['ATX', 'Micro-ATX', 'Mini-ITX'] AS ff
MATCH (p:Product {sku: sku}), (f:FormFactor {name: ff})
MERGE (p)-[:ACCEPTS_FORM_FACTOR]->(f);

// -----------------------------------------------------------------------------
//  6. Clients (ids cohérents avec les lots 1 à 3)
// -----------------------------------------------------------------------------
UNWIND [
  {id: 'user:42',       pseudo: 'Client42',   city: 'Lyon'},
  {id: 'user:kevinfps', pseudo: 'Kevin_FPS',  city: 'Toulouse'},
  {id: 'user:thomas33', pseudo: 'Thomas_33',  city: 'Bordeaux'},
  {id: 'user:maximeb',  pseudo: 'MaximeB',    city: 'Nantes'},
  {id: 'user:lucasm',   pseudo: 'Lucas_M',    city: 'Lille'},
  {id: 'user:sophier',  pseudo: 'Sophie_R',   city: 'Paris'},
  {id: 'user:bastieng', pseudo: 'Bastien.G',  city: 'Rennes'},
  {id: 'user:victora',  pseudo: 'Victor_A',   city: 'Marseille'},
  {id: 'user:hugob',    pseudo: 'Hugo_B',     city: 'Strasbourg'},
  {id: 'user:clarap',   pseudo: 'Clara.P',    city: 'Nice'},
  {id: 'user:mathieut', pseudo: 'Mathieu.T',  city: 'Grenoble'},
  {id: 'user:emmav',    pseudo: 'Emma.V',     city: 'Montpellier'},
  {id: 'user:romaink',  pseudo: 'Romain_K',   city: 'Dijon'}
] AS c
MERGE (cu:Customer {id: c.id})
  SET cu.pseudo = c.pseudo, cu.city = c.city;

// -----------------------------------------------------------------------------
//  7. Achats — une relation BOUGHT par ligne de commande
// -----------------------------------------------------------------------------
//  order_id permet de distinguer « acheté par le même client » (n'importe
//  quand) et « acheté dans le même panier » (même commande).
UNWIND [
  {c: 'user:42',       order: 'LD2606150417', date: '2026-06-15', skus: ['SOU-LOGI-G502X']},
  {c: 'user:42',       order: 'LD2611020042', date: '2026-11-02', skus: ['CPU-AMD-R7-7800X3D']},
  {c: 'user:kevinfps', order: 'LD2611180118', date: '2026-11-18', skus: ['CPU-AMD-R7-7800X3D', 'CM-ASUS-B650A-WIFI', 'RAM-CORSAIR-DDR5-32-6000', 'GPU-ASUS-RTX4070S-12', 'BOI-CORSAIR-4000D']},
  {c: 'user:thomas33', order: 'LD2609020311', date: '2026-09-02', skus: ['CPU-AMD-R7-7800X3D', 'CM-ASUS-B650A-WIFI', 'RAM-CORSAIR-DDR5-32-6000', 'GPU-SAPPHIRE-RX7800XT-16']},
  {c: 'user:maximeb',  order: 'LD2610120207', date: '2026-10-12', skus: ['CPU-AMD-R7-7800X3D', 'CM-ASUS-B650A-WIFI', 'RAM-CORSAIR-DDR5-32-6000', 'BOI-FRACTAL-NORTH']},
  {c: 'user:lucasm',   order: 'LD2610050150', date: '2026-10-05', skus: ['CPU-AMD-R5-7600X', 'CM-MSI-B650MA-WIFI', 'RAM-CORSAIR-DDR5-32-6000', 'BOI-CORSAIR-4000D', 'GPU-ASUS-RTX4070S-12']},
  {c: 'user:sophier',  order: 'LD2602150089', date: '2026-02-15', skus: ['CPU-AMD-R5-7600X', 'CM-ASUS-B650A-WIFI', 'RAM-GSKILL-DDR5-32-6400', 'BOI-FRACTAL-NORTH']},
  {c: 'user:bastieng', order: 'LD2607250276', date: '2026-07-25', skus: ['CPU-AMD-R7-7800X3D', 'CM-MSI-B650MA-WIFI', 'GPU-ASUS-RTX4070S-12', 'BOI-FRACTAL-NORTH']},
  {c: 'user:victora',  order: 'LD2603150412', date: '2026-03-15', skus: ['CPU-AMD-R5-7600X', 'CM-ASUS-B650A-WIFI', 'RAM-GSKILL-DDR5-32-6400', 'GPU-SAPPHIRE-RX7800XT-16']},
  {c: 'user:hugob',    order: 'LD2609220198', date: '2026-09-22', skus: ['CPU-INTEL-I5-14600K', 'CM-MSI-B760-TOMAHAWK', 'RAM-CORSAIR-DDR5-32-6000']},
  {c: 'user:hugob',    order: 'LD2610010033', date: '2026-10-01', skus: ['LOG-MS-WIN11-FAM']},
  {c: 'user:clarap',   order: 'LD2605080245', date: '2026-05-08', skus: ['CPU-INTEL-I5-14600K', 'CM-MSI-B760-TOMAHAWK', 'RAM-GSKILL-DDR5-32-6400', 'SOU-LOGI-G502X']},
  {c: 'user:mathieut', order: 'LD2608030120', date: '2026-08-03', skus: ['CPU-AMD-R7-7800X3D', 'CM-ASUS-B650A-WIFI', 'LOG-MS-WIN11-FAM']},
  {c: 'user:emmav',    order: 'LD2607190301', date: '2026-07-19', skus: ['CPU-AMD-R5-7600X', 'SOU-LOGI-G502X']},
  {c: 'user:romaink',  order: 'LD2603110077', date: '2026-03-11', skus: ['CPU-AMD-R5-7600X', 'CM-MSI-B650MA-WIFI', 'SOU-LOGI-G502X']}
] AS o
MATCH (cu:Customer {id: o.c})
UNWIND o.skus AS sku
MATCH (p:Product {sku: sku})
MERGE (cu)-[b:BOUGHT {order_id: o.order}]->(p)
  SET b.date = date(o.date), b.quantity = 1, b.unit_price = p.price;

// -----------------------------------------------------------------------------
//  8. Consultations récentes (agrégées depuis les événements Cassandra)
// -----------------------------------------------------------------------------
//  user:42 a acheté un 7800X3D et regarde une carte graphique, une carte
//  mère et de la RAM : il est en train de monter sa config.
UNWIND [
  ['user:42', 'GPU-ASUS-RTX4070S-12',     5, '2026-11-18'],
  ['user:42', 'CM-ASUS-B650A-WIFI',       3, '2026-11-18'],
  ['user:42', 'RAM-CORSAIR-DDR5-32-6000', 2, '2026-11-17'],
  ['user:hugob', 'GPU-SAPPHIRE-RX7800XT-16', 4, '2026-11-15']
] AS v
MATCH (c:Customer {id: v[0]}), (p:Product {sku: v[1]})
MERGE (c)-[r:VIEWED]->(p)
  SET r.count = v[2], r.last_seen = date(v[3]);

// -----------------------------------------------------------------------------
//  9. Réseau social (parrainage / amis de la communauté LDLC)
// -----------------------------------------------------------------------------
//  Relation stockée dans un seul sens, interrogée sans direction (-[:FRIEND_OF]-).
UNWIND [
  ['user:42', 'user:kevinfps'], ['user:42', 'user:thomas33'],
  ['user:kevinfps', 'user:bastieng'], ['user:kevinfps', 'user:lucasm'],
  ['user:thomas33', 'user:victora'], ['user:thomas33', 'user:maximeb'],
  ['user:lucasm', 'user:emmav'], ['user:hugob', 'user:clarap'],
  ['user:sophier', 'user:victora']
] AS f
MATCH (a:Customer {id: f[0]}), (b:Customer {id: f[1]})
MERGE (a)-[:FRIEND_OF]->(b);

// -----------------------------------------------------------------------------
//  Vérification
// -----------------------------------------------------------------------------
MATCH (n)
RETURN labels(n)[0] AS label, count(*) AS nb
ORDER BY label;
