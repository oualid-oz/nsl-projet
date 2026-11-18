"""Refonte LDLC — prototype d'API sur les 4 bases NoSQL.

    Lot 1  /produits, /categories              MongoDB (+ cache Redis)
    Lot 2  /sessions, /panier, /historique     Redis
    Lot 3  /evenements, /analytics, /commandes Cassandra (+ Neo4j)
    Lot 4  /recommandations                    Neo4j
"""
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse, RedirectResponse

from . import db
from .routers import analytics, catalogue, panier, recommandations

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s : %(message)s")


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.connect_all()
    yield
    db.close_all()


app = FastAPI(
    title="LDLC — Architecture de données NoSQL",
    description="Prototype : un router par lot (MongoDB, Redis, Cassandra, Neo4j).",
    version="1.0.0",
    lifespan=lifespan,
)

app.include_router(catalogue.router)
app.include_router(panier.router)
app.include_router(analytics.router)
app.include_router(recommandations.router)


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/docs")


@app.get("/sante", tags=["Supervision"], summary="État des 4 bases")
def health():
    status = db.ping_all()
    ok = all(v == "ok" for v in status.values())
    return JSONResponse({"statut": "ok" if ok else "degrade", "bases": status}, status_code=200 if ok else 503)
