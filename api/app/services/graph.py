"""Lot 4 — Recommandations et compatibilités (Neo4j).

Mêmes requêtes que queries.cypher, paramétrées ($sku, $cid…)."""
from ..db import cypher

# Co-achats matérialisés par le job nocturne (1 saut)
ALSO_BOUGHT_MATERIALIZED = """
MATCH (:Product {sku: $sku})-[r:BOUGHT_WITH]->(o:Product)-[:IN_CATEGORY]->(c:Category)
WHERE ($cat IS NULL OR c.id = $cat) AND o.stock_status <> 'rupture'
RETURN o.sku AS sku, o.name AS nom, o.type AS type, o.price AS prix,
       r.customers AS clients_communs, r.confidence AS confiance
ORDER BY confiance DESC, clients_communs DESC
LIMIT $limit
"""

# Même question calculée en direct (2 sauts) — repli si le job n'a pas tourné
ALSO_BOUGHT_LIVE = """
MATCH (p:Product {sku: $sku})<-[:BOUGHT]-(c:Customer)
WITH p, count(DISTINCT c) AS acheteurs
MATCH (p)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(o:Product)-[:IN_CATEGORY]->(cat:Category)
WHERE o <> p AND ($cat IS NULL OR cat.id = $cat) AND o.stock_status <> 'rupture'
WITH o, acheteurs, count(DISTINCT c) AS communs
RETURN o.sku AS sku, o.name AS nom, o.type AS type, o.price AS prix,
       communs AS clients_communs, round(toFloat(communs) / acheteurs, 3) AS confiance
ORDER BY confiance DESC, clients_communs DESC
LIMIT $limit
"""

# Compatibilité DÉDUITE par les nœuds de caractéristiques partagées, quel que
# soit le type du produit de départ (CPU, carte mère, RAM, boîtier, GPU).
COMPATIBLE = """
MATCH (p:Product {sku: $sku})
CALL (p) {
  // CPU <-> carte mère : même socket ET un type de mémoire commun
  MATCH (p)-[:HAS_SOCKET]->(s:Socket)<-[:HAS_SOCKET]-(o:Product)
  WHERE o.type <> p.type
    AND EXISTS { (p)-[:SUPPORTS_MEMORY]->(:MemoryType)<-[:SUPPORTS_MEMORY]-(o) }
  RETURN o, 'socket ' + s.name AS raison
  UNION
  // CPU / carte mère -> barrettes du bon type
  MATCH (p)-[:SUPPORTS_MEMORY]->(m:MemoryType)<-[:HAS_MEMORY_TYPE]-(o:Product)
  RETURN o, 'mémoire ' + m.name AS raison
  UNION
  // barrette -> CPU / cartes mères qui acceptent ce type
  MATCH (p)-[:HAS_MEMORY_TYPE]->(m:MemoryType)<-[:SUPPORTS_MEMORY]-(o:Product)
  RETURN o, 'mémoire ' + m.name AS raison
  UNION
  // carte mère -> boîtiers qui acceptent son format
  MATCH (p)-[:HAS_FORM_FACTOR]->(f:FormFactor)<-[:ACCEPTS_FORM_FACTOR]-(o:Product)
  RETURN o, 'format ' + f.name AS raison
  UNION
  // boîtier -> cartes mères de format accepté
  MATCH (p)-[:ACCEPTS_FORM_FACTOR]->(f:FormFactor)<-[:HAS_FORM_FACTOR]-(o:Product)
  RETURN o, 'format ' + f.name AS raison
  UNION
  // boîtier -> cartes graphiques assez courtes (comparaison de propriétés)
  MATCH (o:Product {type: 'carte_graphique'})
  WHERE p.max_gpu_length_mm IS NOT NULL AND o.length_mm <= p.max_gpu_length_mm
  RETURN o, o.length_mm + ' mm ≤ ' + p.max_gpu_length_mm + ' mm' AS raison
  UNION
  // carte graphique -> boîtiers assez grands
  MATCH (o:Product {type: 'boitier'})
  WHERE p.length_mm IS NOT NULL AND p.length_mm <= o.max_gpu_length_mm
  RETURN o, p.length_mm + ' mm ≤ ' + o.max_gpu_length_mm + ' mm' AS raison
}
WITH o, collect(raison) AS raisons
RETURN o.type AS type, o.sku AS sku, o.name AS nom, o.price AS prix, o.stock_status AS stock, raisons
ORDER BY type, prix
"""

# Configurateur : CPU -> carte mère -> RAM + boîtier, + meilleure GPU qui rentre
BUILDER = """
MATCH (cpu:Product {sku: $sku, type: 'processeur'})-[:HAS_SOCKET]->(:Socket)<-[:HAS_SOCKET]-(mb:Product {type: 'carte_mere'})
WHERE mb.stock_status <> 'rupture'
MATCH (cpu)-[:SUPPORTS_MEMORY]->(mt:MemoryType)<-[:SUPPORTS_MEMORY]-(mb)
MATCH (ram:Product {type: 'memoire'})-[:HAS_MEMORY_TYPE]->(mt)
WHERE ram.stock_status <> 'rupture'
MATCH (mb)-[:HAS_FORM_FACTOR]->(:FormFactor)<-[:ACCEPTS_FORM_FACTOR]-(boitier:Product {type: 'boitier'})
WHERE boitier.stock_status <> 'rupture'
CALL (cpu, mb) {
  OPTIONAL MATCH (cpu)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(mb)
  RETURN count(DISTINCT c) AS popularite_cm
}
CALL (cpu, boitier) {
  OPTIONAL MATCH (g:Product {type: 'carte_graphique'})
  WHERE g.length_mm <= boitier.max_gpu_length_mm AND g.stock_status <> 'rupture'
  OPTIONAL MATCH (cpu)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(g)
  WITH g, count(DISTINCT c) AS n
  RETURN g ORDER BY n DESC, g.price LIMIT 1
}
RETURN cpu.name AS processeur, mb.sku AS carte_mere_sku, mb.name AS carte_mere,
       ram.sku AS memoire_sku, ram.name AS memoire,
       boitier.sku AS boitier_sku, boitier.name AS boitier,
       g.sku AS carte_graphique_sku, g.name AS carte_graphique,
       popularite_cm,
       round(cpu.price + mb.price + ram.price + boitier.price, 2) AS total_sans_gpu,
       round(cpu.price + mb.price + ram.price + boitier.price + coalesce(g.price, 0), 2) AS total_avec_gpu
ORDER BY popularite_cm DESC, total_sans_gpu ASC
LIMIT $limit
"""

SIMILAR = """
MATCH (p:Product {sku: $sku})-[:IN_CATEGORY]->(:Category)<-[:IN_CATEGORY]-(o:Product)
WHERE o <> p
WITH p, o,
     COUNT { (p)-[:HAS_SOCKET|SUPPORTS_MEMORY|HAS_MEMORY_TYPE|HAS_FORM_FACTOR|ACCEPTS_FORM_FACTOR]->()
             <-[:HAS_SOCKET|SUPPORTS_MEMORY|HAS_MEMORY_TYPE|HAS_FORM_FACTOR|ACCEPTS_FORM_FACTOR]-(o) } AS specs_communes,
     CASE WHEN EXISTS { (p)-[:MADE_BY]->(:Brand)<-[:MADE_BY]-(o) } THEN 1 ELSE 0 END AS meme_marque,
     CASE WHEN EXISTS { (p)-[:PART_OF]->(:Range)<-[:PART_OF]-(o) } THEN 1 ELSE 0 END AS meme_gamme,
     1.0 - abs(p.price - o.price) / CASE WHEN p.price > o.price THEN p.price ELSE o.price END AS proximite_prix
CALL (p, o) {
  OPTIONAL MATCH (p)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(o)
  RETURN count(DISTINCT c) AS clients_communs
}
RETURN o.sku AS sku, o.name AS nom, o.price AS prix, specs_communes, meme_marque, meme_gamme,
       round(proximite_prix, 2) AS proximite_prix, clients_communs,
       round(2 * specs_communes + meme_marque + meme_gamme + proximite_prix + 0.5 * clients_communs, 2) AS score
ORDER BY score DESC
LIMIT $limit
"""

PERSONALIZED = """
MATCH (me:Customer {id: $cid})-[:BOUGHT]->(:Product)<-[:BOUGHT]-(other:Customer)-[:BOUGHT]->(reco:Product)
WHERE other <> me
  AND reco.stock_status <> 'rupture'
  AND NOT EXISTS { (me)-[:BOUGHT]->(reco) }
  AND NOT EXISTS { (me)-[:BOUGHT]->(:Product)-[:IN_CATEGORY]->(:Category)<-[:IN_CATEGORY]-(reco) }
WITH me, reco, count(DISTINCT other) AS co_acheteurs
OPTIONAL MATCH (me)-[v:VIEWED]->(reco)
WITH me, reco, co_acheteurs, coalesce(v.count, 0) AS vues,
     COUNT { MATCH (me)-[:FRIEND_OF]-(f:Customer) WHERE EXISTS { (f)-[:BOUGHT]->(reco) } RETURN DISTINCT f } AS achats_amis,
     CASE WHEN EXISTS { (me)-[:BOUGHT]->(:Product)-[:HAS_SOCKET]->(:Socket)<-[:HAS_SOCKET]-(reco) }
            OR EXISTS { (me)-[:BOUGHT]->(:Product)-[:SUPPORTS_MEMORY]->(:MemoryType)<-[:HAS_MEMORY_TYPE]-(reco) }
          THEN 1 ELSE 0 END AS compatible_avec_mon_pc
RETURN reco.sku AS sku, reco.name AS nom, reco.price AS prix,
       co_acheteurs, vues, achats_amis, compatible_avec_mon_pc,
       co_acheteurs + 0.5 * vues + 2 * achats_amis + 3 * compatible_avec_mon_pc AS score
ORDER BY score DESC, prix
LIMIT $limit
"""

# Client sans historique : les produits les plus achetés (« démarrage à froid »)
POPULAR = """
MATCH (p:Product)<-[:BOUGHT]-(c:Customer)
WHERE p.stock_status <> 'rupture'
RETURN p.sku AS sku, p.name AS nom, p.price AS prix, count(DISTINCT c) AS acheteurs
ORDER BY acheteurs DESC
LIMIT $limit
"""

FRIEND_SUGGESTIONS = """
MATCH (me:Customer {id: $cid})-[:FRIEND_OF]-(ami:Customer)-[:FRIEND_OF]-(fof:Customer)
WHERE fof <> me AND NOT EXISTS { (me)-[:FRIEND_OF]-(fof) }
RETURN fof.id AS client, fof.pseudo AS pseudo, count(DISTINCT ami) AS amis_communs,
       collect(DISTINCT ami.pseudo) AS via
ORDER BY amis_communs DESC
LIMIT $limit
"""

CIRCLE_PURCHASES = """
MATCH path = (me:Customer {id: $cid})-[:FRIEND_OF*1..2]-(f:Customer)
WHERE f <> me
WITH me, f, min(length(path)) AS distance
MATCH (f)-[:BOUGHT]->(p:Product)
WHERE NOT EXISTS { (me)-[:BOUGHT]->(p) }
RETURN p.sku AS sku, p.name AS nom,
       count(DISTINCT f) AS personnes,
       collect(DISTINCT f.pseudo + ' (' + distance + ')') AS acheteurs_distance,
       round(sum(1.0 / distance), 2) AS score
ORDER BY score DESC
LIMIT $limit
"""

BOUGHT_WITH_UPSERT = """
MATCH (p1:Product)<-[:BOUGHT]-(c:Customer)
WITH p1, count(DISTINCT c) AS acheteurs
MATCH (p1)<-[:BOUGHT]-(c:Customer)-[:BOUGHT]->(p2:Product)
WHERE p1 <> p2
WITH p1, p2, acheteurs, count(DISTINCT c) AS communs
WHERE communs >= $min_customers
MERGE (p1)-[r:BOUGHT_WITH]->(p2)
  SET r.customers = communs, r.confidence = round(toFloat(communs) / acheteurs, 3), r.run_id = $run_id
RETURN count(r) AS relations
"""

BOUGHT_WITH_CLEANUP = """
MATCH ()-[r:BOUGHT_WITH]->()
WHERE r.run_id IS NULL OR r.run_id <> $run_id
DELETE r
RETURN count(*) AS supprimees
"""


def also_bought(sku: str, category: str | None, limit: int, live: bool) -> dict:
    rows = [] if live else cypher(ALSO_BOUGHT_MATERIALIZED, sku=sku, cat=category, limit=limit)
    source = "BOUGHT_WITH (matérialisé)"
    if not rows:
        rows = cypher(ALSO_BOUGHT_LIVE, sku=sku, cat=category, limit=limit)
        source = "calcul en direct (2 sauts)"
    return {"sku": sku, "source": source, "produits": rows}


def compatible(sku: str) -> dict:
    rows = cypher(COMPATIBLE, sku=sku)
    grouped: dict[str, list] = {}
    for r in rows:
        grouped.setdefault(r.pop("type"), []).append(r)
    return {"sku": sku, "compatibles": grouped}


def builder(cpu_sku: str, limit: int) -> list[dict]:
    return cypher(BUILDER, sku=cpu_sku, limit=limit)


def similar(sku: str, limit: int) -> list[dict]:
    return cypher(SIMILAR, sku=sku, limit=limit)


def personalized(cid: str, limit: int) -> dict:
    rows = cypher(PERSONALIZED, cid=cid, limit=limit)
    if rows:
        return {"client": cid, "strategie": "filtrage collaboratif + vues + amis + compatibilité", "produits": rows}
    return {"client": cid, "strategie": "démarrage à froid : produits les plus achetés",
            "produits": cypher(POPULAR, limit=limit)}


def friend_suggestions(cid: str, limit: int) -> list[dict]:
    return cypher(FRIEND_SUGGESTIONS, cid=cid, limit=limit)


def circle_purchases(cid: str, limit: int) -> list[dict]:
    return cypher(CIRCLE_PURCHASES, cid=cid, limit=limit)


def run_bought_with_job(min_customers: int = 2) -> dict:
    """Job nocturne : écrit les nouvelles relations PUIS supprime celles qui
    n'ont pas été recalculées — le site n'est jamais sans recommandations."""
    import uuid
    run_id = uuid.uuid4().hex
    created = cypher(BOUGHT_WITH_UPSERT, min_customers=min_customers, run_id=run_id)[0]["relations"]
    deleted = cypher(BOUGHT_WITH_CLEANUP, run_id=run_id)[0]["supprimees"]
    return {"run_id": run_id, "relations_bought_with": created, "relations_obsoletes_supprimees": deleted}
