// =============================================================================
//  Refonte LDLC — Lot 4 : Recommandations et compatibilités (Neo4j)
//  queries.cypher — Requêtes de recommandation et de compatibilité
//
//  Exécution (après 01-schema.cypher et 02-sample-data.cypher) :
//    cypher-shell -u neo4j -p <mdp> -f queries.cypher
//
//  Chaque requête commence par « WITH '<valeur>' AS … » pour être exécutable
//  telle quelle ; dans l'application ce sont des paramètres ($sku, $customerId).
// =============================================================================


// =============================================================================
//  Q1. « Les clients qui ont acheté ce processeur ont aussi acheté
//       cette carte mère » — co-achats calculés en direct
// =============================================================================
//  Parcours : Produit ← Client → Autre produit (2 sauts).
//  On filtre sur la catégorie « cartes-meres » pour le bloc de la fiche CPU.
//  confiance = part des acheteurs du CPU qui ont aussi pris cette carte mère.
WITH 'CPU-AMD-R7-7800X3D' AS sku
MATCH (p:Product {sku: sku})<-[:BOUGHT]-(c:Customer)
WITH p, count(DISTINCT c) AS acheteurs_cpu
MATCH (p)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(mb:Product)-[:IN_CATEGORY]->(:Category {id: 'cartes-meres'})
WITH mb, acheteurs_cpu, count(DISTINCT c) AS clients_communs
RETURN mb.sku AS sku, mb.name AS carte_mere, clients_communs,
       round(toFloat(clients_communs) / acheteurs_cpu, 2) AS confiance
ORDER BY clients_communs DESC;

//  Variante toutes catégories : « Les clients ayant acheté ce produit ont
//  aussi acheté… » (bloc générique de la fiche produit).
WITH 'CPU-AMD-R7-7800X3D' AS sku
MATCH (p:Product {sku: sku})<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(o:Product)
WHERE o <> p
RETURN o.type AS type, o.name AS produit, count(DISTINCT c) AS clients_communs
ORDER BY clients_communs DESC, produit
LIMIT 8;

//  Variante « achetés ENSEMBLE » : même commande (même order_id sur les
//  deux relations BOUGHT), pour le bloc « souvent achetés ensemble ».
WITH 'CPU-AMD-R7-7800X3D' AS sku
MATCH (p:Product {sku: sku})<-[b1:BOUGHT]-(:Customer)-[b2:BOUGHT]->(o:Product)
WHERE o <> p AND b1.order_id = b2.order_id
RETURN o.name AS produit, count(DISTINCT b1.order_id) AS commandes_communes
ORDER BY commandes_communes DESC
LIMIT 5;


// =============================================================================
//  Q2. Job nocturne : matérialisation des relations BOUGHT_WITH
// =============================================================================
//  Pourquoi ? Sur le vrai catalogue, un produit populaire a des dizaines de
//  milliers d'acheteurs, chacun ayant acheté des dizaines de produits : le
//  parcours à 2 sauts de Q1 visiterait des millions de chemins (« supernœud »)
//  à chaque affichage de fiche. On le calcule UNE fois par nuit et on stocke
//  le résultat dans une relation directe : en journée, la recommandation est
//  un parcours à 1 saut.
//
//  La relation est ORIENTÉE car la confiance n'est pas symétrique :
//  P(carte mère | CPU) ≠ P(CPU | carte mère).
//  Seuil : au moins 2 clients communs (évite les coïncidences).
//
//  Sur un gros graphe on découpe en transactions :
//    MATCH (p1:Product)
//    CALL (p1) { …même corps… } IN TRANSACTIONS OF 500 ROWS;
//
//  Étape 1 : création / mise à jour, horodatée par run_date.
MATCH (p1:Product)<-[:BOUGHT]-(c:Customer)
WITH p1, count(DISTINCT c) AS acheteurs
MATCH (p1)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(p2:Product)
WHERE p1 <> p2
WITH p1, p2, acheteurs, count(DISTINCT c) AS communs
WHERE communs >= 2
MERGE (p1)-[r:BOUGHT_WITH]->(p2)
  SET r.customers  = communs,
      r.confidence = round(toFloat(communs) / acheteurs, 3),
      r.run_date   = date()
RETURN count(r) AS relations_bought_with;

//  Étape 2 : suppression des relations qui n'ont pas été recalculées ce soir
//  (paire passée sous le seuil). On ne supprime qu'APRÈS avoir écrit les
//  nouvelles : le site n'est jamais sans recommandations pendant le job.
MATCH ()-[r:BOUGHT_WITH]->()
WHERE r.run_date < date()
DELETE r
RETURN count(*) AS relations_obsoletes_supprimees;

//  Lecture en journée : 1 saut, coût constant, quelle que soit la popularité.
WITH 'CPU-AMD-R7-7800X3D' AS sku
MATCH (:Product {sku: sku})-[r:BOUGHT_WITH]->(o:Product)
WHERE o.stock_status <> 'rupture'
RETURN o.name AS produit, r.customers AS clients, r.confidence AS confiance
ORDER BY r.confidence DESC
LIMIT 5;


// =============================================================================
//  Q3. « Produits compatibles avec ce boîtier » — compatibilité DÉDUITE
// =============================================================================
//  Aucune relation « compatible avec » n'a été saisie : elle est déduite par
//  les nœuds de caractéristiques partagées.
//    - cartes mères : Boîtier → FormFactor ← Carte mère ;
//    - cartes graphiques : comparaison de propriétés (longueur) ;
//    - processeurs : 2 étapes, via une carte mère montable dans le boîtier.
WITH 'BOI-FRACTAL-NORTH' AS sku
MATCH (b:Product {sku: sku})-[:ACCEPTS_FORM_FACTOR]->(f:FormFactor)<-[:HAS_FORM_FACTOR]-(mb:Product)
RETURN 'Carte mère' AS type, mb.name AS produit, 'format ' + f.name AS raison
UNION
WITH 'BOI-FRACTAL-NORTH' AS sku
MATCH (b:Product {sku: sku}), (gpu:Product {type: 'carte_graphique'})
WHERE gpu.length_mm <= b.max_gpu_length_mm
RETURN 'Carte graphique' AS type, gpu.name AS produit,
       gpu.length_mm + ' mm ≤ ' + b.max_gpu_length_mm + ' mm' AS raison
UNION
WITH 'BOI-FRACTAL-NORTH' AS sku
MATCH (b:Product {sku: sku})-[:ACCEPTS_FORM_FACTOR]->(:FormFactor)<-[:HAS_FORM_FACTOR]-(mb:Product)
      -[:HAS_SOCKET]->(s:Socket)<-[:HAS_SOCKET]-(cpu:Product {type: 'processeur'})
RETURN DISTINCT 'Processeur' AS type, cpu.name AS produit, 'via une carte mère ' + s.name AS raison;

//  Démonstration de l'intérêt : un NOUVEAU processeur AM5 est référencé.
//  Il suffit de le relier au nœud Socket AM5 : il devient immédiatement
//  compatible avec toutes les cartes mères AM5 (et donc les boîtiers).
MERGE (p:Product {sku: 'CPU-AMD-R7-9800X3D'})
  SET p.name = 'AMD Ryzen 7 9800X3D (4.7 GHz / 5.2 GHz)', p.type = 'processeur',
      p.price = 479.95, p.stock_status = 'precommande'
WITH p
MATCH (s:Socket {name: 'AM5'}), (m:MemoryType {name: 'DDR5'})
MERGE (p)-[:HAS_SOCKET]->(s)
MERGE (p)-[:SUPPORTS_MEMORY]->(m)
WITH p
MATCH (p)-[:HAS_SOCKET]->(:Socket)<-[:HAS_SOCKET]-(mb:Product {type: 'carte_mere'})
RETURN p.name AS nouveau_cpu, collect(mb.name) AS cartes_meres_compatibles;

MATCH (p:Product {sku: 'CPU-AMD-R7-9800X3D'}) DETACH DELETE p;  // retour à l'état initial


// =============================================================================
//  Q4. Compatibilité d'un processeur : cartes mères et mémoire
// =============================================================================
//  Carte mère compatible = même socket ET au moins un type de mémoire
//  supporté à la fois par le CPU et par la carte mère.
WITH 'CPU-INTEL-I5-14600K' AS sku
MATCH (cpu:Product {sku: sku})-[:HAS_SOCKET]->(s:Socket)<-[:HAS_SOCKET]-(mb:Product {type: 'carte_mere'})
MATCH (cpu)-[:SUPPORTS_MEMORY]->(mt:MemoryType)<-[:SUPPORTS_MEMORY]-(mb)
OPTIONAL MATCH (ram:Product {type: 'memoire'})-[:HAS_MEMORY_TYPE]->(mt)
RETURN mb.name AS carte_mere, s.name AS socket, mt.name AS memoire,
       collect(ram.name) AS barrettes_compatibles;


// =============================================================================
//  Q5. Configurateur PC : CPU → carte mère → RAM + boîtier (+ carte graphique)
// =============================================================================
//  À partir du processeur choisi, le graphe propose des configurations
//  complètes et cohérentes. Chaque étape est un parcours par les specs :
//    CPU ─HAS_SOCKET→ Socket ←HAS_SOCKET─ Carte mère
//    CPU ─SUPPORTS_MEMORY→ MemoryType ←SUPPORTS_MEMORY─ Carte mère
//    RAM ─HAS_MEMORY_TYPE→ MemoryType
//    Carte mère ─HAS_FORM_FACTOR→ FormFactor ←ACCEPTS_FORM_FACTOR─ Boîtier
//  Classement : popularité de la carte mère auprès des acheteurs du CPU
//  (signal de co-achat), puis prix total.
WITH 'CPU-AMD-R7-7800X3D' AS sku
MATCH (cpu:Product {sku: sku})-[:HAS_SOCKET]->(:Socket)<-[:HAS_SOCKET]-(mb:Product {type: 'carte_mere'})
WHERE mb.stock_status <> 'rupture'
MATCH (cpu)-[:SUPPORTS_MEMORY]->(mt:MemoryType)<-[:SUPPORTS_MEMORY]-(mb)
MATCH (ram:Product {type: 'memoire'})-[:HAS_MEMORY_TYPE]->(mt)
MATCH (mb)-[:HAS_FORM_FACTOR]->(:FormFactor)<-[:ACCEPTS_FORM_FACTOR]-(boitier:Product {type: 'boitier'})
WITH cpu, mb, ram, boitier,
     COUNT { (cpu)<-[:BOUGHT]-(:Customer)-[:BOUGHT]->(mb) } AS popularite_cm
RETURN mb.name AS carte_mere, ram.name AS memoire, boitier.name AS boitier,
       popularite_cm,
       round(cpu.price + mb.price + ram.price + boitier.price, 2) AS total_eur
ORDER BY popularite_cm DESC, total_eur ASC
LIMIT 5;

//  Étape suivante du configurateur : cartes graphiques qui rentrent dans le
//  boîtier choisi, triées par nombre d'acheteurs ayant le même CPU.
WITH 'CPU-AMD-R7-7800X3D' AS cpu_sku, 'BOI-CORSAIR-4000D' AS boitier_sku
MATCH (cpu:Product {sku: cpu_sku}), (b:Product {sku: boitier_sku}),
      (gpu:Product {type: 'carte_graphique'})
WHERE gpu.length_mm <= b.max_gpu_length_mm
RETURN gpu.name AS carte_graphique, gpu.price AS prix,
       COUNT { (cpu)<-[:BOUGHT]-(:Customer)-[:BOUGHT]->(gpu) } AS achetee_avec_ce_cpu
ORDER BY achetee_avec_ce_cpu DESC, prix;


// =============================================================================
//  Q6. Produits similaires
// =============================================================================
//  Même catégorie, puis score combinant :
//    - caractéristiques partagées (même socket, même type de mémoire…) ;
//    - même marque, même gamme ;
//    - proximité de prix (1 = même prix) ;
//    - clients communs (comportement d'achat).
WITH 'CPU-AMD-R7-7800X3D' AS sku
MATCH (p:Product {sku: sku})-[:IN_CATEGORY]->(:Category)<-[:IN_CATEGORY]-(o:Product)
WHERE o <> p
WITH p, o,
     COUNT { (p)-[:HAS_SOCKET|SUPPORTS_MEMORY|HAS_MEMORY_TYPE|HAS_FORM_FACTOR|ACCEPTS_FORM_FACTOR]->()
             <-[:HAS_SOCKET|SUPPORTS_MEMORY|HAS_MEMORY_TYPE|HAS_FORM_FACTOR|ACCEPTS_FORM_FACTOR]-(o) } AS specs_communes,
     CASE WHEN EXISTS { (p)-[:MADE_BY]->(:Brand)<-[:MADE_BY]-(o) } THEN 1 ELSE 0 END AS meme_marque,
     CASE WHEN EXISTS { (p)-[:PART_OF]->(:Range)<-[:PART_OF]-(o) } THEN 1 ELSE 0 END AS meme_gamme,
     1.0 - abs(p.price - o.price) / CASE WHEN p.price > o.price THEN p.price ELSE o.price END AS proximite_prix,
     COUNT { (p)<-[:BOUGHT]-(:Customer)-[:BOUGHT]->(o) } AS clients_communs
RETURN o.name AS produit, specs_communes, meme_marque, meme_gamme,
       round(proximite_prix, 2) AS proximite_prix, clients_communs,
       round(2 * specs_communes + meme_marque + meme_gamme + proximite_prix + 0.5 * clients_communs, 2) AS score
ORDER BY score DESC;


// =============================================================================
//  Q7. Recommandations personnalisées pour un client
// =============================================================================
//  Pour user:42 (a acheté un 7800X3D et une souris, consulte une RTX 4070
//  SUPER, une carte mère et de la RAM) :
//    1) candidats = produits achetés par les clients qui ont acheté les
//       mêmes produits que lui (filtrage collaboratif) ;
//    2) on exclut ce qu'il possède déjà, les ruptures, et les catégories
//       où il a déjà acheté (on ne repropose pas un 2e processeur) ;
//    3) score = co-achats + consultations + achats de ses amis
//       + bonus si le produit est COMPATIBLE avec ce qu'il possède.
WITH 'user:42' AS customerId
MATCH (me:Customer {id: customerId})-[:BOUGHT]->(:Product)<-[:BOUGHT]-(other:Customer)-[:BOUGHT]->(reco:Product)
WHERE other <> me
  AND reco.stock_status <> 'rupture'
  AND NOT EXISTS { (me)-[:BOUGHT]->(reco) }
  AND NOT EXISTS { (me)-[:BOUGHT]->(:Product)-[:IN_CATEGORY]->(:Category)<-[:IN_CATEGORY]-(reco) }
WITH me, reco, count(DISTINCT other) AS co_acheteurs
OPTIONAL MATCH (me)-[v:VIEWED]->(reco)
WITH me, reco, co_acheteurs, coalesce(v.count, 0) AS vues,
     COUNT { (me)-[:FRIEND_OF]-(:Customer)-[:BOUGHT]->(reco) } AS achats_amis,
     CASE WHEN EXISTS { (me)-[:BOUGHT]->(:Product)-[:HAS_SOCKET]->(:Socket)<-[:HAS_SOCKET]-(reco) }
            OR EXISTS { (me)-[:BOUGHT]->(:Product)-[:SUPPORTS_MEMORY]->(:MemoryType)<-[:HAS_MEMORY_TYPE]-(reco) }
          THEN 1 ELSE 0 END AS compatible_avec_mon_pc
RETURN reco.name AS recommandation, co_acheteurs, vues, achats_amis, compatible_avec_mon_pc,
       co_acheteurs + 0.5 * vues + 2 * achats_amis + 3 * compatible_avec_mon_pc AS score
ORDER BY score DESC
LIMIT 5;


// =============================================================================
//  Q8. Amis d'amis
// =============================================================================
//  a) Suggestions de contacts : amis de mes amis que je ne connais pas
//     encore, classés par nombre d'amis en commun.
WITH 'user:42' AS customerId
MATCH (me:Customer {id: customerId})-[:FRIEND_OF]-(ami:Customer)-[:FRIEND_OF]-(fof:Customer)
WHERE fof <> me AND NOT EXISTS { (me)-[:FRIEND_OF]-(fof) }
RETURN fof.pseudo AS ami_d_ami, count(DISTINCT ami) AS amis_communs,
       collect(DISTINCT ami.pseudo) AS via
ORDER BY amis_communs DESC;

//  b) « Ce qu'achète votre entourage » : achats des amis (distance 1) et
//     amis d'amis (distance 2), pondérés par la proximité.
WITH 'user:42' AS customerId
MATCH path = (me:Customer {id: customerId})-[:FRIEND_OF*1..2]-(f:Customer)
WHERE f <> me
WITH me, f, min(length(path)) AS distance
MATCH (f)-[:BOUGHT]->(p:Product)
WHERE NOT EXISTS { (me)-[:BOUGHT]->(p) }
RETURN p.name AS produit,
       count(DISTINCT f) AS personnes,
       collect(DISTINCT f.pseudo + ' (' + distance + ')') AS acheteurs_distance,
       round(sum(1.0 / distance), 2) AS score
ORDER BY score DESC
LIMIT 5;

//  c) Plus court chemin social entre deux clients (degrés de séparation).
MATCH (a:Customer {id: 'user:42'}), (b:Customer {id: 'user:emmav'})
MATCH path = shortestPath((a)-[:FRIEND_OF*..6]-(b))
RETURN [n IN nodes(path) | n.pseudo] AS chaine, length(path) AS degres;


// =============================================================================
//  Q9. Analyse : marques préférées par acheteurs d'un socket
// =============================================================================
//  Exemple d'analyse impossible à exprimer simplement en clé-valeur : parmi
//  les clients ayant un CPU AM5, quelles marques de carte graphique
//  choisissent-ils ?
MATCH (:Socket {name: 'AM5'})<-[:HAS_SOCKET]-(:Product {type: 'processeur'})<-[:BOUGHT]-(c:Customer)
      -[:BOUGHT]->(:Product {type: 'carte_graphique'})-[:MADE_BY]->(b:Brand)
RETURN b.name AS marque_gpu, count(DISTINCT c) AS clients
ORDER BY clients DESC;
