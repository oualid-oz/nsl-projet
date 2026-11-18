// =============================================================================
//  Refonte LDLC — Lot 1 : Catalogue produits (MongoDB)
//  queries.js — Requêtes types du site, commentées par pattern
//
//  Exécution (après 01-schema.js et 02-sample-data.js) :
//    mongosh "mongodb://localhost:27017/ldlc" queries.js
//
//  Attention : Q12, Q13, Q15 et Q18 MODIFIENT les données (ajout d'avis,
//  migration, renommage). Pour repartir d'un état propre, relancer
//  02-sample-data.js avant chaque exécution.
// =============================================================================

db = db.getSiblingDB("ldlc");

const titre = (t) => print("\n" + "=".repeat(78) + "\n " + t + "\n" + "=".repeat(78));

// Projection « carte produit » utilisée dans tous les listings.
const CARTE = { name: 1, "brand.name": 1, "price.amount": 1, "stock.status": 1, "rating.average": 1, "rating.count": 1 };

// -----------------------------------------------------------------------------
titre("Q1. Fiche produit — UNE seule lecture, sans jointure");
// -----------------------------------------------------------------------------
//  Grâce à Extended Reference (marque, catégorie, compatibles), Subset
//  (5 derniers avis) et Computed (note), tout ce qu'affiche la page produit
//  est dans un seul document, lu via l'index _id. C'est ce document qui est
//  mis en cache dans Redis (cache:product:<sku>, voir lot 2).
printjson(db.products.findOne({ _id: "CPU-AMD-R7-7800X3D" }));

// -----------------------------------------------------------------------------
titre("Q2. Fil d'Ariane d'une catégorie — ARRAY OF ANCESTORS");
// -----------------------------------------------------------------------------
//  Une lecture suffit, sans parcours récursif de l'arbre.
const cat = db.categories.findOne({ _id: "processeurs" });
print([...cat.ancestors.map((a) => a.name), cat.name].join(" > "));

// -----------------------------------------------------------------------------
titre("Q3. Toutes les sous-catégories de « Composants » — ARRAY OF ANCESTORS");
// -----------------------------------------------------------------------------
//  Égalité sur un tableau (index multiclé idx_cat_ancetres), quelle que soit
//  la profondeur.
db.categories.find({ "ancestors._id": "composants" }, { name: 1 }).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q4. Listing « Composants » (toutes sous-catégories) trié par prix");
// -----------------------------------------------------------------------------
//  category.path contient la catégorie ET ses ancêtres : un seul critère
//  d'égalité ramène les produits de toutes les sous-catégories.
//  Index utilisé : idx_listing_categorie_prix (égalité + tri).
db.products.find({ "category.path": "composants" }, CARTE)
  .sort({ "price.amount": 1 })
  .limit(20)
  .forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q5. Filtres techniques — POLYMORPHIC + INDEX WILDCARD");
// -----------------------------------------------------------------------------
//  « Processeurs AM5 avec au moins 8 cœurs » : les champs specs.socket et
//  specs.cores n'ont jamais été déclarés nulle part, pourtant ils sont indexés
//  par idx_wildcard_specs.
db.products.find(
  { type: "processeur", "specs.socket": "AM5", "specs.cores": { $gte: 8 } },
  CARTE
).forEach(printjson);

//  « Kits DDR5 de 32 Go à 6000 MHz minimum »
db.products.find(
  { "specs.memory_type": "DDR5", "specs.capacity_gb": 32, "specs.frequency_mhz": { $gte: 6000 }, type: "memoire" },
  CARTE
).forEach(printjson);

//  Preuve que l'index wildcard est utilisé :
const plan = db.products.find({ "specs.socket": "AM5" }).explain("queryPlanner");
const idx = JSON.stringify(plan.queryPlanner.winningPlan).match(/"indexName":"([^"]+)"/);
print("Index choisi pour specs.socket : " + (idx ? idx[1] : "aucun (COLLSCAN)"));

// -----------------------------------------------------------------------------
titre("Q6. Polymorphisme — un même critère sur des types différents");
// -----------------------------------------------------------------------------
//  « Tout ce qui est en socket AM5 » renvoie à la fois des processeurs et des
//  cartes mères, depuis la même collection.
db.products.find({ "specs.socket": "AM5" }, { type: 1, name: 1 }).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q7. Produits compatibles — EXTENDED REFERENCE");
// -----------------------------------------------------------------------------
//  a) Affichage direct depuis la fiche : aucun $lookup, nom et type sont copiés.
printjson(db.products.findOne({ _id: "CPU-AMD-R7-7800X3D" }, { _id: 0, compatible: 1 }));

//  b) Pour afficher les prix À JOUR des compatibles (non copiés car volatils),
//     on fait une seconde requête ciblée par _id ($in), toujours indexée.
const skus = db.products.findOne({ _id: "CPU-AMD-R7-7800X3D" }).compatible.map((c) => c.sku);
db.products.find({ _id: { $in: skus } }, { name: 1, "price.amount": 1, "stock.status": 1 }).forEach(printjson);

//  c) Recherche inverse : « quels produits déclarent la RAM Corsair compatible ? »
//     (index multiclé idx_compatibles)
db.products.find({ "compatible.sku": "RAM-CORSAIR-DDR5-32-6000" }, { name: 1 }).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q8. Configurateur PC — cartes mères compatibles avec un CPU et une RAM");
// -----------------------------------------------------------------------------
//  Compatibilité « calculée » à partir des specs (même socket, même type de
//  mémoire), utile quand la liste compatible[] n'est pas renseignée.
const cpu = db.products.findOne({ _id: "CPU-AMD-R7-7800X3D" });
const ram = db.products.findOne({ _id: "RAM-CORSAIR-DDR5-32-6000" });
db.products.find(
  { type: "carte_mere", "specs.socket": cpu.specs.socket, "specs.memory_type": ram.specs.memory_type, "stock.quantity": { $gt: 0 } },
  { name: 1, "specs.form_factor": 1, "price.amount": 1 }
).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q9. Recherche plein texte « ryzen gaming »");
// -----------------------------------------------------------------------------
db.products.find(
  { $text: { $search: "ryzen gaming" } },
  { name: 1, score: { $meta: "textScore" } }
).sort({ score: { $meta: "textScore" } }).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q10. Navigation à facettes de la catégorie « Composants »");
// -----------------------------------------------------------------------------
//  Le panneau de filtres latéral : marques, tranches de prix, état du stock,
//  calculés en une seule agrégation ($facet).
db.products.aggregate([
  { $match: { "category.path": "composants" } },
  {
    $facet: {
      par_marque:    [{ $group: { _id: "$brand.name", nb: { $sum: 1 } } }, { $sort: { nb: -1 } }],
      par_categorie: [{ $group: { _id: "$category.name", nb: { $sum: 1 } } }, { $sort: { _id: 1 } }],
      par_prix: [{
        $bucket: {
          groupBy: "$price.amount",
          boundaries: [NumberDecimal("0"), NumberDecimal("150"), NumberDecimal("300"), NumberDecimal("500"), NumberDecimal("100000")],
          output: { nb: { $sum: 1 } }
        }
      }],
      disponibilite: [{ $group: { _id: "$stock.status", nb: { $sum: 1 } } }]
    }
  }
]).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q11. Avis — SUBSET : page 2 des avis (au-delà des 5 embarqués)");
// -----------------------------------------------------------------------------
//  Les 5 plus récents sont déjà dans products.latest_reviews. Pour les
//  suivants, on interroge la collection reviews (index idx_avis_produit_date).
//  Pagination par curseur sur la date du plus ancien avis embarqué : plus
//  efficace qu'un skip() sur de gros volumes.
const fiche = db.products.findOne({ _id: "CPU-AMD-R7-7800X3D" }, { latest_reviews: 1 });
const plusAncienAffiche = fiche.latest_reviews[fiche.latest_reviews.length - 1].date;
db.reviews.find(
  { product_id: "CPU-AMD-R7-7800X3D", date: { $lt: plusAncienAffiche } },
  { _id: 0, "author.pseudo": 1, rating: 1, title: 1, date: 1 }
).sort({ date: -1 }).limit(10).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q12. Dépôt d'un avis — SUBSET + COMPUTED mis à jour à l'écriture");
// -----------------------------------------------------------------------------
//  1) insertion dans reviews (source de vérité) ;
//  2) mise à jour du produit par un pipeline d'agrégation :
//     - distribution et count incrémentés ;
//     - average recalculée EXACTEMENT à partir de la distribution (pas de
//       dérive d'arrondi au fil des mises à jour) ;
//     - le nouvel avis est ajouté en tête de latest_reviews, tronqué à 5.
//  En production, les deux écritures sont dans une transaction multi-documents
//  (replica set requis) ou l'étape 2 est rejouée par un consumer en cas
//  d'échec : l'avis complet ne peut pas être perdu, seule la copie l'est.
const nouvelAvis = {
  _id: new ObjectId(),
  product_id: "CPU-AMD-R7-7800X3D",
  author: { user_id: "user:oualid", pseudo: "Oualid_O" },
  rating: NumberInt(5),
  title: "Monstrueux en jeu",
  comment: "Associé à une RTX 4070 SUPER, plus aucun ralentissement sur les jeux compétitifs.",
  date: new Date(),
  verified_purchase: true
};
db.reviews.deleteOne({ product_id: nouvelAvis.product_id, "author.user_id": nouvelAvis.author.user_id }); // rejouabilité du script
db.reviews.insertOne(nouvelAvis);

const note = nouvelAvis.rating.valueOf();
db.products.updateOne({ _id: nouvelAvis.product_id }, [
  {
    $set: {
      ["rating.distribution." + note]: { $add: ["$rating.distribution." + note, NumberInt(1)] },
      "rating.count": { $add: ["$rating.count", NumberInt(1)] },
      latest_reviews: {
        $slice: [{
          $concatArrays: [[{
            review_id: nouvelAvis._id, pseudo: nouvelAvis.author.pseudo, rating: nouvelAvis.rating,
            title: nouvelAvis.title, excerpt: nouvelAvis.comment, date: nouvelAvis.date
          }], "$latest_reviews"]
        }, 5]
      },
      updated_at: "$$NOW"
    }
  },
  {
    $set: {
      "rating.average": {
        $round: [{
          $divide: [
            { $add: [
              { $multiply: [1, "$rating.distribution.1"] }, { $multiply: [2, "$rating.distribution.2"] },
              { $multiply: [3, "$rating.distribution.3"] }, { $multiply: [4, "$rating.distribution.4"] },
              { $multiply: [5, "$rating.distribution.5"] }
            ] },
            "$rating.count"
          ]
        }, 2]
      }
    }
  }
]);
printjson(db.products.findOne(
  { _id: "CPU-AMD-R7-7800X3D" },
  { rating: 1, "latest_reviews.pseudo": 1, "latest_reviews.date": 1 }
));

// -----------------------------------------------------------------------------
titre("Q13. COMPUTED — recalcul de contrôle depuis la collection reviews");
// -----------------------------------------------------------------------------
//  Batch nocturne de réconciliation : recalcule les notes de tous les
//  produits v2 à partir de la source de vérité et les réécrit ($merge).
//  Garantit qu'une éventuelle mise à jour ratée (cf. Q12) est corrigée.
db.reviews.aggregate([
  { $group: {
      _id: "$product_id",
      count: { $sum: 1 },
      average: { $avg: "$rating" },
      d1: { $sum: { $cond: [{ $eq: ["$rating", 1] }, 1, 0] } },
      d2: { $sum: { $cond: [{ $eq: ["$rating", 2] }, 1, 0] } },
      d3: { $sum: { $cond: [{ $eq: ["$rating", 3] }, 1, 0] } },
      d4: { $sum: { $cond: [{ $eq: ["$rating", 4] }, 1, 0] } },
      d5: { $sum: { $cond: [{ $eq: ["$rating", 5] }, 1, 0] } }
  } },
  { $project: {
      rating: {
        average: { $round: ["$average", 2] },
        count: { $toInt: "$count" },
        distribution: { 1: { $toInt: "$d1" }, 2: { $toInt: "$d2" }, 3: { $toInt: "$d3" }, 4: { $toInt: "$d4" }, 5: { $toInt: "$d5" } }
      }
  } },
  // On ne touche qu'aux produits v2 (les v1 ont une note à plat).
  { $lookup: { from: "products", localField: "_id", foreignField: "_id", as: "p", pipeline: [{ $project: { schema_version: 1 } }] } },
  { $match: { "p.schema_version": { $gte: 2 } } },
  { $project: { p: 0 } },
  { $merge: { into: "products", on: "_id", whenMatched: "merge", whenNotMatched: "discard" } }
]);
db.products.find({ schema_version: 2 }, { name: 1, rating: 1 }).sort({ "rating.average": -1 }).limit(5).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q14. SCHEMA VERSIONING — lecture compatible v1 / v2");
// -----------------------------------------------------------------------------
//  Tant que des documents v1 existent, les lectures « normalisent » la note
//  et l'image. Ici dans une agrégation ; dans l'application c'est un simple
//  if (doc.schema_version === 1) dans la couche d'accès aux données.
db.products.aggregate([
  { $match: { "category.path": "informatique" } },
  { $project: {
      name: 1, schema_version: 1,
      note:     { $ifNull: ["$rating.average", "$rating_avg"] },
      nb_avis:  { $ifNull: ["$rating.count", "$reviews_count"] },
      vignette: { $ifNull: [{ $first: "$images" }, "$image"] }
  } },
  { $sort: { note: -1 } }
]).forEach(printjson);

// -----------------------------------------------------------------------------
titre("Q15. SCHEMA VERSIONING — migration paresseuse v1 → v2");
// -----------------------------------------------------------------------------
//  Exécutée par l'application lorsqu'elle RÉÉCRIT un document v1 (changement
//  de prix, de stock...), ou par un batch de fond par petits lots. Aucun
//  arrêt de service, aucune migration « big bang ».
//  La condition schema_version: 1 rend l'opération idempotente.
const migrerV1versV2 = [
  { $set: {
      schema_version: NumberInt(2),
      images: ["$image"],
      rating: {
        average: "$rating_avg",
        count: "$reviews_count",
        distribution: { 1: NumberInt(0), 2: NumberInt(0), 3: NumberInt(0), 4: NumberInt(0), 5: NumberInt(0) }
      },
      latest_reviews: [],
      updated_at: "$$NOW"
  } },
  { $unset: ["image", "rating_avg", "reviews_count"] }
];
print("Avant : " + db.products.countDocuments({ schema_version: 1 }) + " document(s) en v1");
// Exemple : on migre uniquement la souris, au moment d'un changement de prix.
db.products.updateOne({ _id: "SOU-LOGI-G502X", schema_version: 1 }, [
  ...migrerV1versV2,
  { $set: { "price.amount": NumberDecimal("79.95") } }
]);
print("Après : " + db.products.countDocuments({ schema_version: 1 }) + " document(s) en v1");
//  La distribution et latest_reviews seront remplis exactement par le batch
//  de réconciliation (Q13), qui traite désormais ce document puisqu'il est en v2.
printjson(db.products.findOne({ _id: "SOU-LOGI-G502X" }, { schema_version: 1, images: 1, rating: 1, price: 1 }));

// -----------------------------------------------------------------------------
titre("Q16. Évolution SANS migration — nouvelle catégorie, nouvelles specs");
// -----------------------------------------------------------------------------
//  LDLC référence un écran : type et caractéristiques jamais vus jusque-là.
//  Aucun ALTER TABLE, aucune modification du validateur : le document est
//  accepté car les champs communs sont présents, et ses specs sont
//  immédiatement indexées par l'index wildcard.
db.products.deleteOne({ _id: "ECR-ASUS-VG27AQ3A" }); // rejouabilité
db.products.insertOne({
  _id: "ECR-ASUS-VG27AQ3A",
  schema_version: NumberInt(2),
  type: "ecran",
  name: "ASUS TUF Gaming VG27AQ3A",
  brand: { _id: "asus", name: "ASUS" },
  category: { _id: "ecrans", name: "Écrans PC", path: ["informatique", "peripheriques", "ecrans"] },
  price: { amount: NumberDecimal("219.95"), currency: "EUR" },
  stock: { quantity: NumberInt(120), status: "en_stock" },
  specs: { diagonal_in: 27, resolution: "2560x1440", panel: "IPS", refresh_hz: NumberInt(180), response_ms: 1, adaptive_sync: ["G-Sync Compatible", "FreeSync Premium"] },
  rating: { average: null, count: NumberInt(0), distribution: { 1: NumberInt(0), 2: NumberInt(0), 3: NumberInt(0), 4: NumberInt(0), 5: NumberInt(0) } },
  latest_reviews: [],
  compatible: []
});
db.products.find({ "specs.refresh_hz": { $gte: 144 } }, { name: 1, "specs.refresh_hz": 1 }).forEach(printjson);
db.products.deleteOne({ _id: "ECR-ASUS-VG27AQ3A" });

// -----------------------------------------------------------------------------
titre("Q17. Validation — un document sans champs communs est refusé");
// -----------------------------------------------------------------------------
try {
  db.products.insertOne({ _id: "TEST-INVALIDE", type: "souris", name: "Sans prix ni marque", specs: {} });
} catch (e) {
  print("Refusé par $jsonSchema : " + e.message);
}

// -----------------------------------------------------------------------------
titre("Q18. EXTENDED REFERENCE — propagation d'un changement de marque");
// -----------------------------------------------------------------------------
//  Contrepartie de la dénormalisation : si une marque change de nom (rare),
//  on met à jour le référentiel PUIS les copies. Opération ponctuelle,
//  indexée (idx_marque), acceptable car le nom d'une marque est stable.
db.brands.updateOne({ _id: "gskill" }, { $set: { name: "G.SKILL" } });
const r = db.products.updateMany({ "brand._id": "gskill" }, { $set: { "brand.name": "G.SKILL" } });
print(r.modifiedCount + " produit(s) mis à jour");
// Même logique pour les références dans compatible[] (renommage d'un produit) :
//   db.products.updateMany({ "compatible.sku": SKU },
//                          { $set: { "compatible.$[c].name": NOUVEAU_NOM } },
//                          { arrayFilters: [{ "c.sku": SKU }] })
