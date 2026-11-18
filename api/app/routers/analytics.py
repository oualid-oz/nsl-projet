"""Lot 3 — Événements, analytics et commandes (Cassandra, + Neo4j)."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..services import analytics, catalogue, events, orders, sessions
from ..services.sessions import current_session, require_customer
from ..utils import utcnow

router = APIRouter(tags=["Lot 3 — Événements, analytics et commandes (Cassandra)"])


# --- Événements -----------------------------------------------------------------------

class EventIn(BaseModel):
    type: Literal["page_view", "click", "search", "add_to_cart"]
    sku: str | None = None
    page: str | None = None
    referent: str | None = None
    recherche: str | None = None
    nb_resultats: int | None = None
    element: str | None = None
    appareil: Literal["desktop", "mobile", "tablet"] = "desktop"


@router.post("/evenements", status_code=201, summary="Trace un événement de navigation")
def post_event(body: EventIn, session: dict = Depends(current_session)):
    """Écrit l'événement brut (`events_by_hour`, partition heure × shard,
    timeuuid), incrémente les compteurs, et pour une page vue : ajoute le
    produit à `recent:{owner}` (Redis) et à `VIEWED` (Neo4j, client connecté)."""
    if body.sku and catalogue.get_product(body.sku)[0] is None:
        raise HTTPException(404, "Produit inconnu")
    if body.type == "search" and not body.recherche:
        raise HTTPException(422, "« recherche » est obligatoire pour un événement search")
    return events.track(session, body.type, sku=body.sku, page_url=body.page, referrer=body.referent,
                        search_query=body.recherche, results_count=body.nb_resultats,
                        element=body.element, device=body.appareil)


# --- Analytics ---------------------------------------------------------------------------

@router.get("/analytics/produits/{sku}/vues", summary="Vues d'un produit aujourd'hui / sur N jours")
def product_views(sku: str, jours: int = Query(7, ge=1, le=365)):
    """Table `product_views_by_day` : une partition par produit, une ligne par jour."""
    if catalogue.get_product(sku)[0] is None:
        raise HTTPException(404, "Produit inconnu")
    return analytics.product_views(sku, jours)


@router.get("/analytics/top-semaine", summary="Top des produits vus de la semaine (pré-calculé)")
def weekly_top(semaine: str | None = Query(None, pattern=r"^\d{4}-W\d{2}$", description="ex. 2026-W47"),
               categorie: str = Query("all", description="'all' ou un id de catégorie du lot 1"),
               limite: int = Query(10, ge=1, le=100)):
    week = semaine or analytics.iso_week(utcnow().date())
    rows = analytics.weekly_top(week, categorie, limite)
    return {"semaine": week, "categorie": categorie, "classement": rows,
            "note": None if rows else "Aucun classement : lancer POST /analytics/jobs/top-semaine"}


@router.post("/analytics/jobs/top-semaine", summary="Job : recalcule le top de la semaine")
def run_weekly_top(semaine: str | None = Query(None, pattern=r"^\d{4}-W\d{2}$")):
    return analytics.compute_weekly_top(semaine)


@router.get("/analytics/jour", summary="Statistiques globales d'une journée")
def daily_stats(date: dt.date | None = None):
    return analytics.site_stats(date or utcnow().date())


@router.get("/analytics/evenements", summary="Événements bruts d'une heure (16 shards en parallèle)")
def raw_events(heure: dt.datetime | None = Query(None, description="ISO 8601, UTC ; défaut : heure courante"),
               limite: int = Query(20, ge=1, le=500)):
    hour = heure or utcnow()
    if hour.tzinfo is None:
        hour = hour.replace(tzinfo=dt.timezone.utc)
    bucket = events.bucket_hour(hour.astimezone(dt.timezone.utc))
    return {"bucket_hour": bucket.isoformat(), "evenements": analytics.raw_events(bucket, limite)}


# --- Commandes -----------------------------------------------------------------------------

class Address(BaseModel):
    recipient: str
    street: str
    postal_code: str
    city: str
    country: str = "FR"


class OrderIn(BaseModel):
    adresse: Address | None = None
    paiement: Literal["carte_bancaire", "paypal", "virement", "paiement_4x"] = "carte_bancaire"


@router.post("/commandes", status_code=201, summary="Passe la commande du panier")
def place_order(body: OrderIn | None = None, session: dict = Depends(current_session)):
    """Panier Redis → réservation du stock MongoDB (décrément conditionnel,
    compensé en cas d'échec) → Cassandra (`orders_by_customer` +
    `orders_by_id`, BATCH LOGGED) → Neo4j (`BOUGHT`) → panier vidé."""
    customer_id = require_customer(session)
    body = body or OrderIn()
    order = orders.place_order(customer_id, sessions.cart_items(session["cart_owner"]),
                               body.adresse.model_dump() if body.adresse else None, body.paiement)
    sessions.cart_clear(session["cart_owner"])
    return order


@router.get("/commandes", summary="Mes commandes (client connecté)")
def my_orders(avant: dt.datetime | None = None, limite: int = Query(20, ge=1, le=100),
              session: dict = Depends(current_session)):
    return orders.orders_of_customer(require_customer(session), avant, limite)


@router.get("/clients/{customer_id}/commandes", summary="Historique de commandes d'un client (back-office)")
def customer_orders(customer_id: str, avant: dt.datetime | None = None, limite: int = Query(20, ge=1, le=100)):
    """Une partition `orders_by_customer`, triée par date décroissante.
    Pagination : `avant=<order_date de la dernière commande affichée>`."""
    return orders.orders_of_customer(customer_id, avant, limite)


@router.get("/commandes/{order_id}", summary="Détail d'une commande")
def get_order(order_id: str):
    order = orders.get_order(order_id)
    if order is None:
        raise HTTPException(404, "Commande inconnue")
    return order


class StatusIn(BaseModel):
    statut: Literal["payee", "preparation", "expediee", "livree", "annulee"]
    transporteur: str | None = None
    suivi: str | None = Field(None, max_length=40)


@router.patch("/commandes/{order_id}/statut", summary="Changement de statut (les 2 tables, BATCH)")
def update_status(order_id: str, body: StatusIn):
    return orders.update_status(order_id, body.statut, body.transporteur, body.suivi)
