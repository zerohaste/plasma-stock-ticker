#!/usr/bin/env python3
"""Build accounts.json for the HUD Card plasmoid from a simple input file.

The widget never talks to a bank. You (or a script you trust) export balances
and transactions, and this tool turns them into the display file:

  * 30-day balance history, rebuilt backwards from the current balance
  * a 7-day forecast from recurring deposits/bills it detects in the data
  * the lowest projected balance in that window
  * retirement / HSA summaries (change, YTD contributions, medical spend)

Usage:
  hud-accounts-build.py INPUT.json [--transactions-csv tx.csv]
                        [-o ~/.local/share/controllimit-hud/accounts.json]
                        [--days 30] [--forecast-days 7] [--no-discretionary]

INPUT.json (see README "Data schema" for every field):
  {"accounts": [
     {"id": "checking-1234", "type": "checking", "name": "Everyday Checking",
      "mask": "1234", "balance": 2500.00, "available": 2400.00,
      "transactions": [{"date": "2026-11-01", "amount": -45.10,
                        "description": "Grocery Store", "pending": false}]},
     {"id": "401k-5678", "type": "retirement", "name": "Work 401(k)", "mask": "5678",
      "balance": 50000, "history": [{"d": "2026-08-01", "v": 48000}],
      "contributions": [{"date": "2026-01-15", "amount": 500}]},
     {"id": "hsa-9012", "type": "hsa", "name": "HSA", "mask": "9012", "balance": 3000,
      "contributionLimit": 4400,
      "contributions": [{"date": "2026-02-01", "amount": 200}],
      "medical": [{"date": "2026-10-03", "amount": 85.20}]}
  ]}

Optional CSV (header row): account_id,date,amount,description[,pending]
Rows are appended to the matching account's "transactions".
Amount sign: positive = money in, negative = money out.

If the output file already exists, each account's previous daily balances are
kept and today's balance is added, so a daily refresh slowly builds a real
history for accounts where you only know the current balance.
"""
import argparse
import csv
import json
import os
import re
import statistics
import sys
import tempfile
from collections import defaultdict
from datetime import date, datetime, timedelta

DEFAULT_OUT = os.path.expanduser("~/.local/share/controllimit-hud/accounts.json")
CASH_TYPES = {"checking", "savings", "cash"}
DISCRETIONARY_CAP = 500.0  # single purchases above this are treated as one-offs


def d(s):
    return datetime.strptime(str(s)[:10], "%Y-%m-%d").date()


def num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def r2(v):
    return None if v is None else round(float(v), 2)


NOISE = re.compile(
    r"\b(ach|withdrawal|deposit|debit|credit|card|purch(ase)?|pos|dc|company|entry|"
    r"payment|pmt|online|mobile|banking|recurring|bill|from|to|the|www|com|inc|llc)\b")


def merchant_key(desc):
    s = (desc or "").lower()
    s = re.sub(r"entry:.*$", "", s)          # bank ACH tails often contain names/ids
    s = re.sub(r"[^a-z ]", " ", s)
    s = NOISE.sub(" ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:24] or "other"


def label_for(desc):
    s = re.sub(r"(?i)entry:.*$", "", desc or "")
    s = re.sub(r"(?i)^(ach (withdrawal|deposit)\s*)?(company:\s*)?", "", s)
    s = re.sub(r"(?i)^(home banking |mobile banking )?(payment to|withdrawal|deposit)\s+", "", s)
    s = re.sub(r"[*#]{2,}\S*", "", s)
    s = re.sub(r"\b\w*\d\w*\b", "", s)        # drop account/reference numbers
    s = re.sub(r"\s+", " ", s).strip()
    return (s[:18] or "Recurring").strip()


def cluster_amounts(items):
    """Split one merchant's charges into clusters of similar size."""
    items = sorted(items, key=lambda t: abs(t["amount"]))
    out, cur = [], []
    for t in items:
        if cur and abs(t["amount"]) > abs(cur[-1]["amount"]) * 1.25 + 1:
            out.append(cur)
            cur = []
        cur.append(t)
    if cur:
        out.append(cur)
    return out


def detect_recurring(txs, today):
    """Return recurring series: [{label, amount, interval, next, count}]."""
    posted = [t for t in txs if not t.get("pending")]
    if not posted:
        return []
    span = (today - min(t["date"] for t in posted)).days or 1
    groups = defaultdict(list)
    for t in posted:
        if abs(t["amount"]) < 1:
            continue
        groups[(merchant_key(t["description"]), t["amount"] > 0)].append(t)
    series = []
    for (key, _inflow), items in groups.items():
        for cl in cluster_amounts(items):
            dates = sorted({t["date"] for t in cl})
            if len(dates) < 2:
                continue
            months = {(x.year, x.month) for x in dates}
            if len(months) < (3 if span >= 80 else 2):
                continue
            gaps = [(b - a).days for a, b in zip(dates, dates[1:])]
            gap = statistics.median(gaps)
            if 26 <= gap <= 35:
                interval = 30
            elif 12 <= gap <= 16:
                interval = 14
            elif 6 <= gap <= 8:
                interval = 7
            else:
                continue
            amts = [t["amount"] for t in cl]
            med = statistics.median(amts)
            mad = statistics.median([abs(a - med) for a in amts])
            if abs(med) < 1 or mad / abs(med) > 0.25:
                continue
            last = dates[-1]
            if interval == 30:
                dom = round(statistics.median([x.day for x in dates]))
                y, m = last.year, last.month + 1
                if m == 13:
                    y, m = y + 1, 1
                nxt = date(y, m, min(dom, 28 if m == 2 else 30))
            else:
                nxt = last + timedelta(days=interval)
            if nxt <= today:
                if (today - nxt).days <= 5:      # a little late: expect it soon
                    # ...unless a similar-sized charge already posted (merchant renamed)
                    if any(t["amount"] * med > 0 and abs(t["amount"] - med) <= abs(med) * 0.10
                           and t["date"] >= nxt - timedelta(days=5) for t in posted):
                        continue
                    nxt = today + timedelta(days=1)
                else:                              # looks stopped
                    continue
            desc = max(cl, key=lambda t: t["date"])["description"]
            series.append({"label": label_for(desc), "key": key, "amount": r2(med),
                           "interval": interval, "next": nxt, "count": len(cl),
                           "ids": {id(t) for t in cl}})
    return series


def build_cash(acc, today, days, fdays, use_discretionary):
    txs = acc["transactions"]
    bal = num(acc.get("balance"), 0.0)
    posted = [t for t in txs if not t.get("pending")]
    pending_sum = sum(t["amount"] for t in txs if t.get("pending"))
    hist = []
    for i in range(days, -1, -1):
        day = today - timedelta(days=i)
        later = sum(t["amount"] for t in posted if t["date"] > day)
        hist.append({"d": day.isoformat(), "v": r2(bal - later)})

    series = detect_recurring(txs, today)
    recurring_ids = set().union(*[s["ids"] for s in series]) if series else set()
    window = [t for t in posted if (today - t["date"]).days < 30 and id(t) not in recurring_ids]
    outflows = [-t["amount"] for t in window if t["amount"] < 0 and -t["amount"] <= DISCRETIONARY_CAP]
    daily = (sum(outflows) / 30.0) if (use_discretionary and outflows) else 0.0

    upcoming = []
    end = today + timedelta(days=fdays)
    for s in series:
        n = s["next"]
        while n <= end:
            upcoming.append({"d": n.isoformat(), "label": s["label"], "amount": s["amount"]})
            n = n + timedelta(days=s["interval"])
    upcoming.sort(key=lambda u: u["d"])

    start = bal + pending_sum
    fc, run = [{"d": today.isoformat(), "v": r2(start)}], start
    for i in range(1, fdays + 1):
        day = (today + timedelta(days=i)).isoformat()
        run += sum(u["amount"] for u in upcoming if u["d"] == day) - daily
        fc.append({"d": day, "v": r2(run)})
    low = min(fc, key=lambda p: p["v"])
    run_b, low_b = start, start
    for i in range(1, fdays + 1):
        day = (today + timedelta(days=i)).isoformat()
        run_b += sum(u["amount"] for u in upcoming if u["d"] == day)
        low_b = min(low_b, run_b)
    change = r2(hist[-1]["v"] - hist[0]["v"])
    return {
        "history": hist,
        "change": {"amount": change, "days": days},
        "pending": r2(pending_sum),
        "forecast": fc,
        "forecastLow": low,
        "forecastLowBillsOnly": r2(low_b),
        "forecastMethod": "recurring" + ("+discretionary" if daily else ""),
        "discretionaryPerDay": r2(daily),
        "upcoming": upcoming[:8],
    }


def merge_history(given, previous, bal, today, days):
    pts = {}
    for p in (previous or []):
        pts[p["d"]] = p["v"]
    for p in (given or []):
        pts[str(p.get("d") or p.get("date"))[:10]] = num(p.get("v", p.get("value")))
    if bal is not None:
        pts[today.isoformat()] = r2(bal)
    cutoff = (today - timedelta(days=days)).isoformat()
    return [{"d": k, "v": r2(v)} for k, v in sorted(pts.items()) if k >= cutoff and v is not None]


def ytd(rows, today):
    tot = [num(r.get("amount"), 0) for r in rows or [] if d(r["date"]).year == today.year]
    return r2(sum(tot)) if rows is not None else None


def build_invest(acc, prev, today, days):
    bal = num(acc.get("balance"))
    hist = merge_history(acc.get("history"), (prev or {}).get("history"), bal, today, days)
    out = {"history": hist, "estimated": bool(acc.get("estimated"))}
    if len(hist) >= 2:
        first, last = hist[0]["v"], hist[-1]["v"]
        span = (d(hist[-1]["d"]) - d(hist[0]["d"])).days
        out["change"] = {"amount": r2(last - first),
                         "pct": r2((last - first) / first * 100) if first else None,
                         "days": span}
    out["ytdContributions"] = ytd(acc.get("contributions"), today)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("--transactions-csv")
    ap.add_argument("-o", "--output", default=DEFAULT_OUT)
    ap.add_argument("--days", type=int, default=30, help="history window for cash accounts")
    ap.add_argument("--invest-days", type=int, default=90, help="history window for retirement/HSA")
    ap.add_argument("--forecast-days", type=int, default=7)
    ap.add_argument("--no-discretionary", action="store_true",
                    help="forecast from recurring items only (no average daily spending)")
    ap.add_argument("--today", help="override today's date (YYYY-MM-DD), for testing")
    a = ap.parse_args()

    today = d(a.today) if a.today else date.today()
    src = json.load(open(os.path.expanduser(a.input)))
    accounts = src.get("accounts", [])
    by_id = {x["id"]: x for x in accounts}
    if a.transactions_csv:
        with open(os.path.expanduser(a.transactions_csv), newline="") as fh:
            for row in csv.DictReader(fh):
                acc = by_id.get(row.get("account_id"))
                if acc is None:
                    continue
                acc.setdefault("transactions", []).append({
                    "date": row["date"], "amount": row["amount"],
                    "description": row.get("description", ""),
                    "pending": str(row.get("pending", "")).lower() in {"1", "true", "yes"}})

    out_path = os.path.abspath(os.path.expanduser(a.output))
    previous = {}
    if os.path.exists(out_path):
        try:
            previous = {x["id"]: x for x in json.load(open(out_path)).get("accounts", [])}
        except (ValueError, KeyError):
            previous = {}

    result = []
    for acc in accounts:
        typ = (acc.get("type") or "checking").lower()
        mask = str(acc.get("mask") or "")[-4:]
        base = {"id": acc["id"], "type": typ, "name": acc.get("name") or acc["id"],
                "mask": mask, "institution": acc.get("institution", ""),
                "balance": r2(num(acc.get("balance"))), "currency": acc.get("currency", "USD")}
        if acc.get("available") is not None:
            base["available"] = r2(num(acc["available"]))
        if typ in CASH_TYPES:
            txs = []
            for t in acc.get("transactions", []):
                txs.append({"date": d(t["date"]), "amount": num(t["amount"], 0.0),
                            "description": str(t.get("description", "")),
                            "pending": bool(t.get("pending"))})
            acc["transactions"] = txs
            base.update(build_cash(acc, today, a.days, a.forecast_days, not a.no_discretionary))
        else:
            base.update(build_invest(acc, previous.get(acc["id"]), today, a.invest_days))
            if typ == "hsa":
                base["contributionLimit"] = num(acc.get("contributionLimit"))
                med = acc.get("medical") or []
                cutoff = today - timedelta(days=90)
                base["medicalSpend"] = {"days": 90, "amount": r2(sum(
                    abs(num(m.get("amount"), 0)) for m in med if d(m["date"]) >= cutoff))}
        if acc.get("extra"):
            base["extra"] = [{"label": str(e["label"])[:22], "value": r2(num(e["value"]))}
                             for e in acc["extra"]][:3]
        result.append(base)

    doc = {"version": 1, "generated": datetime.now().astimezone().isoformat(timespec="minutes"),
           "accounts": result}
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out_path), prefix=".accounts.")
    with os.fdopen(fd, "w") as fh:
        json.dump(doc, fh, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, out_path)
    print(f"wrote {out_path}: {len(result)} accounts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
