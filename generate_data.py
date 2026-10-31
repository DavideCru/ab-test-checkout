"""
Synthetic A/B test dataset: an e-commerce app tests a redesigned checkout flow.

Produces 5 relational tables (Parquet, ready for BigQuery upload):
    users, assignments, sessions, events, orders

The data contains a 28-day pre-period (usable for CUPED) and a 28-day experiment.
Ground-truth effects injected on purpose are documented in GROUND_TRUTH below,
so the analysis can be validated against them.
"""
from pathlib import Path

import numpy as np
import pandas as pd

SEED = 2027
N_USERS = 100_000
PRE_START = pd.Timestamp("2026-08-04")
PRE_DAYS, EXP_DAYS = 28, 28
EXP_START = PRE_START + pd.Timedelta(days=PRE_DAYS)  # 2026-09-01
TOTAL_DAYS = PRE_DAYS + EXP_DAYS
EXPERIMENT_ID = "checkout_v2"
OUT = Path("data")

GROUND_TRUTH = {
    # relative lift on P(purchase | checkout started), by platform
    "lift_by_platform": {"ios": 0.07, "android": 0.07, "web": 0.01},
    # extra lift in the first days after exposure, decays with tau = 4 days
    "novelty_lift": 0.15,
    "novelty_tau_days": 4,
    # average order value in treatment (multiplicative)
    "aov_multiplier": 0.99,
    # logging bug: android treatment users first exposed on experiment
    # days 8-10 lose their assignment record with this probability
    "bug_days": (7, 9),  # 0-indexed experiment days
    "bug_drop_prob": 0.40,
}

rng = np.random.default_rng(SEED)


def sigmoid(x):
    return 1 / (1 + np.exp(-x))


def logit(p):
    return np.log(p / (1 - p))


# ---------------------------------------------------------------- users
platforms = np.array(["ios", "android", "web"])
countries = np.array(["IE", "GB", "DE", "IT", "ES", "NO"])
plat = rng.choice(platforms, N_USERS, p=[0.35, 0.35, 0.30])
country = rng.choice(countries, N_USERS, p=[0.15, 0.25, 0.20, 0.15, 0.15, 0.10])

existing = rng.random(N_USERS) < 0.8
signup_day = np.where(
    existing,
    -rng.integers(1, 720, N_USERS),          # signed up before the pre-period
    rng.integers(0, TOTAL_DAYS, N_USERS),    # signs up during the window
)
signup_ts = PRE_START + pd.to_timedelta(signup_day, "D") + pd.to_timedelta(
    rng.integers(0, 86_400, N_USERS), "s"
)

plat_activity = pd.Series({"ios": 1.1, "android": 1.0, "web": 0.8})
activity = rng.gamma(1.2, 0.22, N_USERS) * plat_activity[plat].to_numpy()
intent = rng.normal(0, 0.5, N_USERS)                     # latent purchase intent
variant = np.where(rng.random(N_USERS) < 0.5, "treatment", "control")

users = pd.DataFrame({
    "user_id": np.arange(1, N_USERS + 1),
    "signup_ts": signup_ts,
    "platform": plat,
    "country": country,
})

# ---------------------------------------------------------------- sessions
start_day = np.maximum(signup_day, 0)
n_days = TOTAL_DAYS - start_day
n_sess = rng.poisson(activity * n_days)

u_idx = np.repeat(np.arange(N_USERS), n_sess)
day = start_day[u_idx] + np.floor(rng.random(u_idx.size) * n_days[u_idx]).astype(int)
sec = rng.integers(0, 86_400, u_idx.size)
# a session on the signup day must start after signup
signup_sec = (signup_ts - signup_ts.normalize()).total_seconds().to_numpy().astype(int)
same_day = day == signup_day[u_idx]
sec = np.where(same_day, np.maximum(sec, signup_sec[u_idx]), sec)

sess = pd.DataFrame({"u": u_idx, "day": day, "sec": sec}).sort_values(["u", "day", "sec"])
sess["session_id"] = np.arange(1, len(sess) + 1)
sess["session_ts"] = PRE_START + pd.to_timedelta(sess["day"], "D") + pd.to_timedelta(sess["sec"], "s")
sess["in_exp"] = sess["day"] >= PRE_DAYS

# exposure = first session during the experiment window
expo_day = sess[sess["in_exp"]].groupby("u")["day"].min()
expo_ts = sess[sess["in_exp"]].groupby("u")["session_ts"].min()
sess["expo_day"] = sess["u"].map(expo_day)

# ---------------------------------------------------------------- funnel
u = sess["u"].to_numpy()
treated = (variant[u] == "treatment") & sess["in_exp"].to_numpy()
days_since = (sess["day"] - sess["expo_day"]).fillna(0).to_numpy()

base = {"view": 0.70, "cart": 0.25, "checkout": 0.55, "purchase": 0.45}
weights = {"view": 0.3, "cart": 0.8, "checkout": 0.6, "purchase": 0.6}
probs = {k: sigmoid(logit(p) + weights[k] * intent[u]) for k, p in base.items()}

lift = pd.Series(GROUND_TRUTH["lift_by_platform"])[plat[u]].to_numpy()
novelty = GROUND_TRUTH["novelty_lift"] * np.exp(-days_since / GROUND_TRUTH["novelty_tau_days"])
probs["purchase"] = np.where(
    treated, np.minimum(probs["purchase"] * (1 + lift + novelty), 0.99), probs["purchase"]
)

steps = ["view", "cart", "checkout", "purchase"]
depth = np.zeros(len(sess), dtype=int)
alive = np.ones(len(sess), dtype=bool)
for s in steps:
    alive &= rng.random(len(sess)) < probs[s]
    depth += alive
sess["depth"] = depth

sessions = pd.DataFrame({
    "session_id": sess["session_id"],
    "user_id": sess["u"] + 1,
    "session_start_ts": sess["session_ts"],
    "platform": plat[u],
})

# ---------------------------------------------------------------- events (long format)
event_names = np.array(["session_start", "product_view", "add_to_cart", "checkout_start", "purchase"])
n_ev = depth + 1
ev_sess = np.repeat(np.arange(len(sess)), n_ev)
step_idx = np.arange(ev_sess.size) - np.repeat(np.cumsum(n_ev) - n_ev, n_ev)
gap = np.where(step_idx == 0, 0, rng.integers(10, 240, ev_sess.size))
offset = pd.Series(gap).groupby(ev_sess).cumsum().to_numpy()

events = pd.DataFrame({
    "event_id": np.arange(1, ev_sess.size + 1),
    "session_id": sess["session_id"].to_numpy()[ev_sess],
    "user_id": u[ev_sess] + 1,
    "event_name": event_names[step_idx],
    "event_ts": sess["session_ts"].to_numpy()[ev_sess] + pd.to_timedelta(offset, "s").to_numpy(),
})

# ---------------------------------------------------------------- orders
buy = sess[sess["depth"] == 4]
bu = buy["u"].to_numpy()
country_aov = pd.Series({"IE": 1.0, "GB": 1.05, "DE": 1.0, "IT": 0.9, "ES": 0.85, "NO": 1.3})
revenue = rng.lognormal(3.6, 0.6, len(buy)) * country_aov[country[bu]].to_numpy()
bt = (variant[bu] == "treatment") & buy["in_exp"].to_numpy()
revenue = np.where(bt, revenue * GROUND_TRUTH["aov_multiplier"], revenue)

purchase_ts = events.loc[events["event_name"] == "purchase"].set_index("session_id")["event_ts"]
orders = pd.DataFrame({
    "order_id": np.arange(1, len(buy) + 1),
    "user_id": bu + 1,
    "session_id": buy["session_id"].to_numpy(),
    "order_ts": purchase_ts.loc[buy["session_id"]].to_numpy(),
    "revenue_eur": np.round(revenue, 2),
})

# ---------------------------------------------------------------- assignments (with logging bug)
eu = expo_day.index.to_numpy()
assignments = pd.DataFrame({
    "user_id": eu + 1,
    "experiment_id": EXPERIMENT_ID,
    "variant": variant[eu],
    "assigned_ts": expo_ts.loc[eu].to_numpy(),
})
exp_day = expo_day.to_numpy() - PRE_DAYS
lo, hi = GROUND_TRUTH["bug_days"]
hit = (
    (variant[eu] == "treatment") & (plat[eu] == "android")
    & (exp_day >= lo) & (exp_day <= hi)
    & (rng.random(eu.size) < GROUND_TRUTH["bug_drop_prob"])
)
assignments = assignments[~hit].reset_index(drop=True)

# ---------------------------------------------------------------- write
OUT.mkdir(exist_ok=True)
try:
    import pyarrow  # noqa: F401
    FMT = "parquet"
except ImportError:  # fallback: gzipped CSV, also accepted by BigQuery
    FMT = "csv.gz"

for name, df in {"users": users, "assignments": assignments, "sessions": sessions,
                 "events": events, "orders": orders}.items():
    path = OUT / f"{name}.{FMT}"
    if FMT == "parquet":
        df.to_parquet(path, index=False)
    else:
        df.to_csv(path, index=False, compression="gzip", date_format="%Y-%m-%d %H:%M:%S")
    print(f"{name:12s} {len(df):>10,d} rows -> {path}")
