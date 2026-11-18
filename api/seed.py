"""Seed du prototype : données datées par rapport à AUJOURD'HUI.

    python seed.py            # une seule fois (marqueur dans Cassandra)
    python seed.py --force    # rejoue (les compteurs s'ADDITIONNENT)

1. Recopie dans Cassandra les commandes du graphe initial (lot 4) pour que
   l'historique de user:42 soit le même dans les deux bases.
2. Génère ~30 clients et leurs commandes sur les 180 derniers jours
   (Cassandra orders_by_customer / orders_by_id + Neo4j BOUGHT), avec des
   habitudes d'achat réalistes (config AMD haut de gamme, config Intel...).
3. Génère 14 jours de compteurs de vues (pré-agrégés comme le ferait le
   consumer d'ingestion) et quelques centaines d'événements bruts.
4. Calcule le top de la semaine courante et de la précédente.
5. Lance le job BOUGHT_WITH.
"""
import datetime as dt
import random
import sys
import time

from app import db
from app.services import analytics, events, graph, orders

RNG = random.Random(2026)
NOW = dt.datetime.now(dt.timezone.utc)
TODAY = NOW.date()

# Vues quotidiennes moyennes par produit (popularité relative)
POPULARITY = {
    "GPU-ASUS-RTX4070S-12": 3000, "CPU-AMD-R7-7800X3D": 2100, "RAM-CORSAIR-DDR5-32-6000": 1400,
    "CPU-AMD-R5-7600X": 1250, "GPU-SAPPHIRE-RX7800XT-16": 1100, "CM-ASUS-B650A-WIFI": 950,
    "SOU-LOGI-G502X": 820, "BOI-FRACTAL-NORTH": 700, "BOI-CORSAIR-4000D": 650,
    "CPU-INTEL-I5-14600K": 600, "RAM-GSKILL-DDR5-32-6400": 520, "CM-MSI-B760-TOMAHAWK": 450,
    "CM-MSI-B650MA-WIFI": 400, "LOG-MS-WIN11-FAM": 350,
}
SEARCHES = ["rtx 4070", "7800x3d", "carte mere am5", "ddr5 32go", "boitier atx", "ryzen 7",
            "souris gamer", "windows 11", "b650", "radeon 7800 xt"]
PSEUDOS = ["Alex_R", "Benoit.M", "Camille_T", "David_P", "Elise.B", "Fabien_K", "Gaelle.D", "Hamza_S",
           "Ilona.V", "Jordan_L", "Karim.B", "Laura_G", "Mehdi.A", "Nadia_F", "Olivier.C", "Pauline_H",
           "Quentin.M", "Rachid_E", "Salome.R", "Theo_J", "Ugo.P", "Valentin_N", "Wassim.T", "Xavier_D",
           "Yasmine.K", "Zoe_L", "Adrien.F", "Blandine_S", "Cyril.O", "Dounia_M"]
CITIES = ["Paris", "Lyon", "Marseille", "Toulouse", "Nantes", "Lille", "Bordeaux", "Strasbourg",
          "Rennes", "Grenoble", "Montpellier", "Nice", "Dijon", "Limonest"]


def pick(p: float) -> bool:
    return RNG.random() < p


# Habitudes d'achat : (poids, fonction qui renvoie la liste des SKU)
def build_amd_high():
    skus = ["CPU-AMD-R7-7800X3D", "CM-ASUS-B650A-WIFI",
            "RAM-CORSAIR-DDR5-32-6000" if pick(0.75) else "RAM-GSKILL-DDR5-32-6400"]
    if pick(0.85):
        skus.append("GPU-ASUS-RTX4070S-12" if pick(0.65) else "GPU-SAPPHIRE-RX7800XT-16")
    skus.append("BOI-FRACTAL-NORTH" if pick(0.55) else "BOI-CORSAIR-4000D")
    if pick(0.35):
        skus.append("LOG-MS-WIN11-FAM")
    return skus


def build_amd_budget():
    skus = ["CPU-AMD-R5-7600X", "CM-MSI-B650MA-WIFI" if pick(0.5) else "CM-ASUS-B650A-WIFI",
            "RAM-CORSAIR-DDR5-32-6000" if pick(0.6) else "RAM-GSKILL-DDR5-32-6400"]
    if pick(0.6):
        skus.append("GPU-SAPPHIRE-RX7800XT-16")
    if pick(0.7):
        skus.append("BOI-CORSAIR-4000D")
    if pick(0.3):
        skus.append("SOU-LOGI-G502X")
    return skus


def build_intel():
    skus = ["CPU-INTEL-I5-14600K", "CM-MSI-B760-TOMAHAWK",
            "RAM-GSKILL-DDR5-32-6400" if pick(0.5) else "RAM-CORSAIR-DDR5-32-6000"]
    if pick(0.6):
        skus.append("LOG-MS-WIN11-FAM")
    if pick(0.5):
        skus.append("BOI-CORSAIR-4000D")
    if pick(0.4):
        skus.append("GPU-ASUS-RTX4070S-12")
    return skus


def upgrade_gpu():
    skus = ["GPU-ASUS-RTX4070S-12" if pick(0.6) else "GPU-SAPPHIRE-RX7800XT-16"]
    if pick(0.2):
        skus.append("SOU-LOGI-G502X")
    return skus


def accessories():
    skus = ["SOU-LOGI-G502X"]
    if pick(0.3):
        skus.append("LOG-MS-WIN11-FAM")
    return skus


HABITS = [(0.30, build_amd_high), (0.25, build_amd_budget), (0.15, build_intel),
          (0.15, upgrade_gpu), (0.15, accessories)]


def status_for(at: dt.datetime) -> tuple[str, str | None, str | None]:
    age = (NOW - at).total_seconds() / 86400
    if age < 1:
        return "preparation", None, None
    carrier = RNG.choice(["Colissimo", "Chronopost", "DPD"])
    tracking = f"{RNG.randint(10**11, 10**12 - 1)}FR"
    return ("expediee" if age < 3 else "livree"), carrier, tracking


def step(msg: str) -> None:
    print(f"[seed] {msg}", flush=True)


def already_seeded() -> bool:
    s = db.cassandra()
    s.execute("CREATE TABLE IF NOT EXISTS seed_runs (id text PRIMARY KEY, run_at timestamp)")
    return s.execute("SELECT id FROM seed_runs WHERE id = 'v1'").one() is not None


def sync_graph_orders() -> int:
    """Commandes du jeu de données Neo4j (lot 4) → Cassandra."""
    rows = db.cypher("""
        MATCH (c:Customer)-[b:BOUGHT]->(p:Product)
        RETURN c.id AS cid, b.order_id AS oid, b.date AS date,
               collect({sku: p.sku, qty: coalesce(b.quantity, 1)}) AS items
    """)
    for r in rows:
        day = r["date"].to_native()
        at = dt.datetime.combine(day, dt.time(10, RNG.randint(0, 59)), dt.timezone.utc)
        lines = orders.build_lines({i["sku"]: i["qty"] for i in r["items"]})
        status, carrier, tracking = status_for(at)
        orders.write_order(r["cid"], r["oid"], at, lines, status, carrier=carrier, tracking=tracking)
    return len(rows)


def synthetic_customers() -> list[str]:
    ids = []
    for i, pseudo in enumerate(PSEUDOS, start=1):
        cid = f"user:c{i:03d}"
        db.cypher("MERGE (c:Customer {id: $cid}) SET c.pseudo = $pseudo, c.city = $city",
                  cid=cid, pseudo=pseudo, city=RNG.choice(CITIES))
        ids.append(cid)
    # Réseau d'amis : ~45 liens aléatoires + 2 amis supplémentaires pour user:42
    pairs = set()
    while len(pairs) < 45:
        a, b = RNG.sample(ids, 2)
        pairs.add(tuple(sorted((a, b))))
    pairs |= {("user:42", ids[0]), ("user:42", ids[1])}
    db.cypher("""
        UNWIND $pairs AS pr
        MATCH (a:Customer {id: pr[0]}), (b:Customer {id: pr[1]})
        MERGE (a)-[:FRIEND_OF]->(b)
    """, pairs=[list(p) for p in pairs])
    return ids


def synthetic_orders(customers: list[str]) -> int:
    weights = [w for w, _ in HABITS]
    builders = [f for _, f in HABITS]
    n = 0
    for cid in customers:
        for _ in range(RNG.choice([1, 1, 2, 2, 3])):
            skus = RNG.choices(builders, weights)[0]()
            at = NOW - dt.timedelta(days=RNG.randint(0, 180), hours=RNG.randint(0, 23), minutes=RNG.randint(0, 59))
            at = min(at, NOW)
            status, carrier, tracking = status_for(at)
            lines = orders.build_lines({s: 1 for s in dict.fromkeys(skus)})
            orders.write_order(cid, orders.new_order_id(at), at, lines, status,
                               payment=RNG.choice(["carte_bancaire", "paypal", "paiement_4x"]),
                               carrier=carrier, tracking=tracking)
            n += 1
        # quelques consultations récentes (relation VIEWED)
        for sku in RNG.sample(list(POPULARITY), 3):
            db.cypher("""
                MATCH (c:Customer {id: $cid}), (p:Product {sku: $sku})
                MERGE (c)-[v:VIEWED]->(p) SET v.count = $n, v.last_seen = date($d)
            """, cid=cid, sku=sku, n=RNG.randint(1, 6), d=(TODAY - dt.timedelta(days=RNG.randint(0, 10))).isoformat())
    return n


def counters(days: int = 14) -> int:
    """Compteurs quotidiens, pré-agrégés (n > 1), comme le consumer d'ingestion."""
    writes = 0
    for d in range(days):
        day = TODAY - dt.timedelta(days=d)
        factor = 1.25 if day.weekday() >= 5 else 1.0
        if d == 0:                                    # journée en cours
            factor *= max(NOW.hour + NOW.minute / 60, 1) / 24
        for sku, base in POPULARITY.items():
            views = int(base * factor * RNG.uniform(0.8, 1.2))
            events.increment_counters(day, "page_view", sku, views)
            events.increment_counters(day, "click", sku, int(views * RNG.uniform(0.09, 0.14)))
            events.increment_counters(day, "add_to_cart", sku, int(views * RNG.uniform(0.03, 0.06)))
            writes += 3
        events.increment_counters(day, "search", None, int(4000 * factor * RNG.uniform(0.8, 1.2)))
    return writes


def raw_events(per_day: int = 300) -> int:
    """Événements bruts pour aujourd'hui et hier (les compteurs ci-dessus
    représentent déjà leur volume : on n'incrémente pas une seconde fois)."""
    skus, weights = list(POPULARITY), list(POPULARITY.values())
    sessions = [f"{RNG.getrandbits(128):032x}" for _ in range(60)]
    n = 0
    for d in (0, 1):
        start = dt.datetime.combine(TODAY - dt.timedelta(days=d), dt.time(0), dt.timezone.utc)
        span = (NOW - start).total_seconds() if d == 0 else 86400
        for _ in range(per_day):
            at = start + dt.timedelta(seconds=RNG.uniform(0, span))
            sid = RNG.choice(sessions)
            kind = RNG.choices(["page_view", "click", "search", "add_to_cart"], [70, 15, 10, 5])[0]
            sku = None if kind == "search" else RNG.choices(skus, weights)[0]
            events.insert_raw_event(
                kind, sid, at, sku=sku,
                page_url=f"/fiche/{sku}.html" if sku else "/recherche",
                search_query=RNG.choice(SEARCHES) if kind == "search" else None,
                results_count=RNG.randint(3, 80) if kind == "search" else None,
                device=RNG.choices(["desktop", "mobile", "tablet"], [55, 40, 5])[0])
            n += 1
    return n


def main() -> None:
    force = "--force" in sys.argv
    t0 = time.time()
    db.connect_all()
    if already_seeded() and not force:
        step("Données déjà présentes (marqueur seed_runs) : rien à faire. Utiliser --force pour rejouer.")
        return

    step(f"Aujourd'hui : {TODAY.isoformat()} (semaine {analytics.iso_week(TODAY)})")
    step(f"{sync_graph_orders()} commandes du graphe initial recopiées dans Cassandra")
    customers = synthetic_customers()
    step(f"{len(customers)} clients synthétiques + réseau d'amis")
    step(f"{synthetic_orders(customers)} commandes générées (Cassandra + Neo4j)")
    step(f"{counters()} incréments de compteurs sur 14 jours")
    step(f"{raw_events()} événements bruts (aujourd'hui et hier)")
    for week in (analytics.iso_week(TODAY - dt.timedelta(days=7)), analytics.iso_week(TODAY)):
        res = analytics.compute_weekly_top(week)
        step(f"Top {res['semaine']} : {res['produits_classes']} produits classés")
    res = graph.run_bought_with_job()
    step(f"BOUGHT_WITH : {res['relations_bought_with']} relations")
    db.cassandra().execute("INSERT INTO seed_runs (id, run_at) VALUES ('v1', toTimestamp(now()))")
    step(f"Terminé en {time.time() - t0:.1f} s")
    db.close_all()


if __name__ == "__main__":
    main()
