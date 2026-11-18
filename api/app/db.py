"""Connexions aux quatre bases (une instance partagée par processus).

Les clients sont synchrones : FastAPI exécute les routes `def` dans un pool
de threads, et les quatre drivers sont thread-safe.
"""
import logging
import time

import redis
from cassandra.cluster import EXEC_PROFILE_DEFAULT, Cluster, ExecutionProfile
from cassandra.policies import DCAwareRoundRobinPolicy
from neo4j import GraphDatabase
from pymongo import MongoClient

from . import config

log = logging.getLogger("ldlc.db")


# --- Types utilisateur Cassandra (lot 3) -------------------------------------
#  Enregistrés auprès du driver : on écrit et on lit des objets Python.
class OrderLine:
    def __init__(self, sku=None, name=None, unit_price=None, quantity=None, line_total=None):
        self.sku = sku
        self.name = name
        self.unit_price = unit_price
        self.quantity = quantity
        self.line_total = line_total


class PostalAddress:
    def __init__(self, recipient=None, street=None, postal_code=None, city=None, country=None):
        self.recipient = recipient
        self.street = street
        self.postal_code = postal_code
        self.city = city
        self.country = country


_mongo = None
_redis = None
_cluster = None
_cassandra = None
_neo4j = None
_prepared = {}


def mongo():
    """Base `ldlc` (lot 1)."""
    global _mongo
    if _mongo is None:
        _mongo = MongoClient(config.MONGO_URI, serverSelectionTimeoutMS=5000, tz_aware=True)
    return _mongo[config.MONGO_DB]


def rds() -> redis.Redis:
    """Client Redis (lot 2)."""
    global _redis
    if _redis is None:
        _redis = redis.Redis(host=config.REDIS_HOST, port=config.REDIS_PORT, decode_responses=True)
    return _redis


def cassandra():
    """Session Cassandra sur le keyspace ldlc_analytics (lot 3)."""
    global _cluster, _cassandra
    if _cassandra is None:
        profile = ExecutionProfile(load_balancing_policy=DCAwareRoundRobinPolicy(local_dc=config.CASSANDRA_DC))
        _cluster = Cluster(config.CASSANDRA_HOSTS, port=config.CASSANDRA_PORT,
                           execution_profiles={EXEC_PROFILE_DEFAULT: profile})
        session = _cluster.connect(config.CASSANDRA_KEYSPACE)
        _cluster.register_user_type(config.CASSANDRA_KEYSPACE, "order_line", OrderLine)
        _cluster.register_user_type(config.CASSANDRA_KEYSPACE, "postal_address", PostalAddress)
        _cassandra = session
    return _cassandra


def prep(cql: str):
    """Requête préparée, mise en cache (parsée une seule fois par le cluster)."""
    if cql not in _prepared:
        _prepared[cql] = cassandra().prepare(cql)
    return _prepared[cql]


def neo4j():
    """Driver Neo4j (lot 4)."""
    global _neo4j
    if _neo4j is None:
        _neo4j = GraphDatabase.driver(config.NEO4J_URI, auth=(config.NEO4J_USER, config.NEO4J_PASSWORD))
    return _neo4j


def cypher(query: str, **params) -> list[dict]:
    """Exécute une requête Cypher et renvoie les lignes sous forme de dict."""
    records, _, _ = neo4j().execute_query(query, params, database_="neo4j")
    return [r.data() for r in records]


def ping_all() -> dict:
    """État de chaque base (utilisé par /sante)."""
    status = {}
    checks = {
        "mongodb": lambda: mongo().command("ping"),
        "redis": lambda: rds().ping(),
        "cassandra": lambda: cassandra().execute("SELECT release_version FROM system.local").one(),
        "neo4j": lambda: neo4j().verify_connectivity(),
    }
    for name, check in checks.items():
        try:
            check()
            status[name] = "ok"
        except Exception as exc:  # noqa: BLE001 — on veut le message, quel qu'il soit
            status[name] = f"erreur : {exc.__class__.__name__}: {exc}"[:300]
    return status


def connect_all(retries: int = 30, delay: float = 2.0) -> None:
    """Attend que les quatre bases répondent (démarrage de l'API ou du seed)."""
    for attempt in range(1, retries + 1):
        status = ping_all()
        if all(v == "ok" for v in status.values()):
            log.info("Connecté aux 4 bases")
            return
        log.warning("Bases pas encore prêtes (%s/%s) : %s", attempt, retries, status)
        time.sleep(delay)
    raise RuntimeError(f"Impossible de se connecter aux bases : {ping_all()}")


def close_all() -> None:
    if _cluster is not None:
        _cluster.shutdown()
    if _neo4j is not None:
        _neo4j.close()
    if _mongo is not None:
        _mongo.close()
