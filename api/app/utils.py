"""Conversion des types propres aux drivers (Decimal128, ObjectId, UUID,
dates Cassandra / Neo4j, UDT) en types JSON."""
import datetime as dt
import uuid
from decimal import Decimal

from bson import Decimal128, ObjectId
from cassandra.util import Date as CassandraDate


def to_jsonable(o):
    if isinstance(o, dict):
        return {str(k): to_jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple, set)):
        return [to_jsonable(v) for v in o]
    if isinstance(o, Decimal128):
        return float(o.to_decimal())
    if isinstance(o, Decimal):
        return float(o)
    if isinstance(o, (ObjectId, uuid.UUID)):
        return str(o)
    if isinstance(o, (dt.datetime, dt.date)):
        return o.isoformat()
    if isinstance(o, CassandraDate):
        return str(o)
    if hasattr(o, "iso_format"):          # neo4j.time.Date / DateTime
        return o.iso_format()
    if hasattr(o, "__dict__") and not isinstance(o, type):   # UDT Cassandra
        return to_jsonable(vars(o))
    return o


def coerce(value: str):
    """Convertit un paramètre d'URL en bool / int / float si possible."""
    low = value.lower()
    if low in ("true", "false"):
        return low == "true"
    for cast in (int, float):
        try:
            return cast(value)
        except ValueError:
            pass
    return value


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)
