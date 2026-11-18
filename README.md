# Refonte LDLC — Architecture de données NoSQL

**Membre :** OUZANIK Oualid

Conception de l'architecture de données de LDLC, site e-commerce high-tech : 27 000 produits, 600 marques, plusieurs millions de visites par mois, jusqu'à 25 000 colis par jour.

## Architecture en bref

Une API **sans état** derrière un load balancer, et une base par besoin (persistance polyglotte) :

| Lot | Base | Rôle | CAP |
|-----|------|------|-----|
| 1 | **MongoDB** | catalogue à schéma variable, très lu (patterns Polymorphic, Extended Reference, Subset, Computed, Schema Versioning, Array of Ancestors) | CP |
| 2 | **Redis** | sessions partagées, paniers et cache, en sub-milliseconde avec TTL glissants (ajout au panier atomique en Lua) | AP |
| 3 | **Cassandra** | événements de navigation, compteurs, top de la semaine et historique de commandes (une table par requête) | AP, cohérence réglable |
| 4 | **Neo4j** | co-achats, compatibilités déduites par parcours, configurateur PC, recommandations | CP |

En cible, un bus **Kafka** et des **jobs nocturnes** (top hebdomadaire, `BOUGHT_WITH`, réconciliation) relient les bases. Schémas : [docs/architecture.md](docs/architecture.md).

## Livrables

| Livrable | Contenu |
|----------|---------|
| [docs/architecture.md](docs/architecture.md) | schéma global (Mermaid), positions CAP, séquences « fiche produit » et « panier → commande » |
| [docs/conception.md](docs/conception.md) | dossier de conception : choix et alternatives, schémas, patterns, CAP, cohérence entre les bases |
| [lot1-catalogue-mongodb/](lot1-catalogue-mongodb/) | `01-schema.js` (validation, index dont wildcard), `02-sample-data.js` (14 produits), `queries.js` (18 requêtes) |
| [lot2-panier-sessions-redis/](lot2-panier-sessions-redis/) | `commands.redis` (clés, TTL, hash tags), `cart_add.lua` (ajout atomique plafonné) |
| [lot3-logs-analytics-cassandra/](lot3-logs-analytics-cassandra/) | `schema.cql` (7 tables, TTL, TWCS, UDT), `queries.cql` |
| [lot4-recommandations-neo4j/](lot4-recommandations-neo4j/) | `01-schema.cypher`, `02-sample-data.cypher`, `queries.cypher` |
| [api/](api/) + [docker-compose.yml](docker-compose.yml) | prototype FastAPI sur les 4 bases, seed et script de démonstration |

## Lancer le prototype

Prérequis : Docker avec Compose, curl et python3.

```bash
docker compose up -d --build     # ~2 min la première fois (Cassandra)
./api/demo.sh                    # scénario complet : catalogue → panier → connexion → recommandations → commande → analytics
```

- Documentation interactive : <http://localhost:8000/docs>
- Port déjà occupé ? Les ports se surchargent par variables (voir [.env.example](.env.example)), par exemple `MONGO_PORT=27018 docker compose up -d --build`.
- Arrêt : `docker compose down` (ajouter `-v` pour effacer les données).

Au démarrage, MongoDB charge les scripts du lot 1, deux conteneurs d'initialisation exécutent ceux des lots 3 et 4, puis un seed génère commandes et événements datés par rapport au jour courant.

Chaque script se lance aussi seul, par exemple `mongosh ldlc lot1-catalogue-mongodb/queries.js` ou `cqlsh -f lot3-logs-analytics-cassandra/queries.cql`.

## Principaux endpoints

La session se transmet par l'en-tête `X-Session-Id` (renvoyé par `POST /sessions`) ; la connexion est simulée (`{"customer_id": "user:42"}`).

| Endpoint | Bases | Rôle |
|----------|-------|------|
| `GET /produits?categorie=composants&specs.socket=AM5&specs.cores=gte:8` | MongoDB | listing filtré + facettes |
| `GET /produits/{sku}` | Redis → MongoDB | fiche en cache-aside (en-tête `X-Cache`) |
| `POST /sessions`, `POST /sessions/connexion` | Redis | session, puis connexion avec fusion du panier |
| `POST /panier/articles`, `GET /panier` | Redis | ajout atomique plafonné (Lua), panier enrichi |
| `POST /evenements` | Cassandra, Redis, Neo4j | traçage de la navigation |
| `POST /commandes` | MongoDB → Cassandra → Neo4j | stock, commande, relations d'achat |
| `GET /clients/{id}/commandes` | Cassandra | historique de commandes |
| `GET /analytics/produits/{sku}/vues`, `GET /analytics/top-semaine` | Cassandra | vues du jour, top hebdomadaire |
| `GET /recommandations/produits/{sku}/aussi-achetes` | Neo4j | « ont aussi acheté » |
| `GET /recommandations/produits/{sku}/compatibles` | Neo4j | compatibilités déduites |
| `GET /recommandations/configurateur?cpu={sku}` | Neo4j | configuration complète |
| `GET /recommandations/clients/{id}` | Neo4j | recommandations personnalisées |
