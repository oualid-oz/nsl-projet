"""Lot 2 — Sessions et paniers (Redis)."""
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from .. import config
from ..db import rds
from ..services import catalogue, events, sessions
from ..services.sessions import current_session

router = APIRouter(tags=["Lot 2 — Sessions et panier (Redis)"])

CUSTOMER_PATTERN = r"^user:[a-z0-9_]{1,40}$"


def _product_or_404(sku: str) -> dict:
    product, _ = catalogue.get_product(sku)
    if product is None:
        raise HTTPException(404, f"Produit inconnu : {sku}")
    return product


def _max_qty(sku: str) -> int:
    return catalogue.max_qty_for(_product_or_404(sku))


def _set_cookie(response: Response, sid: str) -> None:
    response.headers["X-Session-Id"] = sid
    response.set_cookie("sid", sid, max_age=config.SESSION_TTL, httponly=True, samesite="lax")


# --- Sessions -----------------------------------------------------------------------

@router.post("/sessions", status_code=201, summary="Nouvelle session anonyme")
def new_session(request: Request, response: Response):
    """Crée `sess:{sid}` (HASH, TTL 30 min). Le sid est renvoyé dans le corps,
    l'en-tête `X-Session-Id` et un cookie HttpOnly. Partagée par tous les
    serveurs web : aucun état n'est gardé dans l'API."""
    sid = sessions.create_session(request.client.host if request.client else "",
                                  request.headers.get("user-agent", ""))
    _set_cookie(response, sid)
    return {"sid": sid, "ttl": config.SESSION_TTL, "cle": sessions.sess_key(sid)}


@router.get("/sessions/moi", summary="Contenu de la session (TTL relancé)")
def my_session(session: dict = Depends(current_session)):
    session = dict(session)
    session["ttl_restant"] = rds().ttl(sessions.sess_key(session["sid"]))
    return session


class LoginIn(BaseModel):
    customer_id: str = Field(pattern=CUSTOMER_PATTERN, examples=["user:42"])


@router.post("/sessions/connexion", summary="Connexion + fusion du panier anonyme")
def login(body: LoginIn, response: Response, session: dict = Depends(current_session)):
    """Prototype : pas de mot de passe. Nouveau sid (anti-fixation de session),
    fusion ligne à ligne du panier `cart:{anon:<sid>}` dans `cart:{user:<id>}`
    via le script Lua (plafonds respectés), puis suppression du panier anonyme."""
    result = sessions.login(session, body.customer_id, _max_qty)
    _set_cookie(response, result["sid"])
    return result


@router.post("/sessions/deconnexion", summary="Déconnexion (le panier client est conservé)")
def logout(response: Response, session: dict = Depends(current_session)):
    sessions.destroy_session(session)
    response.delete_cookie("sid")
    return {"sid": session["sid"], "session": "supprimée",
            "panier_conserve": bool(session.get("user_id"))}


# --- Panier ---------------------------------------------------------------------------

@router.get("/panier", summary="Panier enrichi (fiches lues dans le cache)")
def get_cart(session: dict = Depends(current_session)):
    owner = session["cart_owner"]
    lines, total = [], 0.0
    for sku, qty in sessions.cart_items(owner).items():
        product, hit = catalogue.get_product(sku)
        if product is None:
            continue
        price = product["price"]["amount"]
        lines.append({"sku": sku, "nom": product["name"], "prix_unitaire": price, "quantite": qty,
                      "total_ligne": round(price * qty, 2), "stock": product["stock"]["status"],
                      "cache": "HIT" if hit else "MISS"})
        total += price * qty
    return {"proprietaire": owner, "cle": sessions.cart_key(owner),
            "ttl_restant": rds().ttl(sessions.cart_key(owner)),
            "lignes": lines, "nb_articles": sum(l["quantite"] for l in lines), "total": round(total, 2)}


class CartAdd(BaseModel):
    sku: str
    quantite: int = Field(1, ge=1, le=1000)


@router.post("/panier/articles", summary="Ajout atomique (script Lua cart_add.lua)")
def add_to_cart(body: CartAdd, session: dict = Depends(current_session)):
    """Lecture + plafond + écriture + EXPIRE dans un seul script Lua atomique.
    Plafond : 10 par article, 5 pour un processeur, 3 pour une carte graphique.
    L'ajout est aussi tracé comme événement `add_to_cart` (lot 3)."""
    product = _product_or_404(body.sku)
    if product["stock"]["status"] == "rupture":
        raise HTTPException(409, f"Produit en rupture de stock : {body.sku}")
    result = sessions.cart_add(session["cart_owner"], body.sku, body.quantite, catalogue.max_qty_for(product))
    result["plafond"] = catalogue.max_qty_for(product)
    events.track(session, "add_to_cart", sku=body.sku, element="bouton-ajout-panier")
    return result


class CartSet(BaseModel):
    quantite: int = Field(ge=0, le=1000)


@router.put("/panier/articles/{sku}", summary="Quantité absolue (0 = suppression)")
def set_cart_line(sku: str, body: CartSet, session: dict = Depends(current_session)):
    qty = sessions.cart_set(session["cart_owner"], sku, body.quantite, _max_qty(sku))
    return {"sku": sku, "quantite": qty}


@router.delete("/panier/articles/{sku}", summary="Suppression d'un article")
def delete_cart_line(sku: str, session: dict = Depends(current_session)):
    sessions.cart_set(session["cart_owner"], sku, 0, config.MAX_QTY_DEFAULT)
    return {"sku": sku, "supprime": True}


@router.get("/historique", summary="Produits consultés récemment (LIST Redis)")
def recently_viewed(session: dict = Depends(current_session)):
    out = []
    for sku in sessions.recent(session["cart_owner"]):
        product, _ = catalogue.get_product(sku)
        if product:
            out.append({"sku": sku, "nom": product["name"], "prix": product["price"]["amount"]})
    return {"proprietaire": session["cart_owner"], "produits": out}
