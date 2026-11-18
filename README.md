# Refonte LDLC — Architecture de données NoSQL

**Auteur :** OUZANIK Oualid — projet réalisé seul

---

## Contexte

LDLC est un site e-commerce français spécialisé dans le high-tech :

- environ **27 000 produits** et **600 marques** ;
- **plusieurs millions de visites** par mois ;
- jusqu'à **25 000 colis expédiés par jour**.

L'objectif est de concevoir une architecture de données NoSQL (persistance polyglotte) adaptée à chaque besoin métier.

## Organisation du dépôt

| Lot | Dossier | Technologie | Besoin |
|-----|---------|-------------|--------|
| 1 | [lot1-catalogue-mongodb/](lot1-catalogue-mongodb/) | MongoDB | Catalogue produits : schémas variables, forte lecture |
| 2 | [lot2-panier-sessions-redis/](lot2-panier-sessions-redis/) | Redis | Panier et sessions : latence sub-milliseconde, expiration |
| 3 | [lot3-logs-analytics-cassandra/](lot3-logs-analytics-cassandra/) | Cassandra | Logs de navigation et historique de commandes : écritures massives, rétention longue |
| 4 | [lot4-recommandations-neo4j/](lot4-recommandations-neo4j/) | Neo4j | Recommandations et compatibilités : parcours de relations |

## Exécution rapide

```bash
# Lot 1 — MongoDB
mongosh "mongodb://localhost:27017/ldlc" lot1-catalogue-mongodb/01-schema.js
mongosh "mongodb://localhost:27017/ldlc" lot1-catalogue-mongodb/02-sample-data.js
mongosh "mongodb://localhost:27017/ldlc" lot1-catalogue-mongodb/queries.js

# Lot 2 — Redis
grep -Ev '^\s*(#|$)' lot2-panier-sessions-redis/commands.redis | redis-cli
redis-cli --eval lot2-panier-sessions-redis/cart_add.lua 'cart:{user:42}' , CPU-AMD-R7-7800X3D 2 10 2592000

# Lot 3 — Cassandra
cqlsh -f lot3-logs-analytics-cassandra/schema.cql
cqlsh -f lot3-logs-analytics-cassandra/queries.cql

# Lot 4 — Neo4j 5
cypher-shell -u neo4j -p <mdp> -f lot4-recommandations-neo4j/01-schema.cypher
cypher-shell -u neo4j -p <mdp> -f lot4-recommandations-neo4j/02-sample-data.cypher
cypher-shell -u neo4j -p <mdp> -f lot4-recommandations-neo4j/queries.cypher
```

Les identifiants sont communs à tous les lots : SKU du catalogue (`CPU-AMD-R7-7800X3D`…), clients `user:…`, numéros de commande `LD…`.

## Suite du document

> _À compléter : choix d'architecture globale, justification des technologies (théorème CAP, modèles de cohérence), lots suivants, schémas d'ensemble, limites et perspectives._
