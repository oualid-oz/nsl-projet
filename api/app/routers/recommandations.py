"""Lot 4 — Recommandations et compatibilités (Neo4j)."""
from fastapi import APIRouter, HTTPException, Query

from ..db import cypher
from ..services import graph

router = APIRouter(prefix="/recommandations", tags=["Lot 4 — Recommandations (Neo4j)"])


def _check_product(sku: str) -> None:
    if not cypher("MATCH (p:Product {sku: $sku}) RETURN p.sku AS sku", sku=sku):
        raise HTTPException(404, "Produit inconnu du graphe")


def _check_customer(cid: str) -> None:
    if not cypher("MATCH (c:Customer {id: $cid}) RETURN c.id AS id", cid=cid):
        raise HTTPException(404, "Client inconnu du graphe")


@router.get("/produits/{sku}/aussi-achetes", summary="« Les clients qui ont acheté ceci ont aussi acheté… »")
def also_bought(sku: str, categorie: str | None = Query(None, description="ex. cartes-meres"),
                limite: int = Query(5, ge=1, le=50),
                direct: bool = Query(False, description="forcer le calcul en direct (2 sauts)")):
    """Lit les relations `BOUGHT_WITH` matérialisées par le job nocturne
    (1 saut) ; à défaut, calcule en direct Produit ← Client → Produit."""
    _check_product(sku)
    return graph.also_bought(sku, categorie, limite, direct)


@router.get("/produits/{sku}/compatibles", summary="Produits compatibles (déduits par parcours)")
def compatible(sku: str):
    """Socket, MemoryType et FormFactor sont des nœuds partagés : la
    compatibilité n'est jamais saisie, elle se déduit du graphe."""
    _check_product(sku)
    return graph.compatible(sku)


@router.get("/produits/{sku}/similaires", summary="Produits similaires (score)")
def similar(sku: str, limite: int = Query(5, ge=1, le=50)):
    _check_product(sku)
    return graph.similar(sku, limite)


@router.get("/configurateur", summary="Configurateur : CPU → carte mère → RAM + boîtier (+ GPU)")
def builder(cpu: str = Query(..., examples=["CPU-AMD-R7-7800X3D"]), limite: int = Query(5, ge=1, le=20)):
    _check_product(cpu)
    builds = graph.builder(cpu, limite)
    if not builds:
        raise HTTPException(422, "Aucune configuration : le SKU est-il bien un processeur ?")
    return {"cpu": cpu, "configurations": builds}


@router.get("/clients/{customer_id}", summary="Recommandations personnalisées")
def personalized(customer_id: str, limite: int = Query(5, ge=1, le=50)):
    _check_customer(customer_id)
    return graph.personalized(customer_id, limite)


@router.get("/clients/{customer_id}/suggestions-amis", summary="Amis d'amis")
def friend_suggestions(customer_id: str, limite: int = Query(10, ge=1, le=50)):
    _check_customer(customer_id)
    return graph.friend_suggestions(customer_id, limite)


@router.get("/clients/{customer_id}/entourage", summary="Ce qu'achètent mes amis et amis d'amis")
def circle(customer_id: str, limite: int = Query(5, ge=1, le=50)):
    _check_customer(customer_id)
    return graph.circle_purchases(customer_id, limite)


@router.post("/jobs/bought-with", summary="Job nocturne : matérialise BOUGHT_WITH")
def bought_with_job(min_clients: int = Query(2, ge=1)):
    return graph.run_bought_with_job(min_clients)
