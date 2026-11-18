"""Lot 1 — Catalogue (MongoDB) avec cache Redis."""
import datetime as dt
from typing import Literal

from bson import Decimal128, ObjectId
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from pymongo.errors import DuplicateKeyError

from ..db import cypher, mongo
from ..services import catalogue
from ..services.sessions import current_session, require_customer
from ..utils import coerce, to_jsonable, utcnow

router = APIRouter(tags=["Lot 1 — Catalogue (MongoDB)"])

CARD = {"name": 1, "type": 1, "brand.name": 1, "category._id": 1, "price.amount": 1,
        "stock.status": 1, "rating.average": 1, "rating.count": 1, "rating_avg": 1}
SORTS = {"prix_asc": {"price.amount": 1}, "prix_desc": {"price.amount": -1},
         "note": {"rating.average": -1, "rating_avg": -1}}
OPERATORS = {"gte": "$gte", "lte": "$lte", "gt": "$gt", "lt": "$lt", "ne": "$ne"}
PRICE_BOUNDARIES = [0, 150, 300, 500, 1000, 100000]


def _spec_filter(raw: str):
    """specs.cores=8, specs.cores=gte:8, specs.socket=AM5 (wildcard index)."""
    if ":" in raw:
        op, _, value = raw.partition(":")
        if op in OPERATORS:
            return {OPERATORS[op]: coerce(value)}
    return coerce(raw)


@router.get("/produits", summary="Listing filtrable + facettes ($facet)")
def list_products(
    request: Request,
    categorie: str | None = Query(None, description="id de catégorie, sous-catégories incluses (category.path)"),
    marque: str | None = Query(None, description="id de marque, ex. amd"),
    type: str | None = Query(None, description="discriminant Polymorphic, ex. processeur"),
    prix_min: float | None = None,
    prix_max: float | None = None,
    en_stock: bool = False,
    q: str | None = Query(None, description="recherche plein texte (index text, français)"),
    tri: Literal["prix_asc", "prix_desc", "note", "pertinence"] = "prix_asc",
    page: int = Query(1, ge=1),
    par_page: int = Query(20, ge=1, le=100),
):
    """Filtres techniques libres : tout paramètre `specs.<champ>` est appliqué
    tel quel (ex. `specs.socket=AM5`, `specs.cores=gte:8`) et servi par
    l'index wildcard `specs.$**`."""
    match: dict = {}
    if q:
        match["$text"] = {"$search": q}
    if categorie:
        match["category.path"] = categorie
    if marque:
        match["brand._id"] = marque
    if type:
        match["type"] = type
    if prix_min is not None or prix_max is not None:
        match["price.amount"] = {}
        if prix_min is not None:
            match["price.amount"]["$gte"] = catalogue.decimal(prix_min)
        if prix_max is not None:
            match["price.amount"]["$lte"] = catalogue.decimal(prix_max)
    if en_stock:
        match["stock.quantity"] = {"$gt": 0}
    for key, value in request.query_params.multi_items():
        if key.startswith("specs."):
            match[key] = _spec_filter(value)

    if tri == "pertinence" and q:
        sort = {"score": {"$meta": "textScore"}}
    else:
        sort = SORTS.get(tri, SORTS["prix_asc"])
    projection = dict(CARD, **({"score": {"$meta": "textScore"}} if q else {}))

    pipeline = [
        {"$match": match},
        {"$facet": {
            "produits": [{"$sort": sort}, {"$skip": (page - 1) * par_page}, {"$limit": par_page},
                         {"$project": projection}],
            "total": [{"$count": "n"}],
            "marques": [{"$group": {"_id": "$brand.name", "nb": {"$sum": 1}}}, {"$sort": {"nb": -1, "_id": 1}}],
            "categories": [{"$group": {"_id": "$category._id", "nb": {"$sum": 1}}}, {"$sort": {"_id": 1}}],
            "types": [{"$group": {"_id": "$type", "nb": {"$sum": 1}}}, {"$sort": {"_id": 1}}],
            "prix": [{"$bucket": {"groupBy": "$price.amount",
                                  "boundaries": [Decimal128(str(b)) for b in PRICE_BOUNDARIES],
                                  "default": "autre", "output": {"nb": {"$sum": 1}}}}],
            "disponibilite": [{"$group": {"_id": "$stock.status", "nb": {"$sum": 1}}}],
        }},
    ]
    res = next(mongo().products.aggregate(pipeline))
    total = res["total"][0]["n"] if res["total"] else 0
    tranches = []
    for b in res["prix"]:
        if b["_id"] == "autre":
            continue
        low = float(b["_id"].to_decimal())
        high = PRICE_BOUNDARIES[PRICE_BOUNDARIES.index(int(low)) + 1]
        tranches.append({"de": low, "a": high, "nb": b["nb"]})
    return {
        "filtres": to_jsonable(match),
        "total": total, "page": page, "par_page": par_page,
        "produits": to_jsonable(res["produits"]),
        "facettes": {
            "marques": [{"valeur": f["_id"], "nb": f["nb"]} for f in res["marques"]],
            "categories": [{"valeur": f["_id"], "nb": f["nb"]} for f in res["categories"]],
            "types": [{"valeur": f["_id"], "nb": f["nb"]} for f in res["types"]],
            "prix": tranches,
            "disponibilite": [{"valeur": f["_id"], "nb": f["nb"]} for f in res["disponibilite"]],
        },
    }


@router.get("/produits/{sku}", summary="Fiche produit (cache-aside Redis)")
def get_product(sku: str, response: Response):
    """Une seule lecture MongoDB (Extended Reference, Subset, Computed),
    mise en cache dans `cache:product:<sku>`. En-tête `X-Cache: HIT|MISS`."""
    product, hit = catalogue.get_product(sku)
    if product is None:
        raise HTTPException(404, "Produit inconnu")
    response.headers["X-Cache"] = "HIT" if hit else "MISS"
    return product


class PriceUpdate(BaseModel):
    prix: float = Field(gt=0)


@router.patch("/produits/{sku}/prix", summary="Changement de prix + invalidation du cache")
def update_price(sku: str, body: PriceUpdate):
    res = mongo().products.update_one(
        {"_id": sku}, {"$set": {"price.amount": catalogue.decimal(body.prix), "updated_at": utcnow()}})
    if res.matched_count == 0:
        raise HTTPException(404, "Produit inconnu")
    catalogue.invalidate(sku)                                   # lot 2 : DEL cache:product:<sku>
    cypher("MATCH (p:Product {sku: $sku}) SET p.price = $prix", sku=sku, prix=body.prix)   # lot 4
    return {"sku": sku, "prix": body.prix, "cache": "invalidé", "graphe": "mis à jour"}


@router.get("/produits/{sku}/avis", summary="Avis au-delà des 5 embarqués (pattern Subset)")
def list_reviews(sku: str, avant: dt.datetime | None = Query(None, description="pagination par date"),
                 limite: int = Query(10, ge=1, le=50)):
    query: dict = {"product_id": sku}
    if avant:
        query["date"] = {"$lt": avant}
    rows = mongo().reviews.find(query, {"product_id": 0}).sort("date", -1).limit(limite)
    return to_jsonable(list(rows))


class ReviewIn(BaseModel):
    note: int = Field(ge=1, le=5)
    titre: str = Field(min_length=2, max_length=120)
    commentaire: str = Field(min_length=2, max_length=4000)


@router.post("/produits/{sku}/avis", status_code=201, summary="Dépôt d'un avis (Subset + Computed)")
def add_review(sku: str, body: ReviewIn, session: dict = Depends(current_session)):
    """Insertion dans `reviews`, puis mise à jour de la note et des 5 derniers
    avis embarqués. Un produit encore en schema_version 1 est migré en v2 à
    cette occasion (migration paresseuse)."""
    customer_id = require_customer(session)
    db = mongo()
    product = db.products.find_one({"_id": sku}, {"schema_version": 1})
    if product is None:
        raise HTTPException(404, "Produit inconnu")
    review = {
        "_id": ObjectId(), "product_id": sku,
        "author": {"user_id": customer_id, "pseudo": customer_id.split(":", 1)[-1]},
        "rating": body.note, "title": body.titre, "comment": body.commentaire,
        "date": utcnow(), "verified_purchase": False,
    }
    try:
        db.reviews.insert_one(review)
    except DuplicateKeyError as exc:
        raise HTTPException(409, "Vous avez déjà laissé un avis sur ce produit") from exc
    if product.get("schema_version", 1) >= 2:
        catalogue.apply_new_review(sku, review)
        mode = "incrémental (pipeline d'agrégation)"
    else:
        catalogue.rebuild_rating_and_subset(sku)
        mode = "migration v1 → v2 puis recalcul complet"
    catalogue.invalidate(sku)
    doc = db.products.find_one({"_id": sku}, {"schema_version": 1, "rating": 1, "latest_reviews.pseudo": 1})
    return {"avis": to_jsonable(review), "mise_a_jour": mode, "produit": to_jsonable(doc)}


@router.get("/categories", summary="Arbre des catégories")
def list_categories():
    return to_jsonable(list(mongo().categories.find().sort([("parent", 1), ("_id", 1)])))


@router.get("/categories/{category_id}", summary="Fil d'Ariane et sous-catégories (Array of Ancestors)")
def get_category(category_id: str):
    db = mongo()
    cat = db.categories.find_one({"_id": category_id})
    if cat is None:
        raise HTTPException(404, "Catégorie inconnue")
    return {
        "categorie": {"id": cat["_id"], "nom": cat["name"]},
        "fil_d_ariane": [a["name"] for a in cat["ancestors"]] + [cat["name"]],
        "enfants": [{"id": c["_id"], "nom": c["name"]} for c in db.categories.find({"parent": category_id})],
        "descendants": [c["_id"] for c in db.categories.find({"ancestors._id": category_id}, {"_id": 1})],
        "nb_produits": db.products.count_documents({"category.path": category_id}),
    }
