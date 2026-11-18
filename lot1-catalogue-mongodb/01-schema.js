// =============================================================================
//  Refonte LDLC — Lot 1 : Catalogue produits (MongoDB)
//  01-schema.js — Création des collections, validation et index
//
//  Exécution :  mongosh "mongodb://localhost:27017/ldlc" 01-schema.js
//  (le script est idempotent : il supprime puis recrée les collections)
// =============================================================================
//
//  Pourquoi MongoDB pour le catalogue ?
//  -------------------------------------
//  - 27 000 produits répartis dans des centaines de catégories dont les
//    caractéristiques techniques n'ont rien en commun (un processeur a un
//    socket et un nombre de cœurs, une souris a un DPI et un poids...).
//    En relationnel, cela donne soit une table par catégorie, soit un modèle
//    EAV illisible et lent. Le modèle document stocke chaque fiche telle quelle.
//  - Le catalogue est lu des millions de fois par mois et modifié rarement :
//    on optimise pour la LECTURE en dénormalisant (une fiche produit = une
//    seule lecture, sans jointure).
//  - Le schéma doit évoluer sans migration : nouvelle catégorie, nouvelle
//    caractéristique → on insère simplement des documents avec de nouveaux
//    champs.
//
//  Collections
//  -----------
//    categories : arbre des catégories (pattern Array of Ancestors)
//    brands     : référentiel des ~600 marques
//    products   : fiches produits (Polymorphic, Extended Reference, Subset,
//                 Computed, Schema Versioning)
//    reviews    : TOUS les avis clients (le sous-ensemble récent est aussi
//                 embarqué dans products — pattern Subset)
// =============================================================================

db = db.getSiblingDB("ldlc");

["categories", "brands", "products", "reviews"].forEach((c) => {
  if (db.getCollectionNames().includes(c)) db.getCollection(c).drop();
});

// -----------------------------------------------------------------------------
//  1. categories — pattern ARRAY OF ANCESTORS
// -----------------------------------------------------------------------------
//  Chaque catégorie stocke son parent direct ET la liste ordonnée de tous ses
//  ancêtres (de la racine vers le parent), avec leur nom.
//    - fil d'Ariane : une seule lecture de la catégorie, sans récursivité ;
//    - « toutes les sous-catégories de Composants » : une requête indexée
//      sur ancestors._id, sans $graphLookup.
//  L'arbre change très rarement : le coût de mise à jour (réécrire les
//  ancêtres des descendants lors d'un déplacement) est acceptable.
//
//  Exemple :
//  { _id: "processeurs", name: "Processeurs", parent: "composants",
//    ancestors: [ { _id: "informatique", name: "Informatique" },
//                 { _id: "composants",   name: "Composants" } ] }
// -----------------------------------------------------------------------------
db.createCollection("categories", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "name", "parent", "ancestors"],
      properties: {
        _id:    { bsonType: "string", description: "slug de la catégorie" },
        name:   { bsonType: "string", minLength: 2 },
        parent: { bsonType: ["string", "null"], description: "null pour une racine" },
        ancestors: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["_id", "name"],
            properties: {
              _id:  { bsonType: "string" },
              name: { bsonType: "string" }
            }
          }
        }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

db.categories.createIndex({ "ancestors._id": 1 }, { name: "idx_cat_ancetres" });
db.categories.createIndex({ parent: 1 },          { name: "idx_cat_parent" });

// -----------------------------------------------------------------------------
//  2. brands — référentiel des marques
// -----------------------------------------------------------------------------
//  Source de vérité des marques. Les produits n'en copient que les champs
//  utiles à l'affichage (pattern Extended Reference, voir products).
// -----------------------------------------------------------------------------
db.createCollection("brands", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "name"],
      properties: {
        _id:     { bsonType: "string" },
        name:    { bsonType: "string" },
        country: { bsonType: "string" },
        logo:    { bsonType: "string" }
      }
    }
  }
});

// -----------------------------------------------------------------------------
//  3. products — la collection centrale
// -----------------------------------------------------------------------------
//  Patterns appliqués (voir 02-sample-data.js pour des exemples concrets) :
//
//  • POLYMORPHIC : tous les produits (CPU, carte mère, souris, logiciel...)
//    vivent dans la même collection. Le champ `type` indique la « forme »
//    du document et le sous-document `specs` contient les caractéristiques
//    propres à ce type. Une seule collection = une seule recherche, un seul
//    listing, un seul panier, quel que soit le type de produit.
//
//  • EXTENDED REFERENCE : `brand` et `category` ne sont pas de simples
//    identifiants, on y copie les champs nécessaires à l'affichage
//    ({_id, name} pour la marque, {_id, name, path} pour la catégorie).
//    Idem pour `compatible[]` ({sku, name, type}). On évite ainsi un
//    $lookup à chaque affichage. On ne copie QUE des champs stables
//    (le nom d'une marque change rarement ; le prix d'un produit compatible,
//    trop volatil, n'est PAS copié).
//
//  • SUBSET : `latest_reviews` contient au plus les 5 avis les plus récents
//    (ceux affichés sur la fiche). L'intégralité des avis est dans la
//    collection `reviews`, chargée seulement si l'internaute clique sur
//    « voir tous les avis ». Le document produit reste petit (limite 16 Mo,
//    working set en RAM).
//
//  • COMPUTED : `rating` = { average, count, distribution } est calculé à
//    l'écriture d'un avis plutôt qu'à chaque lecture. Lire une moyenne
//    stockée coûte 0 ; recalculer AVG() sur des milliers d'avis à chaque
//    affichage de listing serait ruineux.
//
//  • SCHEMA VERSIONING : `schema_version` indique la version de structure du
//    document. L'application sait lire v1 et v2 ; les documents v1 sont
//    migrés paresseusement (à leur prochaine écriture) ou par un batch en
//    tâche de fond — jamais de migration bloquante.
//      v1 : note à plat (rating_avg, reviews_count), une seule image (image),
//           pas d'avis embarqués.
//      v2 : rating {average, count, distribution}, images[], latest_reviews[].
//
//  • ARRAY OF ANCESTORS (côté produit) : `category.path` contient la
//    catégorie et tous ses ancêtres → « tous les produits de Composants »
//    est une simple égalité indexée sur category.path.
//
//  Validation : le $jsonSchema ne contrôle QUE les champs communs à tous les
//  produits, quelle que soit leur version ou leur type. `specs` doit être un
//  objet, mais son contenu est libre : ajouter une catégorie ou une
//  caractéristique ne demande ni migration ni modification du validateur.
//  `type` n'est volontairement PAS une énumération, pour la même raison.
// -----------------------------------------------------------------------------
db.createCollection("products", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      title: "Champs communs à tous les produits LDLC",
      required: ["_id", "schema_version", "type", "name", "brand", "category",
                 "price", "stock", "specs"],
      properties: {
        _id: {
          bsonType: "string",
          pattern: "^[A-Z0-9-]+$",
          description: "SKU LDLC, sert aussi de clé dans Redis (cache:product:<sku>)"
        },
        schema_version: { bsonType: "int", minimum: 1 },
        type:           { bsonType: "string", description: "discriminant du pattern Polymorphic" },
        name:           { bsonType: "string", minLength: 3 },
        brand: {
          bsonType: "object",
          required: ["_id", "name"],
          properties: {
            _id:  { bsonType: "string" },
            name: { bsonType: "string" }
          }
        },
        category: {
          bsonType: "object",
          required: ["_id", "name", "path"],
          properties: {
            _id:  { bsonType: "string" },
            name: { bsonType: "string" },
            path: { bsonType: "array", minItems: 1, items: { bsonType: "string" } }
          }
        },
        price: {
          bsonType: "object",
          required: ["amount", "currency"],
          properties: {
            amount:   { bsonType: "decimal", minimum: 0 },
            currency: { enum: ["EUR"] }
          }
        },
        stock: {
          bsonType: "object",
          required: ["quantity", "status"],
          properties: {
            quantity: { bsonType: "int", minimum: 0 },
            status:   { enum: ["en_stock", "stock_faible", "rupture", "precommande"] }
          }
        },
        specs:          { bsonType: "object", description: "contenu libre selon le type" },
        latest_reviews: { bsonType: "array", maxItems: 5, description: "pattern Subset" },
        compatible:     { bsonType: "array" }
      }
      // additionalProperties non précisé (= true) : tout autre champ est accepté.
    }
  },
  // "moderate" : les documents déjà invalides (anciens imports) peuvent
  // toujours être mis à jour, les nouveaux doivent être valides.
  validationLevel: "moderate",
  validationAction: "error"
});

// --- Index de products -------------------------------------------------------
// Le catalogue est majoritairement lu : on peut se permettre plusieurs index.

// Listing par catégorie (inclut toutes les sous-catégories grâce à path)
// trié par prix.
db.products.createIndex(
  { "category.path": 1, "price.amount": 1 },
  { name: "idx_listing_categorie_prix" }
);

// Filtre / page marque.
db.products.createIndex({ "brand._id": 1 }, { name: "idx_marque" });

// Tri « meilleures notes ».
db.products.createIndex({ "rating.average": -1 }, { name: "idx_note" });

// Recherche inverse de compatibilité : « quels produits déclarent ce SKU
// comme compatible ? » (index multiclé sur le tableau).
db.products.createIndex({ "compatible.sku": 1 }, { name: "idx_compatibles" });

// INDEX WILDCARD sur specs : indexe automatiquement TOUS les champs de specs,
// quels qu'ils soient (specs.socket, specs.dpi, specs.memory_type...).
// Indispensable avec le pattern Polymorphic : on ne peut pas créer à
// l'avance un index par caractéristique de chaque catégorie, et une
// nouvelle caractéristique est indexée dès son premier document.
db.products.createIndex({ "specs.$**": 1 }, { name: "idx_wildcard_specs" });

// Recherche plein texte en français (barre de recherche).
// (En production : Atlas Search / Elasticsearch, plus riche en pertinence.)
db.products.createIndex(
  { name: "text", "brand.name": "text", description: "text" },
  {
    name: "idx_texte",
    default_language: "french",
    weights: { name: 10, "brand.name": 5, description: 1 }
  }
);

// Retrouver les documents encore en ancienne version (migration progressive).
db.products.createIndex({ schema_version: 1 }, { name: "idx_version_schema" });

// -----------------------------------------------------------------------------
//  4. reviews — tous les avis (le côté « reste » du pattern Subset)
// -----------------------------------------------------------------------------
db.createCollection("reviews", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["product_id", "author", "rating", "date"],
      properties: {
        product_id: { bsonType: "string" },
        author: {
          bsonType: "object",
          required: ["user_id", "pseudo"],
          properties: {
            user_id: { bsonType: "string" },
            pseudo:  { bsonType: "string" }
          }
        },
        rating:            { bsonType: "int", minimum: 1, maximum: 5 },
        title:             { bsonType: "string" },
        comment:           { bsonType: "string" },
        date:              { bsonType: "date" },
        verified_purchase: { bsonType: "bool" }
      }
    }
  }
});

// Pagination des avis d'un produit, du plus récent au plus ancien.
db.reviews.createIndex({ product_id: 1, date: -1 }, { name: "idx_avis_produit_date" });
// Un client ne dépose qu'un avis par produit.
db.reviews.createIndex(
  { product_id: 1, "author.user_id": 1 },
  { name: "idx_avis_unique_client", unique: true }
);

// -----------------------------------------------------------------------------
//  Récapitulatif
// -----------------------------------------------------------------------------
print("=== Collections créées dans la base 'ldlc' ===");
["categories", "brands", "products", "reviews"].forEach((c) => {
  print(`\n# ${c}`);
  db.getCollection(c).getIndexes().forEach((i) => print("  - " + i.name + " " + JSON.stringify(i.key)));
});
