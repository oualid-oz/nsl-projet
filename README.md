# Refonte LDLC — Architecture de données NoSQL

**Auteur :** OUZANIK Oualid

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

## Bonus — prototype d'API sur les 4 bases

Un [docker-compose.yml](docker-compose.yml) démarre les quatre bases, les initialise avec les scripts des lots, génère des données datées par rapport au jour courant, puis lance une API FastAPI ([api/](api/)).

```bash
docker compose up -d --build        # ~2 min au premier démarrage (Cassandra)
./api/demo.sh                       # scénario complet en curl
# Documentation interactive : http://localhost:8000/docs
```

Les ports exposés se surchargent par variables (voir [.env.example](.env.example)), par exemple `MONGO_PORT=27018 docker compose up -d` si un MongoDB local occupe déjà 27017.

| Service | Rôle |
|---------|------|
| `mongo` | charge `lot1/01-schema.js` et `02-sample-data.js` via `docker-entrypoint-initdb.d` |
| `redis` | sessions, paniers, cache (AOF activé) |
| `cassandra` + `cassandra-init` | `lot3/schema.cql` |
| `neo4j` + `neo4j-init` | `lot4/01-schema.cypher`, puis `02-sample-data.cypher` si le graphe est vide |
| `seed` | commandes sur 180 jours, compteurs sur 14 jours, événements bruts, top de la semaine, `BOUGHT_WITH` (une seule fois) |
| `api` | FastAPI, un router par lot |

| Router | Routes principales | Bases |
|--------|--------------------|-------|
| Lot 1 — catalogue | `GET /produits` (filtres `specs.*`, facettes, texte), `GET /produits/{sku}` (cache-aside, en-tête `X-Cache`), `POST /produits/{sku}/avis`, `PATCH /produits/{sku}/prix`, `GET /categories/{id}` | MongoDB, Redis |
| Lot 2 — panier | `POST /sessions`, `POST /sessions/connexion` (fusion du panier), `POST /panier/articles` (script Lua), `PUT/DELETE /panier/articles/{sku}`, `GET /panier`, `GET /historique` | Redis |
| Lot 3 — analytics | `POST /evenements`, `GET /analytics/produits/{sku}/vues`, `GET /analytics/top-semaine`, `POST /analytics/jobs/top-semaine`, `POST /commandes`, `GET /clients/{id}/commandes`, `PATCH /commandes/{id}/statut` | Cassandra, Neo4j, MongoDB |
| Lot 4 — recommandations | `…/aussi-achetes`, `…/compatibles`, `…/similaires`, `/configurateur`, `/clients/{id}`, `…/entourage`, `POST /recommandations/jobs/bought-with` | Neo4j |

La session se transmet par l'en-tête `X-Session-Id` (ou le cookie `sid`). La connexion est simulée (`{"customer_id": "user:42"}`, sans mot de passe).

## Suite du document

> _À compléter : choix d'architecture globale, justification des technologies (théorème CAP, modèles de cohérence), lots suivants, schémas d'ensemble, limites et perspectives._
