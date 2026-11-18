// =============================================================================
//  Refonte LDLC — Lot 1 : Catalogue produits (MongoDB)
//  02-sample-data.js — Jeu de données réaliste (14 produits « config PC »)
//
//  Exécution (après 01-schema.js) :
//    mongosh "mongodb://localhost:27017/ldlc" 02-sample-data.js
//
//  Contenu : 11 catégories, 11 marques, 14 produits, ~45 avis.
//    - 3 processeurs, 3 cartes mères, 2 kits de RAM, 2 cartes graphiques,
//      2 boîtiers, 1 souris, 1 licence Windows.
//    - 12 produits en schema_version 2, 2 produits « historiques » en
//      schema_version 1 (souris et Windows) pour illustrer le Schema Versioning.
//
//  Les avis sont d'abord insérés dans `reviews` (source de vérité), puis le
//  script CALCULE pour chaque produit la note (pattern Computed) et le
//  sous-ensemble des 5 avis les plus récents (pattern Subset) : les données
//  embarquées sont donc toujours cohérentes avec la collection reviews.
// =============================================================================

db = db.getSiblingDB("ldlc");

db.categories.deleteMany({});
db.brands.deleteMany({});
db.products.deleteMany({});
db.reviews.deleteMany({});

const I = NumberInt;      // entiers 32 bits (le validateur exige bsonType "int")
const D = NumberDecimal;  // prix en Decimal128 : pas d'erreur d'arrondi sur les euros

// -----------------------------------------------------------------------------
//  1. Catégories — pattern ARRAY OF ANCESTORS
// -----------------------------------------------------------------------------
//  Arbre :
//    Informatique
//    ├── Composants
//    │   ├── Processeurs
//    │   ├── Cartes mères
//    │   ├── Mémoire PC
//    │   ├── Cartes graphiques
//    │   └── Boîtiers PC
//    ├── Périphériques
//    │   └── Souris
//    └── Logiciels
//        └── Systèmes d'exploitation
// -----------------------------------------------------------------------------
const catDefs = [
  // [_id, nom, parent]
  ["informatique",          "Informatique",             null],
  ["composants",            "Composants",               "informatique"],
  ["processeurs",           "Processeurs",              "composants"],
  ["cartes-meres",          "Cartes mères",             "composants"],
  ["memoire-pc",            "Mémoire PC",               "composants"],
  ["cartes-graphiques",     "Cartes graphiques",        "composants"],
  ["boitiers-pc",           "Boîtiers PC",              "composants"],
  ["peripheriques",         "Périphériques",            "informatique"],
  ["souris",                "Souris",                   "peripheriques"],
  ["logiciels",             "Logiciels",                "informatique"],
  ["systemes-exploitation", "Systèmes d'exploitation",  "logiciels"]
];

const categories = {};
catDefs.forEach(([id, name, parent]) => {
  // ancêtres = ancêtres du parent + le parent lui-même (ordre racine → parent)
  const ancestors = parent
    ? [...categories[parent].ancestors, { _id: parent, name: categories[parent].name }]
    : [];
  categories[id] = { _id: id, name, parent, ancestors };
});
db.categories.insertMany(Object.values(categories));

// -----------------------------------------------------------------------------
//  2. Marques
// -----------------------------------------------------------------------------
const brands = {
  amd:       { _id: "amd",       name: "AMD",             country: "États-Unis", logo: "/img/marques/amd.svg" },
  intel:     { _id: "intel",     name: "Intel",           country: "États-Unis", logo: "/img/marques/intel.svg" },
  asus:      { _id: "asus",      name: "ASUS",            country: "Taïwan",     logo: "/img/marques/asus.svg" },
  msi:       { _id: "msi",       name: "MSI",             country: "Taïwan",     logo: "/img/marques/msi.svg" },
  corsair:   { _id: "corsair",   name: "Corsair",         country: "États-Unis", logo: "/img/marques/corsair.svg" },
  gskill:    { _id: "gskill",    name: "G.Skill",         country: "Taïwan",     logo: "/img/marques/gskill.svg" },
  sapphire:  { _id: "sapphire",  name: "Sapphire",        country: "Hong Kong",  logo: "/img/marques/sapphire.svg" },
  fractal:   { _id: "fractal",   name: "Fractal Design",  country: "Suède",      logo: "/img/marques/fractal.svg" },
  logitech:  { _id: "logitech",  name: "Logitech G",      country: "Suisse",     logo: "/img/marques/logitech.svg" },
  microsoft: { _id: "microsoft", name: "Microsoft",       country: "États-Unis", logo: "/img/marques/microsoft.svg" },
  nvidia:    { _id: "nvidia",    name: "NVIDIA",          country: "États-Unis", logo: "/img/marques/nvidia.svg" }
};
db.brands.insertMany(Object.values(brands));

// -----------------------------------------------------------------------------
//  3. Définition des produits
// -----------------------------------------------------------------------------
//  `specs` est différent pour chaque type : c'est le pattern POLYMORPHIC.
//  `compatible` ne contient ici que des SKU ; il est transformé plus bas en
//  Extended Reference {sku, name, type}.
//  `reviews` : avis bruts, insérés dans la collection reviews.
// -----------------------------------------------------------------------------
const defs = [
  // ===================== PROCESSEURS =====================
  {
    sku: "CPU-AMD-R7-7800X3D", type: "processeur", brand: "amd", cat: "processeurs",
    name: "AMD Ryzen 7 7800X3D (4.2 GHz / 5.0 GHz)",
    description: "Processeur 8 cœurs / 16 threads avec technologie 3D V-Cache (96 Mo de cache L3), référence pour le jeu vidéo sur plateforme AM5.",
    price: "389.95", qty: 312,
    specs: {
      socket: "AM5", architecture: "Zen 4", cores: I(8), threads: I(16),
      base_clock_ghz: 4.2, boost_clock_ghz: 5.0, cache_l3_mb: I(96),
      tdp_w: I(120), igpu: "AMD Radeon Graphics", cooler_included: false,
      memory_support: ["DDR5"]
    },
    compatible: ["CM-ASUS-B650A-WIFI", "CM-MSI-B650MA-WIFI", "RAM-CORSAIR-DDR5-32-6000", "RAM-GSKILL-DDR5-32-6400"],
    reviews: [
      ["Kevin_FPS",   5, "Le roi du gaming",          "Gros gain de FPS sur Cyberpunk et Warzone par rapport à mon 5600X. Chauffe raisonnable avec un bon ventirad.", "2026-10-28"],
      ["MaximeB",     5, "Parfait pour du 1440p",     "Installation sans souci sur une B650, BIOS à jour obligatoire. Très stable.", "2026-10-12"],
      ["Sandrine.L",  4, "Excellent mais cher",       "Performances au top en jeu, un peu moins convaincant en rendu vidéo face à un 7900X.", "2026-09-30"],
      ["Thomas_33",   5, "Aucun regret",              "Montage avec 32 Go de DDR5 6000 CL30, profil EXPO activé du premier coup.", "2026-09-02"],
      ["NicoHW",      4, "Très bon CPU",              "Penser à prévoir un bon refroidissement, il monte vite à 80 °C en charge.", "2026-08-14"],
      ["Julie_R",     5, "Livraison rapide",          "Reçu en 24 h, parfaitement emballé. Le processeur tient ses promesses.", "2026-06-21"],
      ["PierreG",     3, "Bien mais pas pour le montage vidéo", "Pour du jeu c'est parfait, pour Premiere Pro j'aurais dû prendre plus de cœurs.", "2026-04-03"],
      ["Arnaud.D",    5, "Le meilleur rapport FPS/€", "Consommation très contenue pour de telles performances.", "2026-01-17"]
    ]
  },
  {
    sku: "CPU-AMD-R5-7600X", type: "processeur", brand: "amd", cat: "processeurs",
    name: "AMD Ryzen 5 7600X (4.7 GHz / 5.3 GHz)",
    description: "Processeur 6 cœurs / 12 threads Zen 4 pour plateforme AM5, idéal pour une configuration gaming milieu de gamme.",
    price: "199.95", qty: 540,
    specs: {
      socket: "AM5", architecture: "Zen 4", cores: I(6), threads: I(12),
      base_clock_ghz: 4.7, boost_clock_ghz: 5.3, cache_l3_mb: I(32),
      tdp_w: I(105), igpu: "AMD Radeon Graphics", cooler_included: false,
      memory_support: ["DDR5"]
    },
    compatible: ["CM-ASUS-B650A-WIFI", "CM-MSI-B650MA-WIFI", "RAM-CORSAIR-DDR5-32-6000", "RAM-GSKILL-DDR5-32-6400"],
    reviews: [
      ["Lucas_M",   5, "Super rapport qualité/prix", "Largement suffisant pour jouer en 1080p avec une RTX 4070.", "2026-10-05"],
      ["Emma.V",    4, "Bon processeur",             "Attention, pas de ventirad fourni.", "2026-07-19"],
      ["Romain_K",  4, "Efficace",                   "Chauffe un peu sans undervolt, mais très bonnes performances.", "2026-03-11"]
    ]
  },
  {
    sku: "CPU-INTEL-I5-14600K", type: "processeur", brand: "intel", cat: "processeurs",
    name: "Intel Core i5-14600K (3.5 GHz / 5.3 GHz)",
    description: "Processeur 14 cœurs (6 P-cores + 8 E-cores) / 20 threads débloqué pour socket LGA 1700.",
    price: "279.95", qty: 8,                    // stock faible
    specs: {
      socket: "LGA1700", architecture: "Raptor Lake Refresh", cores: I(14),
      p_cores: I(6), e_cores: I(8), threads: I(20),
      base_clock_ghz: 3.5, boost_clock_ghz: 5.3, cache_l3_mb: I(24),
      tdp_w: I(125), igpu: "Intel UHD Graphics 770", cooler_included: false,
      unlocked: true, memory_support: ["DDR4", "DDR5"]
    },
    compatible: ["CM-MSI-B760-TOMAHAWK", "RAM-CORSAIR-DDR5-32-6000", "RAM-GSKILL-DDR5-32-6400"],
    reviews: [
      ["Hugo_B",     4, "Polyvalent",        "Très bon en jeu comme en multitâche. Mettre à jour le BIOS pour le microcode.", "2026-09-22"],
      ["Clara.P",    5, "Excellent",         "Parfait pour du streaming en même temps que le jeu.", "2026-05-08"]
    ]
  },

  // ===================== CARTES MÈRES =====================
  {
    sku: "CM-ASUS-B650A-WIFI", type: "carte_mere", brand: "asus", cat: "cartes-meres",
    name: "ASUS ROG STRIX B650-A GAMING WIFI",
    description: "Carte mère ATX socket AM5, chipset AMD B650, DDR5, PCIe 5.0 M.2, Wi-Fi 6E et 2.5 GbE.",
    price: "249.95", qty: 97,
    specs: {
      socket: "AM5", chipset: "AMD B650", form_factor: "ATX",
      memory_type: "DDR5", memory_slots: I(4), max_memory_gb: I(192),
      m2_slots: I(3), pcie_x16_gen: "PCIe 4.0", wifi: "Wi-Fi 6E",
      ethernet: "2.5 GbE", bluetooth: "5.2", usb_c_front: true
    },
    compatible: ["CPU-AMD-R7-7800X3D", "CPU-AMD-R5-7600X", "RAM-CORSAIR-DDR5-32-6000", "RAM-GSKILL-DDR5-32-6400", "BOI-FRACTAL-NORTH", "BOI-CORSAIR-4000D"],
    reviews: [
      ["Kevin_FPS",  5, "Belle carte",           "Le BIOS ASUS est clair, bon VRM, le look blanc est superbe.", "2026-10-29"],
      ["Mathieu.T",  4, "Très complète",         "Premier boot un peu long (entraînement mémoire DDR5), ensuite rien à dire.", "2026-08-03"],
      ["Sophie_R",   5, "Rien à redire",         "Wi-Fi 6E stable, beaucoup de ports USB.", "2026-02-15"]
    ]
  },
  {
    sku: "CM-MSI-B650MA-WIFI", type: "carte_mere", brand: "msi", cat: "cartes-meres",
    name: "MSI PRO B650M-A WIFI",
    description: "Carte mère Micro-ATX socket AM5, chipset AMD B650, DDR5, Wi-Fi 6E.",
    price: "159.95", qty: 0,                    // en rupture
    specs: {
      socket: "AM5", chipset: "AMD B650", form_factor: "Micro-ATX",
      memory_type: "DDR5", memory_slots: I(4), max_memory_gb: I(192),
      m2_slots: I(2), pcie_x16_gen: "PCIe 4.0", wifi: "Wi-Fi 6E",
      ethernet: "2.5 GbE", bluetooth: "5.3"
    },
    compatible: ["CPU-AMD-R7-7800X3D", "CPU-AMD-R5-7600X", "RAM-CORSAIR-DDR5-32-6000", "RAM-GSKILL-DDR5-32-6400", "BOI-FRACTAL-NORTH", "BOI-CORSAIR-4000D"],
    reviews: [
      ["Antoine_L",  4, "Simple et efficace",   "Idéale pour une config compacte, rien de superflu.", "2026-07-07"],
      ["Lea.M",      4, "Bon choix budget",     "Le dissipateur M.2 secondaire manque un peu.", "2026-03-28"]
    ]
  },
  {
    sku: "CM-MSI-B760-TOMAHAWK", type: "carte_mere", brand: "msi", cat: "cartes-meres",
    name: "MSI MAG B760 TOMAHAWK WIFI",
    description: "Carte mère ATX socket LGA 1700, chipset Intel B760, DDR5, Wi-Fi 6E.",
    price: "199.95", qty: 64,
    specs: {
      socket: "LGA1700", chipset: "Intel B760", form_factor: "ATX",
      memory_type: "DDR5", memory_slots: I(4), max_memory_gb: I(192),
      m2_slots: I(3), pcie_x16_gen: "PCIe 4.0", wifi: "Wi-Fi 6E",
      ethernet: "2.5 GbE", bluetooth: "5.3"
    },
    compatible: ["CPU-INTEL-I5-14600K", "RAM-CORSAIR-DDR5-32-6000", "RAM-GSKILL-DDR5-32-6400", "BOI-FRACTAL-NORTH", "BOI-CORSAIR-4000D"],
    reviews: [
      ["Hugo_B",     5, "Solide",               "Accompagne parfaitement mon 14600K, VRM froids.", "2026-09-23"],
      ["Damien.F",   4, "Bonne carte",          "Le logiciel MSI Center est lourd, mais la carte est excellente.", "2026-06-10"]
    ]
  },

  // ===================== MÉMOIRE =====================
  {
    sku: "RAM-CORSAIR-DDR5-32-6000", type: "memoire", brand: "corsair", cat: "memoire-pc",
    name: "Corsair Vengeance DDR5 32 Go (2 x 16 Go) 6000 MHz CL30",
    description: "Kit Dual Channel de 2 barrettes DDR5 PC5-48000, profils AMD EXPO et Intel XMP 3.0.",
    price: "129.95", qty: 820,
    specs: {
      memory_type: "DDR5", capacity_gb: I(32), modules: I(2), module_capacity_gb: I(16),
      frequency_mhz: I(6000), cas_latency: I(30), voltage_v: 1.4,
      profiles: ["AMD EXPO", "Intel XMP 3.0"], rgb: false, heatsink: true
    },
    compatible: ["CM-ASUS-B650A-WIFI", "CM-MSI-B650MA-WIFI", "CM-MSI-B760-TOMAHAWK"],
    reviews: [
      ["Thomas_33",  5, "Sweet spot pour AM5",  "6000 CL30, EXPO activé, stable sous TestMem5.", "2026-09-03"],
      ["Julien.R",   5, "Parfait",              "Barrettes basses, compatibles avec mon gros ventirad.", "2026-08-19"],
      ["Marion_C",   4, "Bon kit",              "Fonctionne très bien, packaging minimaliste.", "2026-06-02"],
      ["Yanis.B",    5, "Top",                  "Aucune instabilité depuis 4 mois.", "2026-04-26"],
      ["Paul_D",     4, "Très bien",            "Un poil plus chère que la concurrence mais fiable.", "2026-02-09"],
      ["Ines.K",     5, "Recommandé",           "Reconnue directement par la carte mère.", "2025-12-14"]
    ]
  },
  {
    sku: "RAM-GSKILL-DDR5-32-6400", type: "memoire", brand: "gskill", cat: "memoire-pc",
    name: "G.Skill Trident Z5 RGB 32 Go (2 x 16 Go) DDR5 6400 MHz CL32",
    description: "Kit Dual Channel DDR5 avec éclairage RGB, profil Intel XMP 3.0.",
    price: "149.95", qty: 155,
    specs: {
      memory_type: "DDR5", capacity_gb: I(32), modules: I(2), module_capacity_gb: I(16),
      frequency_mhz: I(6400), cas_latency: I(32), voltage_v: 1.4,
      profiles: ["Intel XMP 3.0"], rgb: true, heatsink: true, color: "Argent"
    },
    compatible: ["CM-ASUS-B650A-WIFI", "CM-MSI-B650MA-WIFI", "CM-MSI-B760-TOMAHAWK"],
    reviews: [
      ["Clara.P",    5, "Magnifique",            "Le RGB est superbe et synchronisable.", "2026-05-09"],
      ["Victor_A",   3, "Instable en 6400 sur AM5", "J'ai dû redescendre en 6000 sur mon Ryzen, normal pour de l'XMP sur AMD.", "2026-03-15"]
    ]
  },

  // ===================== CARTES GRAPHIQUES =====================
  {
    sku: "GPU-ASUS-RTX4070S-12", type: "carte_graphique", brand: "asus", cat: "cartes-graphiques",
    name: "ASUS Dual GeForce RTX 4070 SUPER OC Edition 12 Go",
    description: "Carte graphique NVIDIA GeForce RTX 4070 SUPER, 12 Go GDDR6X, DLSS 3, ray tracing, double ventilateur.",
    price: "629.95", qty: 43,
    specs: {
      gpu_chip: "NVIDIA GeForce RTX 4070 SUPER", chip_maker: "nvidia",
      vram_gb: I(12), vram_type: "GDDR6X", bus_bits: I(192),
      boost_clock_mhz: I(2550), length_mm: I(267), slot_width: 2.56,
      recommended_psu_w: I(650), power_connectors: ["1 x 8 broches"],
      outputs: { hdmi: I(1), displayport: I(3) }, ray_tracing: true, upscaling: "DLSS 3"
    },
    compatible: ["BOI-FRACTAL-NORTH", "BOI-CORSAIR-4000D"],
    reviews: [
      ["Kevin_FPS",  5, "Silencieuse et efficace", "Parfaite en 1440p, DLSS 3 bluffant.", "2026-10-30"],
      ["Sarah_L",    4, "Très bonne carte",        "Un peu de coil whine à très haut FPS, rien de gênant.", "2026-09-14"],
      ["Bastien.G",  5, "Compacte",                "Rentre sans problème dans un boîtier moyen tour.", "2026-07-25"],
      ["Elodie_F",   4, "Bonne mais 12 Go",        "Performances top, j'aurais aimé un peu plus de VRAM pour l'avenir.", "2026-05-30"]
    ]
  },
  {
    sku: "GPU-SAPPHIRE-RX7800XT-16", type: "carte_graphique", brand: "sapphire", cat: "cartes-graphiques",
    name: "Sapphire PULSE Radeon RX 7800 XT 16 Go",
    description: "Carte graphique AMD Radeon RX 7800 XT, 16 Go GDDR6, FSR 3, idéale pour le jeu en 1440p.",
    price: "529.95", qty: 71,
    specs: {
      gpu_chip: "AMD Radeon RX 7800 XT", chip_maker: "amd",
      vram_gb: I(16), vram_type: "GDDR6", bus_bits: I(256),
      boost_clock_mhz: I(2430), length_mm: I(280), slot_width: 2.7,
      recommended_psu_w: I(700), power_connectors: ["2 x 8 broches"],
      outputs: { hdmi: I(2), displayport: I(2) }, ray_tracing: true, upscaling: "FSR 3"
    },
    compatible: ["BOI-FRACTAL-NORTH", "BOI-CORSAIR-4000D"],
    reviews: [
      ["Victor_A",   5, "16 Go bien utiles",    "Excellente en rasterisation, pilotes stables.", "2026-08-08"],
      ["Manon.S",    4, "Bon rapport qualité/prix", "Un peu plus énergivore que la concurrence.", "2026-04-17"],
      ["Quentin_R",  5, "Sapphire au top",      "Très silencieuse, refroidissement efficace.", "2026-01-29"]
    ]
  },

  // ===================== BOÎTIERS =====================
  {
    sku: "BOI-FRACTAL-NORTH", type: "boitier", brand: "fractal", cat: "boitiers-pc",
    name: "Fractal Design North Charcoal Black TG Dark",
    description: "Boîtier moyen tour au design scandinave, façade en noyer, panneau latéral en verre trempé.",
    price: "139.95", qty: 58,
    specs: {
      form_factor: "Moyen tour", motherboard_support: ["ATX", "Micro-ATX", "Mini-ITX"],
      max_gpu_length_mm: I(355), max_cpu_cooler_height_mm: I(170),
      fans_included: I(2), max_radiator_mm: I(360), side_panel: "Verre trempé",
      front_panel: "Noyer", color: "Noir", front_usb_c: true
    },
    compatible: ["CM-ASUS-B650A-WIFI", "CM-MSI-B650MA-WIFI", "CM-MSI-B760-TOMAHAWK", "GPU-ASUS-RTX4070S-12", "GPU-SAPPHIRE-RX7800XT-16"],
    reviews: [
      ["Sophie_R",   5, "Le plus beau boîtier",  "La façade en bois fait son effet dans un salon.", "2026-02-16"],
      ["Bastien.G",  4, "Beau et pratique",      "Montage agréable, gestion des câbles un peu juste derrière.", "2026-07-26"]
    ]
  },
  {
    sku: "BOI-CORSAIR-4000D", type: "boitier", brand: "corsair", cat: "boitiers-pc",
    name: "Corsair 4000D Airflow Noir",
    description: "Boîtier moyen tour à façade perforée pour un flux d'air optimal, panneau en verre trempé.",
    price: "104.95", qty: 230,
    specs: {
      form_factor: "Moyen tour", motherboard_support: ["ATX", "Micro-ATX", "Mini-ITX"],
      max_gpu_length_mm: I(360), max_cpu_cooler_height_mm: I(170),
      fans_included: I(2), max_radiator_mm: I(360), side_panel: "Verre trempé",
      color: "Noir", front_usb_c: true
    },
    compatible: ["CM-ASUS-B650A-WIFI", "CM-MSI-B650MA-WIFI", "CM-MSI-B760-TOMAHAWK", "GPU-ASUS-RTX4070S-12", "GPU-SAPPHIRE-RX7800XT-16"],
    reviews: [
      ["Lucas_M",    5, "Un classique",          "Excellent airflow, montage très facile.", "2026-10-06"],
      ["Paul_D",     4, "Bon boîtier",           "Les ventilateurs fournis sont un peu bruyants.", "2026-02-10"],
      ["Ines.K",     5, "Parfait",               "Très bonne gestion des câbles.", "2025-12-15"]
    ]
  },

  // ===================== PRODUITS « HISTORIQUES » EN SCHEMA v1 =====================
  //  Ces deux fiches ont été créées avant l'introduction de la v2 :
  //  note à plat, une seule image, pas d'avis embarqués.
  {
    sku: "SOU-LOGI-G502X", type: "souris", brand: "logitech", cat: "souris", version: 1,
    name: "Logitech G502 X (Noir)",
    description: "Souris gaming filaire avec capteur HERO 25K, switchs hybrides LIGHTFORCE et 13 commandes programmables.",
    price: "89.95", qty: 410,
    specs: {
      sensor: "HERO 25K", dpi_max: I(25600), buttons: I(13),
      connectivity: "Filaire USB", weight_g: I(89), switches: "LIGHTFORCE hybrides",
      handedness: "Droitier", rgb: false
    },
    compatible: [],
    reviews: [
      ["Romain_K",   5, "Très confortable",      "Bien plus légère que l'ancienne G502 HERO.", "2026-03-12"],
      ["Emma.V",     4, "Bonne souris",          "Molette crantée/libre très pratique.", "2025-11-20"]
    ]
  },
  {
    sku: "LOG-MS-WIN11-FAM", type: "logiciel", brand: "microsoft", cat: "systemes-exploitation", version: 1,
    name: "Microsoft Windows 11 Famille 64 bits - OEM (DVD)",
    description: "Système d'exploitation Windows 11 Famille, licence OEM pour un PC assemblé, version française.",
    price: "139.95", qty: 1200,
    specs: {
      edition: "Famille", architecture: "64 bits", license_type: "OEM",
      language: "Français", media: "DVD", users: I(1)
    },
    compatible: [],
    reviews: [
      ["Mathieu.T",  4, "RAS",                   "Activation immédiate, livré rapidement.", "2026-08-04"]
    ]
  }
];

// -----------------------------------------------------------------------------
//  4. Construction des documents
// -----------------------------------------------------------------------------
const byId = Object.fromEntries(defs.map((d) => [d.sku, d]));
const allReviews = [];
const products = [];

const stockStatus = (q) => (q === 0 ? "rupture" : q < 10 ? "stock_faible" : "en_stock");
const userId = (pseudo) => "user:" + pseudo.toLowerCase().replace(/[^a-z0-9]/g, "");

defs.forEach((d) => {
  const version = d.version || 2;
  const cat = categories[d.cat];

  // --- Avis : tous vont dans la collection reviews ---------------------------
  const reviews = d.reviews.map(([pseudo, rating, title, comment, date]) => ({
    _id: new ObjectId(),
    product_id: d.sku,
    author: { user_id: userId(pseudo), pseudo },
    rating: I(rating),
    title,
    comment,
    date: new Date(date + "T10:00:00Z"),
    verified_purchase: true
  }));
  allReviews.push(...reviews);

  // --- Pattern COMPUTED : note pré-calculée ---------------------------------
  const notes = d.reviews.map((r) => r[1]);
  const distribution = {};
  [1, 2, 3, 4, 5].forEach((n) => (distribution[n] = I(notes.filter((x) => x === n).length)));
  const count = notes.length;
  const average = count ? Math.round((notes.reduce((s, n) => s + n, 0) / count) * 100) / 100 : null;

  const doc = {
    _id: d.sku,
    schema_version: I(version),
    type: d.type,                                       // discriminant Polymorphic
    name: d.name,
    description: d.description,

    // Pattern EXTENDED REFERENCE : copie des seuls champs affichés
    brand: { _id: brands[d.brand]._id, name: brands[d.brand].name },

    // Extended Reference + ARRAY OF ANCESTORS : path = ancêtres + catégorie
    category: {
      _id: cat._id,
      name: cat.name,
      path: [...cat.ancestors.map((a) => a._id), cat._id]
    },

    price: { amount: D(d.price), currency: "EUR" },
    stock: { quantity: I(d.qty), status: stockStatus(d.qty) },

    specs: d.specs,                                     // POLYMORPHIC : libre

    // EXTENDED REFERENCE vers d'autres produits (pas de prix : trop volatil)
    compatible: d.compatible.map((sku) => ({ sku, name: byId[sku].name, type: byId[sku].type })),

    created_at: new Date("2025-09-01T08:00:00Z"),
    updated_at: new Date()
  };

  if (version >= 2) {
    // ----- Structure v2 -----
    doc.images = [
      `/img/produits/${d.sku.toLowerCase()}/1.webp`,
      `/img/produits/${d.sku.toLowerCase()}/2.webp`
    ];
    doc.rating = { average, count: I(count), distribution };   // COMPUTED

    // Pattern SUBSET : les 5 avis les plus récents, en version allégée
    doc.latest_reviews = [...reviews]
      .sort((a, b) => b.date - a.date)
      .slice(0, 5)
      .map((r) => ({
        review_id: r._id,
        pseudo: r.author.pseudo,
        rating: r.rating,
        title: r.title,
        excerpt: r.comment.length > 140 ? r.comment.slice(0, 137) + "..." : r.comment,
        date: r.date
      }));
  } else {
    // ----- Structure v1 (historique) -----
    doc.image = `/img/produits/${d.sku.toLowerCase()}.jpg`;
    doc.rating_avg = average;
    doc.reviews_count = I(count);
  }

  products.push(doc);
});

db.reviews.insertMany(allReviews);
db.products.insertMany(products);

// -----------------------------------------------------------------------------
//  5. Vérification
// -----------------------------------------------------------------------------
print("=== Données chargées ===");
print("categories : " + db.categories.countDocuments());
print("brands     : " + db.brands.countDocuments());
print("products   : " + db.products.countDocuments() +
      "  (v1 : " + db.products.countDocuments({ schema_version: 1 }) +
      ", v2 : " + db.products.countDocuments({ schema_version: 2 }) + ")");
print("reviews    : " + db.reviews.countDocuments());

print("\n=== Exemple de document complet (v2) ===");
printjson(db.products.findOne({ _id: "CPU-AMD-R7-7800X3D" }));

print("\n=== Exemple de document historique (v1) ===");
printjson(db.products.findOne({ _id: "SOU-LOGI-G502X" }));
