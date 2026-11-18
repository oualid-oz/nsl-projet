"""Lot 3 — Lectures analytiques et job du top hebdomadaire (Cassandra)."""
import datetime as dt
from collections import Counter

from .. import config
from ..db import cassandra, mongo, prep
from ..utils import utcnow


def iso_week(day: dt.date) -> str:
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def week_days(week: str) -> list[dt.date]:
    year, w = week.split("-W")
    return [dt.date.fromisocalendar(int(year), int(w), d) for d in range(1, 8)]


def product_views(sku: str, days: int) -> dict:
    """« Combien de vues pour ce produit aujourd'hui / sur N jours ? »
    Une seule partition (sku), tranche sur la clustering column day."""
    today = utcnow().date()
    since = today - dt.timedelta(days=days - 1)
    rows = cassandra().execute(prep(
        "SELECT day, views, clicks, add_to_cart FROM product_views_by_day WHERE sku = ? AND day >= ? AND day <= ?"
    ), (sku, since, today))
    series = [{"jour": str(r.day), "vues": r.views or 0, "clics": r.clicks or 0, "ajouts_panier": r.add_to_cart or 0}
              for r in rows]
    today_row = next((s for s in series if s["jour"] == today.isoformat()), None)
    return {
        "sku": sku,
        "aujourd_hui": today_row["vues"] if today_row else 0,
        "total_periode": sum(s["vues"] for s in series),
        "jours": series,
    }


def daily_views_all_products(day: dt.date) -> Counter:
    """Vues de tous les produits pour un jour : 8 partitions (shards), IN."""
    rows = cassandra().execute(prep(
        "SELECT sku, views FROM daily_product_views WHERE day = ? AND shard IN ?"
    ), (day, list(range(config.DAILY_VIEW_SHARDS))))
    return Counter({r.sku: r.views for r in rows})


def compute_weekly_top(week: str | None = None, size: int = 100, per_category: int = 20) -> dict:
    """Job (nocturne en production) : additionne les vues des 7 jours de la
    semaine, trie, et écrit le classement global ('all') et un classement
    par catégorie dans top_products_by_week. Le site ne lit que le résultat."""
    week = week or iso_week(utcnow().date())
    today = utcnow().date()
    totals: Counter = Counter()
    for day in week_days(week):
        if day <= today:
            totals += daily_views_all_products(day)

    products = {p["_id"]: p for p in mongo().products.find(
        {"_id": {"$in": list(totals)}}, {"name": 1, "brand.name": 1, "category._id": 1})}
    ranking = [(sku, views) for sku, views in totals.most_common() if sku in products]

    by_category: dict[str, list] = {"all": ranking[:size]}
    for sku, views in ranking:
        cat = products[sku]["category"]["_id"]
        if len(by_category.setdefault(cat, [])) < per_category:
            by_category[cat].append((sku, views))

    s = cassandra()
    now = utcnow()
    insert = prep("""INSERT INTO top_products_by_week (week, category_id, rank, sku, name, brand, views, computed_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)""")
    delete = prep("DELETE FROM top_products_by_week WHERE week = ? AND category_id = ?")
    for cat, rows in by_category.items():
        s.execute(delete, (week, cat))       # efface un éventuel classement plus long
        for rank, (sku, views) in enumerate(rows, start=1):
            p = products[sku]
            s.execute(insert, (week, cat, rank, sku, p["name"], p["brand"]["name"], views, now))
    return {"semaine": week, "produits_classes": len(ranking), "classements_ecrits": sorted(by_category)}


def weekly_top(week: str, category: str, limit: int) -> list[dict]:
    rows = cassandra().execute(prep(
        "SELECT rank, sku, name, brand, views, computed_at FROM top_products_by_week "
        "WHERE week = ? AND category_id = ? LIMIT ?"
    ), (week, category, limit))
    return [{"rang": r.rank, "sku": r.sku, "nom": r.name, "marque": r.brand, "vues": r.views,
             "calcule_le": r.computed_at.isoformat() if r.computed_at else None} for r in rows]


def site_stats(day: dt.date) -> dict:
    rows = cassandra().execute(prep("SELECT event_type, total FROM daily_site_stats WHERE day = ?"), (day,))
    return {"jour": day.isoformat(), "evenements": {r.event_type: r.total for r in rows}}


def raw_events(hour: dt.datetime, limit: int) -> list[dict]:
    """Événements bruts d'une heure : 16 partitions lues EN PARALLÈLE
    (une par shard), puis fusionnées par horodatage décroissant."""
    stmt = prep("SELECT event_id, event_type, session_id, customer_id, sku, search_query, page_url, device "
                "FROM events_by_hour WHERE bucket_hour = ? AND shard = ? LIMIT ?")
    s = cassandra()
    futures = [s.execute_async(stmt, (hour, shard, limit)) for shard in range(config.EVENT_SHARDS)]
    events = []
    for shard, fut in enumerate(futures):
        for r in fut.result():
            events.append({
                "shard": shard, "event_id": str(r.event_id),
                "horodatage": dt.datetime.fromtimestamp((r.event_id.time - 0x01B21DD213814000) / 1e7,
                                                        dt.timezone.utc).isoformat(),
                "type": r.event_type, "session": r.session_id[:8] + "…", "client": r.customer_id,
                "sku": r.sku, "recherche": r.search_query, "page": r.page_url, "appareil": r.device,
            })
    events.sort(key=lambda e: e["horodatage"], reverse=True)
    return events[:limit]

