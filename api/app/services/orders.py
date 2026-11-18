"""Commandes : stock MongoDB (lot 1) → Cassandra (lot 3, deux tables
dénormalisées) → Neo4j (lot 4, relations BOUGHT)."""
import datetime as dt
import random
from decimal import Decimal

from cassandra.query import BatchStatement, BatchType
from fastapi import HTTPException

from .. import config
from ..db import OrderLine, PostalAddress, cassandra, cypher, mongo, prep
from ..utils import to_jsonable, utcnow
from . import catalogue

STATUSES = ("payee", "preparation", "expediee", "livree", "annulee")
CENT = Decimal("0.01")

INSERT_BY_CUSTOMER = """
INSERT INTO orders_by_customer (customer_id, order_date, order_id, status, total_amount, shipping_fee, currency,
                                items_count, lines, shipping_address, carrier, tracking_number)
VALUES (?, ?, ?, ?, ?, ?, 'EUR', ?, ?, ?, ?, ?)
"""
INSERT_BY_ID = """
INSERT INTO orders_by_id (order_id, customer_id, order_date, status, total_amount, shipping_fee, currency, items_count,
                          lines, shipping_address, billing_address, payment_method, carrier, tracking_number)
VALUES (?, ?, ?, ?, ?, ?, 'EUR', ?, ?, ?, ?, ?, ?, ?)
"""


def new_order_id(at: dt.datetime) -> str:
    return f"LD{at:%y%m%d}{random.randint(0, 9999):04d}"


def default_address(customer_id: str) -> dict:
    return {"recipient": f"Client {customer_id.split(':', 1)[-1]}", "street": "2 rue des Érables",
            "postal_code": "69760", "city": "Limonest", "country": "FR"}


def build_lines(items: dict[str, int]) -> list[OrderLine]:
    """Lignes « photographiées » avec le prix ACTUEL de MongoDB (pas celui
    du cache) : c'est ce prix qui sera facturé."""
    products = {p["_id"]: p for p in mongo().products.find({"_id": {"$in": list(items)}},
                                                          {"name": 1, "price": 1})}
    missing = set(items) - set(products)
    if missing:
        raise HTTPException(404, f"Produits inconnus : {sorted(missing)}")
    lines = []
    for sku, qty in items.items():
        price = products[sku]["price"]["amount"].to_decimal().quantize(CENT)
        lines.append(OrderLine(sku=sku, name=products[sku]["name"], unit_price=price,
                               quantity=qty, line_total=(price * qty).quantize(CENT)))
    return lines


def write_order(customer_id: str, order_id: str, at: dt.datetime, lines: list[OrderLine], status: str,
                address: dict | None = None, payment: str = "carte_bancaire",
                carrier: str | None = None, tracking: str | None = None) -> dict:
    """Écrit la commande dans Cassandra (BATCH LOGGED sur les deux tables)
    puis dans Neo4j (une relation BOUGHT par ligne, MERGE = idempotent)."""
    subtotal = sum((l.line_total for l in lines), Decimal("0"))
    fee = Decimal("0.00") if subtotal >= config.FREE_SHIPPING_FROM else Decimal(config.SHIPPING_FEE)
    total = (subtotal + fee).quantize(CENT)
    items_count = sum(l.quantity for l in lines)
    addr = PostalAddress(**(address or default_address(customer_id)))

    batch = BatchStatement(batch_type=BatchType.LOGGED)
    batch.add(prep(INSERT_BY_CUSTOMER), (customer_id, at, order_id, status, total, fee, items_count,
                                         lines, addr, carrier, tracking))
    batch.add(prep(INSERT_BY_ID), (order_id, customer_id, at, status, total, fee, items_count,
                                   lines, addr, addr, payment, carrier, tracking))
    cassandra().execute(batch)

    cypher("""
        MERGE (c:Customer {id: $cid}) ON CREATE SET c.pseudo = $cid
        WITH c
        UNWIND $lines AS l
        MATCH (p:Product {sku: l.sku})
        MERGE (c)-[b:BOUGHT {order_id: $oid}]->(p)
        SET b.date = date($date), b.quantity = l.quantity, b.unit_price = l.unit_price
    """, cid=customer_id, oid=order_id, date=at.date().isoformat(),
           lines=[{"sku": l.sku, "quantity": l.quantity, "unit_price": float(l.unit_price)} for l in lines])

    return {"order_id": order_id, "customer_id": customer_id, "order_date": at.isoformat(), "status": status,
            "total_amount": float(total), "shipping_fee": float(fee), "items_count": items_count,
            "lines": to_jsonable(lines)}


def place_order(customer_id: str, items: dict[str, int], address: dict | None, payment: str) -> dict:
    """Commande depuis le panier : réservation du stock (décrément atomique
    conditionnel, compensé en cas d'échec), puis écriture Cassandra + Neo4j."""
    if not items:
        raise HTTPException(400, "Panier vide")
    lines = build_lines(items)
    reserved = []
    try:
        for line in lines:
            updated = catalogue.decrement_stock(line.sku, line.quantity)
            if updated is None:
                raise HTTPException(409, f"Stock insuffisant pour {line.sku}")
            reserved.append((line.sku, line.quantity, updated["stock"]["status"]))
        at = utcnow()
        order = write_order(customer_id, new_order_id(at), at, lines, "payee", address, payment)
    except Exception:
        for sku, qty, _ in reserved:          # compensation (pas de transaction inter-bases)
            catalogue.restock(sku, qty)
        raise
    # Le stock a changé : fiches en cache invalidées, statut répercuté dans le graphe
    catalogue.invalidate(*[sku for sku, _, _ in reserved])
    cypher("UNWIND $rows AS r MATCH (p:Product {sku: r.sku}) SET p.stock_status = r.status",
           rows=[{"sku": sku, "status": status} for sku, _, status in reserved])
    return order


def _order_row(r) -> dict:
    d = {k: getattr(r, k) for k in r._fields}
    return to_jsonable(d)


def orders_of_customer(customer_id: str, before: dt.datetime | None, limit: int) -> list[dict]:
    """« Historique de commandes d'un client » : une partition, triée par
    date décroissante ; pagination par la clustering column (avant=…)."""
    if before:
        rows = cassandra().execute(prep(
            "SELECT * FROM orders_by_customer WHERE customer_id = ? AND order_date < ? LIMIT ?"
        ), (customer_id, before, limit))
    else:
        rows = cassandra().execute(prep(
            "SELECT * FROM orders_by_customer WHERE customer_id = ? LIMIT ?"), (customer_id, limit))
    return [_order_row(r) for r in rows]


def get_order(order_id: str) -> dict | None:
    row = cassandra().execute(prep("SELECT * FROM orders_by_id WHERE order_id = ?"), (order_id,)).one()
    return _order_row(row) if row else None


def update_status(order_id: str, status: str, carrier: str | None, tracking: str | None) -> dict:
    """Mise à jour des DEUX copies dans un BATCH LOGGED. On lit d'abord
    orders_by_id pour connaître la clé complète dans orders_by_customer."""
    row = cassandra().execute(prep(
        "SELECT customer_id, order_date, carrier, tracking_number FROM orders_by_id WHERE order_id = ?"
    ), (order_id,)).one()
    if row is None:
        raise HTTPException(404, "Commande inconnue")
    carrier = carrier or row.carrier
    tracking = tracking or row.tracking_number
    batch = BatchStatement(batch_type=BatchType.LOGGED)
    batch.add(prep("UPDATE orders_by_id SET status = ?, carrier = ?, tracking_number = ? WHERE order_id = ?"),
              (status, carrier, tracking, order_id))
    batch.add(prep("UPDATE orders_by_customer SET status = ?, carrier = ?, tracking_number = ? "
                   "WHERE customer_id = ? AND order_date = ? AND order_id = ?"),
              (status, carrier, tracking, row.customer_id, row.order_date, order_id))
    cassandra().execute(batch)
    return get_order(order_id)
