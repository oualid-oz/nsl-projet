"""Configuration de l'API, lue dans les variables d'environnement."""
import os

# --- Connexions -------------------------------------------------------------
MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
MONGO_DB = os.getenv("MONGO_DB", "ldlc")

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

CASSANDRA_HOSTS = os.getenv("CASSANDRA_HOSTS", "localhost").split(",")
CASSANDRA_PORT = int(os.getenv("CASSANDRA_PORT", "9042"))
CASSANDRA_KEYSPACE = os.getenv("CASSANDRA_KEYSPACE", "ldlc_analytics")
CASSANDRA_DC = os.getenv("CASSANDRA_DC", "datacenter1")

NEO4J_URI = os.getenv("NEO4J_URI", "neo4j://localhost:7687")
NEO4J_USER = os.getenv("NEO4J_USER", "neo4j")
NEO4J_PASSWORD = os.getenv("NEO4J_PASSWORD", "ldlc-password")

# --- Lot 2 : durées de vie (secondes), mêmes valeurs que commands.redis -----
SESSION_TTL = 1800                 # 30 min d'inactivité
CART_TTL_USER = 30 * 24 * 3600     # 30 jours pour un client connecté
CART_TTL_ANON = 3 * 24 * 3600      # 3 jours pour un visiteur anonyme
RECENT_TTL = 30 * 24 * 3600
RECENT_MAX = 20
CACHE_PRODUCT_TTL = 3600           # + aléa de 0 à 300 s
CACHE_PRODUCT_JITTER = 300

# Plafond de quantité par article (passé au script Lua cart_add.lua)
MAX_QTY_DEFAULT = 10
MAX_QTY_BY_TYPE = {"carte_graphique": 3, "processeur": 5}
MAX_CART_LINES = 100

CART_LUA_PATH = os.getenv("CART_LUA_PATH", "../lot2-panier-sessions-redis/cart_add.lua")

# --- Lot 3 : sharding (identique à schema.cql) -------------------------------
EVENT_SHARDS = 16        # events_by_hour : hash(session_id) % 16
DAILY_VIEW_SHARDS = 8    # daily_product_views : hash(sku) % 8

# --- Commandes ----------------------------------------------------------------
FREE_SHIPPING_FROM = 500   # livraison offerte à partir de 500 €
SHIPPING_FEE = "6.95"
