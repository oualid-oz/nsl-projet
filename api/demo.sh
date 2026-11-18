#!/usr/bin/env bash
# =============================================================================
#  Refonte LDLC — démonstration de bout en bout de l'API (curl)
#
#  Prérequis : docker compose up -d --build   (depuis la racine du dépôt)
#  Usage     : ./api/demo.sh
#              API_URL=http://localhost:8001 ./api/demo.sh
#
#  Scénario : un visiteur anonyme parcourt le catalogue, consulte des fiches,
#  remplit son panier, se connecte (fusion du panier), reçoit des
#  recommandations, commande, puis on consulte les analytics.
#  Nécessite curl et python3 (jq est utilisé pour l'affichage s'il est présent).
# =============================================================================
set -euo pipefail

API="${API_URL:-http://localhost:${API_PORT:-8000}}"
CPU="CPU-AMD-R7-7800X3D"

if command -v jq >/dev/null 2>&1; then PRETTY=(jq .); else PRETTY=(python3 -m json.tool --no-ensure-ascii); fi

title() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;33m→ %s\033[0m\n' "$*"; }

# call MÉTHODE CHEMIN [JSON]  — affiche le code HTTP et le corps formaté
call() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  [[ -n "${SID:-}" ]] && args+=(-H "X-Session-Id: $SID")
  [[ -n "$data" ]] && args+=(-d "$data")
  local out code body
  out=$(curl "${args[@]}" "$API$path")
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  printf '\033[2m%s %s → HTTP %s\033[0m\n' "$method" "$path" "$code"
  printf '%s\n' "$body" | "${PRETTY[@]}" 2>/dev/null || printf '%s\n' "$body"
  LAST_BODY=$body
  LAST_CODE=$code
}

# json EXPRESSION — extrait une valeur du dernier corps (ex. json '["sid"]')
json() { python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)" <<<"$LAST_BODY"; }

step "Attente de l'API sur $API"
for _ in $(seq 1 60); do
  curl -fsS "$API/sante" >/dev/null 2>&1 && break
  sleep 2
done
call GET /sante

# -----------------------------------------------------------------------------
title "LOT 1 — Catalogue MongoDB (+ cache Redis)"
# -----------------------------------------------------------------------------
step "Fil d'Ariane et sous-catégories (Array of Ancestors)"
call GET /categories/processeurs

step "Listing « Composants » (toutes sous-catégories) avec facettes"
call GET "/produits?categorie=composants&tri=prix_asc&par_page=3"

step "Filtres techniques libres via l'index wildcard : processeurs AM5 d'au moins 8 cœurs"
call GET "/produits?type=processeur&specs.socket=AM5&specs.cores=gte:8"

step "Recherche plein texte"
call GET "/produits?q=ryzen&tri=pertinence&par_page=5"

step "Fiche produit : MISS → lecture MongoDB puis mise en cache ; appel suivant HIT → Redis (HIT dès le 1er appel si la démo a déjà tourné)"
curl -sS -o /dev/null -D - "$API/produits/$CPU" | grep -i '^x-cache'
curl -sS -o /dev/null -D - "$API/produits/$CPU" | grep -i '^x-cache'

step "Avis au-delà des 5 embarqués (pattern Subset)"
call GET "/produits/$CPU/avis?limite=3"

# -----------------------------------------------------------------------------
title "LOT 2 — Session anonyme et panier Redis"
# -----------------------------------------------------------------------------
step "Nouvelle session anonyme"
call POST /sessions
SID=$(json '["sid"]')
echo "SID=$SID"

step "Consultations (événements page_view → Cassandra + historique Redis)"
for sku in GPU-ASUS-RTX4070S-12 "$CPU" CM-ASUS-B650A-WIFI; do
  call POST /evenements "{\"type\":\"page_view\",\"sku\":\"$sku\",\"page\":\"/fiche/$sku.html\"}"
done
call POST /evenements '{"type":"search","recherche":"carte mere am5","nb_resultats":12}'

step "Produits consultés récemment (LIST recent:{anon:…})"
call GET /historique

step "Ajout au panier via le script Lua (atomique)"
call POST /panier/articles '{"sku":"CM-ASUS-B650A-WIFI","quantite":1}'
call POST /panier/articles '{"sku":"RAM-CORSAIR-DDR5-32-6000","quantite":2}'

step "Plafond par article : 15 cartes graphiques demandées, plafond = 3"
call POST /panier/articles '{"sku":"GPU-ASUS-RTX4070S-12","quantite":15}'

step "Modification de quantité (valeur absolue)"
call PUT /panier/articles/GPU-ASUS-RTX4070S-12 '{"quantite":1}'

step "Panier anonyme"
call GET /panier

step "Connexion de user:42 : nouveau sid + fusion du panier anonyme dans cart:{user:42}"
call POST /sessions/connexion '{"customer_id":"user:42"}'
SID=$(json '["sid"]')
call GET /panier

# -----------------------------------------------------------------------------
title "LOT 4 — Recommandations Neo4j"
# -----------------------------------------------------------------------------
step "« Les clients qui ont acheté ce processeur ont aussi acheté » (cartes mères)"
call GET "/recommandations/produits/$CPU/aussi-achetes?categorie=cartes-meres"

step "Compatibilités déduites par parcours (boîtier Fractal North)"
call GET /recommandations/produits/BOI-FRACTAL-NORTH/compatibles

step "Configurateur : CPU → carte mère → RAM + boîtier (+ GPU)"
call GET "/recommandations/configurateur?cpu=$CPU&limite=3"

step "Produits similaires"
call GET "/recommandations/produits/$CPU/similaires"

step "Recommandations personnalisées pour user:42"
call GET /recommandations/clients/user:42

step "Amis d'amis et achats de l'entourage"
call GET "/recommandations/clients/user:42/suggestions-amis?limite=5"
call GET "/recommandations/clients/user:42/entourage?limite=3"

# -----------------------------------------------------------------------------
title "LOT 3 — Commande (MongoDB → Cassandra → Neo4j)"
# -----------------------------------------------------------------------------
step "Passage de la commande"
call POST /commandes '{"paiement":"carte_bancaire"}'
ORDER_ID=$(json '["order_id"]')
echo "ORDER_ID=$ORDER_ID"

step "Le panier est vidé"
call GET /panier

step "Historique de commandes de user:42 (une partition Cassandra)"
call GET "/commandes?limite=3"

step "Changement de statut (BATCH sur les deux tables)"
call PATCH "/commandes/$ORDER_ID/statut" '{"statut":"expediee","transporteur":"Colissimo","suivi":"6A12345678901"}'

step "Dépôt d'un avis (Subset + Computed ; 409 si déjà déposé)"
call POST /produits/SOU-LOGI-G502X/avis '{"note":5,"titre":"Excellente souris","commentaire":"Confortable et précise."}'

# -----------------------------------------------------------------------------
title "LOT 3 — Analytics Cassandra"
# -----------------------------------------------------------------------------
step "« Combien de vues pour ce produit aujourd'hui ? » (+ 7 derniers jours)"
call GET "/analytics/produits/$CPU/vues?jours=7"

step "Job du top hebdomadaire puis lecture du classement"
call POST /analytics/jobs/top-semaine
call GET "/analytics/top-semaine?limite=5"
call GET "/analytics/top-semaine?categorie=processeurs&limite=3"

step "Statistiques du jour et derniers événements bruts (16 shards)"
call GET /analytics/jour
call GET "/analytics/evenements?limite=5"

step "Job nocturne BOUGHT_WITH (intègre la nouvelle commande)"
call POST /recommandations/jobs/bought-with

step "Changement de prix : invalidation du cache (MISS au prochain appel)"
call PATCH /produits/BOI-CORSAIR-4000D/prix '{"prix":99.95}'
curl -sS -o /dev/null -D - "$API/produits/BOI-CORSAIR-4000D" | grep -i '^x-cache'

step "Déconnexion"
call POST /sessions/deconnexion

title "Démonstration terminée"
