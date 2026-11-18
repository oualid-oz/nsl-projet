--[[
=============================================================================
  Refonte LDLC — Lot 2 : Panier (Redis)
  cart_add.lua — Ajout ATOMIQUE d'un article au panier, avec plafond
                 de quantité par article et TTL glissant
=============================================================================

  Pourquoi un script Lua ?
  ------------------------
  « Lire la quantité, la plafonner, l'écrire, relancer le TTL » demande
  plusieurs commandes. Envoyées séparément, deux requêtes simultanées (double
  clic, deux onglets, deux serveurs web) pourraient s'intercaler et dépasser
  le plafond. Redis exécute un script Lua de façon atomique : aucune autre
  commande ne s'exécute pendant le script. C'est aussi un seul aller-retour
  réseau.

  Toutes les clés touchées sont passées dans KEYS (obligatoire en Redis
  Cluster pour router le script vers le bon nœud).

  Paramètres
  ----------
    KEYS[1]  clé du panier, ex. cart:{user:42}  ou  cart:{anon:<sid>}
    ARGV[1]  SKU du produit                     ex. RAM-CORSAIR-DDR5-32-6000
    ARGV[2]  quantité à ajouter (entier >= 1)
    ARGV[3]  quantité maximale par article      ex. 10 (ou 2 pour une
             carte graphique en promotion limitée)
    ARGV[4]  TTL du panier en secondes          ex. 2592000 (30 j) / 259200 (3 j)
    ARGV[5]  (optionnel) nombre maximal de lignes distinctes, défaut 100

  Retour
  ------
    { quantité finale de l'article,
      1 si la quantité a été plafonnée sinon 0,
      nombre de lignes du panier }

  Exemples
  --------
    redis-cli --eval cart_add.lua 'cart:{user:42}' , RAM-CORSAIR-DDR5-32-6000 2 10 2592000
      -> 1) 2   2) 0   3) 1
    redis-cli --eval cart_add.lua 'cart:{user:42}' , RAM-CORSAIR-DDR5-32-6000 15 10 2592000
      -> 1) 10  2) 1   3) 1      (17 demandés, plafonné à 10)

    Depuis l'application : SCRIPT LOAD au démarrage, puis
      EVALSHA <sha1> 1 cart:{user:42} RAM-CORSAIR-DDR5-32-6000 2 10 2592000
=============================================================================
]]

local cart_key  = KEYS[1]
local sku       = ARGV[1]
local delta     = tonumber(ARGV[2])
local max_qty   = tonumber(ARGV[3])
local ttl       = tonumber(ARGV[4])
local max_lines = tonumber(ARGV[5] or "100")

-- --- Validation des paramètres ----------------------------------------------
-- Le script est la dernière barrière avant les données : on ne fait pas
-- confiance à l'appelant.
if not cart_key or cart_key == "" then
  return redis.error_reply("ERR clé du panier manquante")
end
if not sku or sku == "" then
  return redis.error_reply("ERR SKU manquant")
end
if not delta or delta < 1 or delta ~= math.floor(delta) then
  return redis.error_reply("ERR quantité à ajouter invalide (entier >= 1 attendu)")
end
if not max_qty or max_qty < 1 or max_qty ~= math.floor(max_qty) then
  return redis.error_reply("ERR plafond invalide (entier >= 1 attendu)")
end
if not ttl or ttl < 1 then
  return redis.error_reply("ERR TTL invalide (secondes > 0 attendues)")
end
if not max_lines or max_lines < 1 then
  return redis.error_reply("ERR nombre maximal de lignes invalide")
end

-- --- Lecture de la quantité actuelle ------------------------------------------
-- HGET renvoie false (nil Redis) si l'article n'est pas encore dans le panier.
local current = tonumber(redis.call("HGET", cart_key, sku) or "0") or 0

-- Nouvel article : on vérifie que le panier n'a pas déjà trop de lignes
-- (protection contre les robots qui rempliraient la mémoire).
if current == 0 and redis.call("HLEN", cart_key) >= max_lines then
  return redis.error_reply("ERR panier plein (" .. max_lines .. " articles distincts maximum)")
end

-- --- Calcul avec plafond -----------------------------------------------------
local new_qty = current + delta
local capped  = 0
if new_qty > max_qty then
  new_qty = max_qty
  capped  = 1
end

-- --- Écriture + TTL glissant -------------------------------------------------
-- Les deux commandes sont dans le même script : un panier n'est jamais
-- écrit sans que son TTL soit relancé (pas de panier « immortel »).
redis.call("HSET", cart_key, sku, new_qty)
redis.call("EXPIRE", cart_key, ttl)

return { new_qty, capped, redis.call("HLEN", cart_key) }
