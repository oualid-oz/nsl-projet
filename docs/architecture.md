# Architecture globale — Refonte LDLC

Ce document présente l'architecture **cible** (production) et indique, quand ils diffèrent, les raccourcis pris par le prototype (`docker-compose.yml` + `api/`).

## 1. Vue d'ensemble

Persistance polyglotte : chaque besoin métier est servi par la base dont le modèle de données lui correspond. Les serveurs d'API sont **sans état** : toute donnée de session vit dans Redis, ce qui permet d'ajouter ou de retirer des serveurs pendant les pics (soldes, Black Friday) sans « sticky sessions ».

```mermaid
flowchart LR
    subgraph CLIENTS["Clients"]
        WEB["Navigateur<br/>ldlc.com"]
        APP["Application mobile"]
    end

    LB["Load balancer HTTPS<br/>round-robin, sans affinité"]

    subgraph API["API sans état (N instances)"]
        API1["API 1"]
        API2["API 2"]
        APIN["API N"]
    end

    subgraph DATA["Bases de données"]
        REDIS[("Redis Cluster<br/>sessions, paniers, cache<br/>AP")]
        MONGO[("MongoDB replica set<br/>catalogue, avis<br/>CP")]
        CASS[("Cassandra, RF=3<br/>événements, compteurs, commandes<br/>AP, cohérence réglable")]
        NEO[("Neo4j cluster<br/>recommandations, compatibilités<br/>CP")]
    end

    subgraph BUS["Bus d'événements Kafka"]
        T1["topic navigation"]
        T2["topic commandes"]
        T3["topic produits<br/>(Change Streams MongoDB)"]
    end

    subgraph JOBS["Consumers et jobs batch"]
        C1["Ingestion événements<br/>pré-agrégation par minute"]
        C2["Synchronisation graphe<br/>achats, produits"]
        C3["Invalidation du cache"]
        B1["Job nocturne : top de la semaine"]
        B2["Job nocturne : BOUGHT_WITH"]
        B3["Job nocturne : réconciliation des notes"]
    end

    WEB --> LB
    APP --> LB
    LB --> API1 & API2 & APIN

    API1 & API2 & APIN -->|"sessions, panier, cache"| REDIS
    API1 & API2 & APIN -->|"fiches, listings, stock"| MONGO
    API1 & API2 & APIN -->|"commandes, historique, top"| CASS
    API1 & API2 & APIN -->|"recommandations"| NEO
    API1 & API2 & APIN -->|"événements, commandes"| T1 & T2

    MONGO -. "Change Streams" .-> T3
    T1 --> C1 --> CASS
    T2 --> C2
    C1 -->|"VIEWED"| NEO
    C2 -->|"BOUGHT"| NEO
    T3 --> C3 -->|"DEL cache:product"| REDIS
    T3 --> C2

    CASS --> B1 --> CASS
    NEO --> B2 --> NEO
    MONGO --> B3 --> MONGO
```

### Rôle et position CAP de chaque base

| Base | Données | Position CAP | Justification |
|------|---------|--------------|---------------|
| **MongoDB** (replica set de 3 nœuds) | Catalogue (27 000 fiches), catégories, marques, avis | **CP** | Un seul primaire accepte les écritures ; pendant une élection (quelques secondes), les écritures sont refusées plutôt que divergentes. Un prix ou un stock ne doit pas être incohérent. |
| **Redis Cluster** (3 primaires + 3 réplicas) | Sessions, paniers, historique de navigation, cache des fiches | **AP** | Réplication asynchrone : lors d'une bascule, la dernière seconde d'écritures peut être perdue, mais le service reste disponible. Acceptable pour des données éphémères et reconstructibles. |
| **Cassandra** (RF = 3, multi-nœuds) | Événements de navigation, compteurs, top hebdomadaire, historique de commandes | **AP**, cohérence **réglable** par requête | Pas de maître : un nœud en panne ne bloque rien. `ONE` pour les événements, `LOCAL_QUORUM` pour les commandes (cohérence forte puisque R + W > RF). |
| **Neo4j** (cluster, 3 primaires) | Graphe produits, clients, achats, caractéristiques | **CP** | Les écritures passent par un leader élu par consensus Raft ; les lectures peuvent aller sur des réplicas avec cohérence causale (bookmarks). |

### Flux asynchrones (cible) et prototype

| Flux | Architecture cible | Prototype |
|------|--------------------|-----------|
| Événement de navigation | API → Kafka `navigation` → consumer qui pré-agrège par minute → Cassandra (brut + compteurs) et Neo4j (`VIEWED`) | L'API écrit directement dans Cassandra, Redis et Neo4j (`services/events.py`) |
| Commande | API → MongoDB (stock) → Cassandra (`BATCH LOGGED`) → Kafka `commandes` → Neo4j, entrepôt, paiement | Écritures directes dans MongoDB, Cassandra et Neo4j (`services/orders.py`) |
| Modification d'un produit | Change Streams MongoDB → Kafka `produits` → `DEL cache:product:<sku>` + mise à jour du graphe | L'API invalide le cache et met à jour Neo4j après l'écriture (`PATCH /produits/{sku}/prix`) |
| Top de la semaine | Job Spark nocturne sur `daily_product_views` | `POST /analytics/jobs/top-semaine` (et le seed) |
| Co-achats | Job nocturne `BOUGHT_WITH` | `POST /recommandations/jobs/bought-with` (et le seed) |

Kafka découple l'API des écritures secondaires : un pic de trafic ou une base lente n'allonge pas le temps de réponse, et un message non traité est rejoué. Il n'est pas inclus dans le prototype pour garder une stack légère (8 conteneurs).

## 2. Séquence : affichage d'une fiche produit

Chemin le plus fréquent du site (millions de fois par mois) : il ne touche **que Redis** quand le cache est chaud.

```mermaid
sequenceDiagram
    autonumber
    actor V as Visiteur
    participant LB as Load balancer
    participant API as API (instance quelconque)
    participant R as Redis
    participant M as MongoDB
    participant N as Neo4j
    participant K as Kafka
    participant C as Cassandra

    V->>LB: GET /produits/CPU-AMD-R7-7800X3D (cookie sid)
    LB->>API: requête (pas d'affinité de session)
    API->>R: HGETALL sess:{sid} + EXPIRE 1800 (pipeline)
    R-->>API: session (TTL glissant relancé)
    API->>R: GET cache:product:CPU-AMD-R7-7800X3D
    alt cache HIT
        R-->>API: JSON de la fiche
    else cache MISS
        R-->>API: nil
        API->>M: findOne({_id: sku}) via index _id
        M-->>API: document complet (marque, catégorie, specs, note, 5 derniers avis)
        API->>R: SET cache:product:sku JSON EX 3600 + aléa
    end
    API-->>V: 200 fiche (en-tête X-Cache)

    par Blocs secondaires de la page (appels parallèles)
        V->>API: GET /recommandations/produits/sku/aussi-achetes
        API->>N: BOUGHT_WITH (1 saut, matérialisé la nuit)
        N-->>API: produits + confiance
        API-->>V: 200
    and Traçage
        V->>API: POST /evenements (page_view)
        API->>R: LREM + LPUSH + LTRIM + EXPIRE recent:{owner} (MULTI)
        API->>K: événement page_view
        API-->>V: 201
        K->>C: INSERT events_by_hour (heure, shard) + compteurs
        K->>N: MERGE VIEWED (client connecté)
    end
```

Points clés :

- **une seule lecture MongoDB** en cas de MISS, grâce aux patterns Extended Reference, Subset et Computed (aucune jointure) ;
- la recommandation n'est **pas** calculée en direct : la relation `BOUGHT_WITH` est pré-calculée, ce qui donne un parcours à 1 saut, quelle que soit la popularité du produit ;
- le traçage est **asynchrone** : une panne de Cassandra ne dégrade pas l'affichage.

## 3. Séquence : du panier à la commande

```mermaid
sequenceDiagram
    autonumber
    actor V as Visiteur
    participant API as API
    participant R as Redis
    participant M as MongoDB
    participant C as Cassandra
    participant N as Neo4j
    participant K as Kafka

    Note over V,R: Visiteur anonyme, owner = anon:sid
    V->>API: POST /panier/articles {sku, quantite: 15}
    API->>R: GET cache:product:sku (type, stock)
    API->>R: EVALSHA cart_add.lua cart:{anon:sid} sku 15 3 259200
    Note right of R: Atomique : HGET, plafond, HSET, EXPIRE
    R-->>API: {3, plafonnee: 1, lignes: 1}
    API-->>V: 200 quantité plafonnée à 3

    V->>API: POST /sessions/connexion {customer_id: user:42}
    API->>R: HSET sess:{nouveau_sid} (anti-fixation de session)
    loop pour chaque ligne du panier anonyme
        API->>R: EVALSHA cart_add.lua cart:{user:42} (plafond respecté)
    end
    API->>R: DEL cart:{anon:sid}, DEL sess:{ancien_sid}
    API-->>V: 200 nouveau sid + lignes fusionnées

    V->>API: POST /commandes
    API->>R: HGETALL cart:{user:42}
    API->>M: find prix ACTUELS (pas ceux du cache)
    loop pour chaque ligne
        API->>M: findOneAndUpdate stock.quantity >= qte, $subtract
        alt stock insuffisant
            M-->>API: null
            API->>M: compensation, restock des lignes déjà réservées
            API-->>V: 409 Stock insuffisant
        end
    end
    API->>C: BATCH LOGGED orders_by_customer + orders_by_id (LOCAL_QUORUM)
    API->>N: MERGE (client)-[:BOUGHT {order_id}]->(produit)
    API->>R: DEL cart:{user:42}, DEL cache:product des produits touchés
    API->>K: commande.creee (entrepôt, paiement, e-mails)
    API-->>V: 201 commande LD...
```

Points clés :

- **pas de transaction distribuée** entre les quatre bases : la commande suit une **saga** (réservation du stock, puis compensation en cas d'échec) ;
- le décrément de stock est **atomique et conditionnel** côté MongoDB : le filtre `stock.quantity >= qte` et la mise à jour s'appliquent ensemble, donc deux clients ne peuvent pas acheter la dernière unité ;
- la commande est écrite dans **deux tables Cassandra** (une par requête) dans un `BATCH LOGGED` : les deux copies finissent toujours par être écrites toutes les deux ;
- l'écriture Neo4j est **idempotente** (`MERGE` sur `order_id`) : elle peut être rejouée sans doublon.
