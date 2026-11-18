"""Lot 2 — Sessions, paniers et historique de consultation (Redis).

Mêmes clés que commands.redis :
    sess:{sid}               HASH   TTL glissant 30 min
    user:sessions:{user:ID}  SET
    cart:{owner}             HASH   sku -> quantité
    recent:{owner}           LIST
owner = « user:<id> » (client connecté) ou « anon:<sid> » (visiteur).
"""
import secrets
import time
from functools import lru_cache
from pathlib import Path

from fastapi import Header, HTTPException, Request
from redis.exceptions import ResponseError

from .. import config
from ..db import rds


def sess_key(sid: str) -> str:
    return f"sess:{{{sid}}}"


def cart_key(owner: str) -> str:
    return f"cart:{{{owner}}}"


def recent_key(owner: str) -> str:
    return f"recent:{{{owner}}}"


def user_sessions_key(customer_id: str) -> str:
    return f"user:sessions:{{{customer_id}}}"


def cart_ttl(owner: str) -> int:
    return config.CART_TTL_USER if owner.startswith("user:") else config.CART_TTL_ANON


@lru_cache
def _cart_script():
    """Script Lua du lot 2, chargé une fois (EVALSHA ensuite, avec repli
    automatique sur EVAL si Redis a redémarré)."""
    return rds().register_script(Path(config.CART_LUA_PATH).read_text(encoding="utf-8"))


# --- Sessions -------------------------------------------------------------------

def create_session(ip: str = "", user_agent: str = "", customer_id: str = "") -> str:
    sid = secrets.token_hex(16)              # 128 bits aléatoires
    now = int(time.time())
    owner = customer_id or f"anon:{sid}"
    r = rds()
    pipe = r.pipeline(transaction=False)     # même slot : {sid}
    pipe.hset(sess_key(sid), mapping={
        "created_at": now, "last_seen": now, "user_id": customer_id,
        "cart_owner": owner, "ip": ip, "user_agent": user_agent[:200],
        "csrf_token": secrets.token_hex(8), "lang": "fr",
    })
    pipe.expire(sess_key(sid), config.SESSION_TTL)
    pipe.execute()
    if customer_id:
        r.sadd(user_sessions_key(customer_id), sid)
        r.expire(user_sessions_key(customer_id), config.CART_TTL_USER)
    return sid


def current_session(request: Request, x_session_id: str | None = Header(default=None)) -> dict:
    """Dépendance FastAPI : session obligatoire (en-tête X-Session-Id ou
    cookie sid), avec TTL glissant relancé à chaque requête."""
    sid = x_session_id or request.cookies.get("sid")
    if not sid:
        raise HTTPException(401, "Session manquante : créez-en une avec POST /sessions")
    r = rds()
    data = r.hgetall(sess_key(sid))
    if not data:
        raise HTTPException(401, "Session inconnue ou expirée")
    pipe = r.pipeline(transaction=False)
    pipe.hset(sess_key(sid), "last_seen", int(time.time()))
    pipe.expire(sess_key(sid), config.SESSION_TTL)
    pipe.execute()
    data["sid"] = sid
    data["ttl"] = config.SESSION_TTL
    return data


def require_customer(session: dict) -> str:
    if not session.get("user_id"):
        raise HTTPException(401, "Connexion requise : POST /sessions/connexion")
    return session["user_id"]


def destroy_session(session: dict) -> None:
    r = rds()
    r.delete(sess_key(session["sid"]))
    if session.get("user_id"):
        r.srem(user_sessions_key(session["user_id"]), session["sid"])


# --- Panier ---------------------------------------------------------------------

def cart_add(owner: str, sku: str, qty: int, max_qty: int) -> dict:
    """Ajout atomique via cart_add.lua : plafond + EXPIRE dans le même script."""
    try:
        new_qty, capped, lines = _cart_script()(
            keys=[cart_key(owner)],
            args=[sku, qty, max_qty, cart_ttl(owner), config.MAX_CART_LINES],
        )
    except ResponseError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"sku": sku, "quantite": int(new_qty), "plafonnee": bool(capped), "lignes": int(lines)}


def cart_set(owner: str, sku: str, qty: int, max_qty: int) -> int:
    """Quantité absolue (page panier). 0 = suppression."""
    key = cart_key(owner)
    pipe = rds().pipeline()                  # MULTI/EXEC sur une seule clé
    qty = min(qty, max_qty)
    if qty <= 0:
        pipe.hdel(key, sku)
    else:
        pipe.hset(key, sku, qty)
    pipe.expire(key, cart_ttl(owner))
    pipe.execute()
    return max(qty, 0)


def cart_items(owner: str) -> dict[str, int]:
    return {sku: int(q) for sku, q in rds().hgetall(cart_key(owner)).items()}


def cart_clear(owner: str) -> None:
    rds().delete(cart_key(owner))


# --- Produits consultés récemment ---------------------------------------------------

def push_recent(owner: str, sku: str) -> None:
    key = recent_key(owner)
    pipe = rds().pipeline()                  # MULTI/EXEC : LREM + LPUSH + LTRIM + EXPIRE
    pipe.lrem(key, 0, sku)
    pipe.lpush(key, sku)
    pipe.ltrim(key, 0, config.RECENT_MAX - 1)
    pipe.expire(key, config.RECENT_TTL)
    pipe.execute()


def recent(owner: str, limit: int = 10) -> list[str]:
    return rds().lrange(recent_key(owner), 0, limit - 1)


# --- Connexion : nouvelle session + fusion du panier anonyme -------------------------

def login(session: dict, customer_id: str, max_qty_lookup) -> dict:
    """1) nouvelle session (nouveau sid : protection contre la fixation) ;
    2) fusion du panier anonyme dans le panier client via le script Lua
       (plafonds respectés) puis suppression du panier anonyme ;
    3) idem pour l'historique de consultation ;
    4) suppression de l'ancienne session.
    Les clés anon:… et user:… n'ont pas le même hash tag : la fusion est
    faite par l'application, ligne par ligne (cf. commands.redis)."""
    r = rds()
    old_owner = session.get("cart_owner", "")
    new_sid = create_session(session.get("ip", ""), session.get("user_agent", ""), customer_id)

    merged = []
    if old_owner and old_owner != customer_id:
        for sku, qty in cart_items(old_owner).items():
            merged.append(cart_add(customer_id, sku, qty, max_qty_lookup(sku)))
        r.delete(cart_key(old_owner))
        for sku in reversed(r.lrange(recent_key(old_owner), 0, -1)):
            push_recent(customer_id, sku)
        r.delete(recent_key(old_owner))

    destroy_session(session)
    return {"sid": new_sid, "ancien_sid": session["sid"], "client": customer_id, "panier_fusionne": merged}
