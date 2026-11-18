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

## Exécution rapide

```bash
# Lot 1 — MongoDB
mongosh "mongodb://localhost:27017/ldlc" lot1-catalogue-mongodb/01-schema.js
mongosh "mongodb://localhost:27017/ldlc" lot1-catalogue-mongodb/02-sample-data.js
mongosh "mongodb://localhost:27017/ldlc" lot1-catalogue-mongodb/queries.js

# Lot 2 — Redis
grep -Ev '^\s*(#|$)' lot2-panier-sessions-redis/commands.redis | redis-cli
redis-cli --eval lot2-panier-sessions-redis/cart_add.lua 'cart:{user:42}' , CPU-AMD-R7-7800X3D 2 10 2592000
```

## Suite du document

> _À compléter : choix d'architecture globale, justification des technologies (théorème CAP, modèles de cohérence), lots suivants, schémas d'ensemble, limites et perspectives._
