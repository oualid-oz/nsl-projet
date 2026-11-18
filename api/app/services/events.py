"""Lot 3 — Événements de navigation (Cassandra) et effets de bord :
historique Redis (lot 2) et relation VIEWED dans Neo4j (lot 4)."""
import datetime as dt
import zlib

from cassandra.util import uuid_from_time

from .. import config
from ..db import cassandra, cypher, prep
from ..utils import utcnow
from . import sessions

EVENT_TYPES = ("page_view", "click", "search", "add_to_cart")
# Colonne de product_views_by_day incrémentée selon le type d'événement
PRODUCT_COUNTER = {"page_view": "views", "click": "clicks", "add_to_cart": "add_to_cart"}


def event_shard(session_id: str) -> int:
    """hash(session_id) % 16 — crc32 plutôt que hash() : stable entre processus."""
    return zlib.crc32(session_id.encode()) % config.EVENT_SHARDS


def sku_shard(sku: str) -> int:
    return zlib.crc32(sku.encode()) % config.DAILY_VIEW_SHARDS


def bucket_hour(at: dt.datetime) -> dt.datetime:
    return at.replace(minute=0, second=0, microsecond=0)


INSERT_EVENT = """
INSERT INTO events_by_hour (bucket_hour, shard, event_id, event_type, session_id, customer_id, sku,
                            page_url, referrer, search_query, results_count, element, device, user_agent)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


def insert_raw_event(event_type: str, session_id: str, at: dt.datetime | None = None, *,
                     customer_id=None, sku=None, page_url=None, referrer=None, search_query=None,
                     results_count=None, element=None, device="desktop", user_agent=None):
    """Événement brut : partition (heure, shard), clustering timeuuid.
    Le TTL de 13 mois est appliqué par la table (default_time_to_live)."""
    at = at or utcnow()
    event_id = uuid_from_time(at)
    cassandra().execute(prep(INSERT_EVENT), (
        bucket_hour(at), event_shard(session_id), event_id, event_type, session_id, customer_id or None,
        sku, page_url, referrer, search_query, results_count, element, device, user_agent,
    ))
    return event_id


def increment_counters(day: dt.date, event_type: str, sku: str | None = None, n: int = 1) -> None:
    """Compteurs (tables COUNTER) : une écriture par table de requête.
    En production, le consumer d'ingestion pré-agrège par minute (n > 1)."""
    s = cassandra()
    col = PRODUCT_COUNTER.get(event_type)
    if sku and col:
        s.execute(prep(f"UPDATE product_views_by_day SET {col} = {col} + ? WHERE sku = ? AND day = ?"),
                  (n, sku, day))
    if sku and event_type == "page_view":
        s.execute(prep("UPDATE daily_product_views SET views = views + ? WHERE day = ? AND shard = ? AND sku = ?"),
                  (n, day, sku_shard(sku), sku))
    s.execute(prep("UPDATE daily_site_stats SET total = total + ? WHERE day = ? AND event_type = ?"),
              (n, day, event_type))


def track(session: dict, event_type: str, **fields) -> dict:
    """Point d'entrée de l'API : un événement → Cassandra (brut + compteurs),
    Redis (produits récemment consultés) et Neo4j (VIEWED, client connecté)."""
    at = utcnow()
    customer_id = session.get("user_id") or None
    sku = fields.get("sku")
    event_id = insert_raw_event(event_type, session["sid"], at, customer_id=customer_id, **fields)
    increment_counters(at.date(), event_type, sku)

    effects = ["cassandra:events_by_hour", "cassandra:compteurs"]
    if event_type == "page_view" and sku:
        sessions.push_recent(session["cart_owner"], sku)
        effects.append("redis:recent")
        if customer_id:
            cypher("""
                MATCH (p:Product {sku: $sku})
                MERGE (c:Customer {id: $cid}) ON CREATE SET c.pseudo = $cid
                MERGE (c)-[v:VIEWED]->(p) ON CREATE SET v.count = 0
                SET v.count = v.count + 1, v.last_seen = date()
            """, sku=sku, cid=customer_id)
            effects.append("neo4j:VIEWED")
    return {"event_id": str(event_id), "horodatage": at.isoformat(), "bucket_hour": bucket_hour(at).isoformat(),
            "shard": event_shard(session["sid"]), "ecritures": effects}
