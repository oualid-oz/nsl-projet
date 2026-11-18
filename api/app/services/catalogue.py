"""Lot 1 — Catalogue MongoDB, avec cache Redis « cache-aside » (lot 2)."""
import json
import random

from bson import Decimal128

from .. import config
from ..db import mongo, rds
from ..utils import to_jsonable, utcnow


def cache_key(sku: str) -> str:
    # Pas de hash tag : les fiches doivent se répartir sur tout le cluster.
    return f"cache:product:{sku}"


def get_product(sku: str) -> tuple[dict | None, bool]:
    """Fiche produit en cache-aside. Renvoie (document, cache_hit).

    1) GET cache:product:<sku> ; 2) si absent, findOne MongoDB (une seule
    lecture grâce aux patterns du lot 1) puis SET ... EX 3600 + aléa.
    """
    r = rds()
    raw = r.get(cache_key(sku))
    if raw is not None:
        return json.loads(raw), True
    doc = mongo().products.find_one({"_id": sku})
    if doc is None:
        return None, False
    data = to_jsonable(doc)
    ttl = config.CACHE_PRODUCT_TTL + random.randint(0, config.CACHE_PRODUCT_JITTER)
    r.set(cache_key(sku), json.dumps(data, ensure_ascii=False), ex=ttl)
    return data, False


def invalidate(*skus: str) -> None:
    """Invalidation après écriture (rôle joué en production par un consumer
    des Change Streams MongoDB)."""
    if skus:
        rds().delete(*[cache_key(s) for s in skus])


def max_qty_for(product: dict) -> int:
    return config.MAX_QTY_BY_TYPE.get(product.get("type"), config.MAX_QTY_DEFAULT)


def stock_status(quantity: int) -> str:
    return "rupture" if quantity == 0 else "stock_faible" if quantity < 10 else "en_stock"


def decrement_stock(sku: str, qty: int) -> dict | None:
    """Décrément ATOMIQUE et conditionnel : réussit seulement si le stock
    suffit (le filtre et la mise à jour sont appliqués ensemble par MongoDB).
    Le statut est recalculé dans le même pipeline."""
    return mongo().products.find_one_and_update(
        {"_id": sku, "stock.quantity": {"$gte": qty}},
        [
            {"$set": {"stock.quantity": {"$subtract": ["$stock.quantity", qty]}, "updated_at": "$$NOW"}},
            {"$set": {"stock.status": {"$switch": {
                "branches": [
                    {"case": {"$eq": ["$stock.quantity", 0]}, "then": "rupture"},
                    {"case": {"$lt": ["$stock.quantity", 10]}, "then": "stock_faible"},
                ],
                "default": "en_stock",
            }}}},
        ],
        projection={"stock": 1},
        return_document=True,
    )


def restock(sku: str, qty: int) -> None:
    """Compensation si une commande échoue après avoir réservé du stock."""
    mongo().products.update_one(
        {"_id": sku},
        [
            {"$set": {"stock.quantity": {"$add": ["$stock.quantity", qty]}}},
            {"$set": {"stock.status": {"$cond": [{"$lt": ["$stock.quantity", 10]}, "stock_faible", "en_stock"]}}},
        ],
    )


# --- Avis : patterns Subset + Computed (+ migration paresseuse v1 → v2) -------

def rebuild_rating_and_subset(sku: str) -> None:
    """Recalcule note et 5 derniers avis depuis la collection reviews, et
    migre au passage un document v1 en v2 (Schema Versioning)."""
    db = mongo()
    reviews = list(db.reviews.find({"product_id": sku}).sort("date", -1))
    dist = {str(n): sum(1 for r in reviews if r["rating"] == n) for n in range(1, 6)}
    count = len(reviews)
    average = round(sum(r["rating"] for r in reviews) / count, 2) if count else None
    latest = [{
        "review_id": r["_id"], "pseudo": r["author"]["pseudo"], "rating": r["rating"],
        "title": r.get("title", ""), "excerpt": r.get("comment", "")[:140], "date": r["date"],
    } for r in reviews[:5]]
    doc = db.products.find_one({"_id": sku}, {"image": 1, "images": 1})
    images = doc.get("images") or ([doc["image"]] if doc.get("image") else [])
    db.products.update_one({"_id": sku}, {
        "$set": {"schema_version": 2, "images": images, "latest_reviews": latest,
                 "rating": {"average": average, "count": count, "distribution": dist},
                 "updated_at": utcnow()},
        "$unset": {"image": "", "rating_avg": "", "reviews_count": ""},
    })


def apply_new_review(sku: str, review: dict) -> None:
    """Mise à jour incrémentale (document v2) : distribution et count
    incrémentés, moyenne recalculée depuis la distribution, nouvel avis en
    tête de latest_reviews tronqué à 5 — même pipeline que queries.js Q12."""
    n = str(review["rating"])
    subset = {"review_id": review["_id"], "pseudo": review["author"]["pseudo"], "rating": review["rating"],
              "title": review["title"], "excerpt": review["comment"][:140], "date": review["date"]}
    weighted = {"$add": [{"$multiply": [k, f"$rating.distribution.{k}"]} for k in range(1, 6)]}
    mongo().products.update_one({"_id": sku}, [
        {"$set": {
            f"rating.distribution.{n}": {"$add": [f"$rating.distribution.{n}", 1]},
            "rating.count": {"$add": ["$rating.count", 1]},
            "latest_reviews": {"$slice": [{"$concatArrays": [[{"$literal": subset}], "$latest_reviews"]}, 5]},
            "updated_at": "$$NOW",
        }},
        {"$set": {"rating.average": {"$round": [{"$divide": [weighted, "$rating.count"]}, 2]}}},
    ])


def decimal(value: float) -> Decimal128:
    return Decimal128(f"{value:.2f}")
