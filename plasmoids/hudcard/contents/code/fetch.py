#!/usr/bin/env python3
"""Data helper for the HUD Card plasmoid.

  fetch.py --stock SYMBOL[|news query] [--stock ...] [--accounts FILE]

Prints one JSON object: {"stocks": {SYM: {...}}, "accounts": {...}|null, ...}
Quotes: CNBC restQuote (browser User-Agent required). Daily history and volume:
Nasdaq historical API. Headline: Google News RSS. History and news are cached
under ~/.cache/controllimit-hud to stay polite. Accounts come only from a local
JSON file you control; this script never contacts a bank.
"""
import argparse
import html
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from urllib.parse import quote_plus

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/120.0.0.0 Safari/537.36")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "controllimit-hud")
HISTORY_TTL = 30 * 60
NEWS_TTL = 15 * 60
CNBC_MAP = {
    "^VIX": ".VIX", "VIX": ".VIX", ".VIX": ".VIX",
    "BTC-USD": "BTC.CM=", "BTCUSD": "BTC.CM=", "BTC": "BTC.CM=",
    "ETH-USD": "ETH.CM=", "ETHUSD": "ETH.CM=", "ETH": "ETH.CM=",
    "^GSPC": ".SPX", "^SPX": ".SPX", "SPX": ".SPX",
    "^DJI": ".DJI", "DJI": ".DJI", "^IXIC": ".IXIC", "IXIC": ".IXIC", "COMP": ".IXIC",
    "^RUT": ".RUT",
}


def sanitize_symbol(raw):
    return re.sub(r"[^A-Za-z0-9.^_=-]", "", (raw or "").strip()).upper()[:16]


def sanitize_query(raw):
    s = re.sub(r"[^A-Za-z0-9 ._+'-]", " ", raw or "")
    return re.sub(r"\s+", " ", s).strip()[:120]


def curl(url, accept="*/*", timeout=20):
    proc = subprocess.run(["curl", "-sS", "-L", "--max-time", str(timeout), "-A", UA,
                           "-H", f"Accept: {accept}", url], capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def parse_number(text):
    if text is None:
        return None
    s = str(text).replace(",", "").replace("$", "").replace("+", "").replace("%", "").strip()
    if not s or s in {"—", "-", "N/A", "n/a"}:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def abbreviate(n):
    if n is None:
        return "—"
    sign, n = ("-" if n < 0 else ""), abs(n)
    for div, suf in ((1e9, "B"), (1e6, "M"), (1e4, "K")):
        if n >= div:
            return f"{sign}{n/div:.1f}{suf}"
    return f"{sign}{n:,.0f}"


def now_in(tz):
    if ZoneInfo is None:
        return datetime.now()
    try:
        return datetime.now(ZoneInfo(tz)) if tz else datetime.now().astimezone()
    except Exception:
        return datetime.now().astimezone()


def market_hours_now():
    now = now_in("America/New_York")
    minutes = now.hour * 60 + now.minute
    return now.weekday() < 5 and 570 <= minutes < 960


def local_stamp():
    now = datetime.now().astimezone()
    return now.strftime("%-I:%M %p ") + (now.tzname() or "")


def cached(name, ttl, producer):
    path = os.path.join(CACHE, name)
    try:
        if time.time() - os.path.getmtime(path) < ttl:
            with open(path) as fh:
                return json.load(fh), None
    except (OSError, ValueError):
        pass
    value, err = producer()
    if value:
        try:
            os.makedirs(CACHE, exist_ok=True)
            with open(path + ".tmp", "w") as fh:
                json.dump(value, fh)
            os.replace(path + ".tmp", path)
        except OSError:
            pass
    return value, err


def fetch_quote(symbol):
    cnbc = CNBC_MAP.get(symbol, symbol)
    url = ("https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol"
           f"?symbols={quote_plus(cnbc, safe='.=')}&requestMethod=itv&noform=1&partnerId=2&output=json")
    code, out, err = curl(url, accept="application/json")
    if code != 0 or not out:
        return None, f"quote failed: {err.strip() or code}"
    try:
        raw = json.loads(out)["FormattedQuoteResult"]["FormattedQuote"]
        raw = raw[0] if isinstance(raw, list) and raw else raw
    except (KeyError, ValueError, TypeError, IndexError) as exc:
        return None, f"quote parse failed: {exc}"
    if not raw or str(raw.get("code", "0")) not in {"0", "0.0"}:
        return None, f"no quote for {symbol}"
    pct = parse_number(raw.get("change_pct"))
    return {
        "name": raw.get("name") or raw.get("shortName") or symbol,
        "price": parse_number(raw.get("last")),
        "change": parse_number(raw.get("change")),
        "changePct": pct,
        "open": parse_number(raw.get("open")),
        "high": parse_number(raw.get("high")),
        "low": parse_number(raw.get("low")),
        "previousClose": parse_number(raw.get("previous_day_closing")),
        "volume": parse_number(raw.get("volume")),
        "volumeAlt": raw.get("volume_alt") or None,
        "up": str(raw.get("changetype") or "").upper() == "UP" or (pct or 0) > 0,
    }, None


def _history(symbol):
    end = datetime.now().date()
    start = end - timedelta(days=70)
    for asset in ("stocks", "etf", "index"):
        url = (f"https://api.nasdaq.com/api/quote/{quote_plus(symbol.lstrip('^'))}/historical"
               f"?assetclass={asset}&fromdate={start}&todate={end}&limit=40")
        code, out, _ = curl(url, accept="application/json")
        if code != 0 or not out:
            continue
        try:
            rows = ((json.loads(out).get("data") or {}).get("tradesTable") or {}).get("rows") or []
        except ValueError:
            continue
        pts = []
        for row in rows:
            close = parse_number(row.get("close"))
            try:
                day = datetime.strptime((row.get("date") or "").strip(), "%m/%d/%Y")
            except ValueError:
                continue
            if close is not None:
                pts.append({"date": day.strftime("%Y-%m-%d"), "close": close,
                            "volume": parse_number(row.get("volume"))})
        if pts:
            pts.sort(key=lambda p: p["date"])
            return pts[-30:], None
    return None, "no daily history"


def _news(query):
    url = "https://news.google.com/rss/search?q=" + quote_plus(query) + "&hl=en-US&gl=US&ceid=US:en"
    code, out, err = curl(url, accept="application/rss+xml, application/xml, text/xml")
    if code != 0 or not out:
        return None, "news failed"
    try:
        item = ET.fromstring(out).find("./channel/item")
    except ET.ParseError:
        return None, "news parse failed"
    if item is None:
        return None, "no news"
    title = html.unescape(re.sub(r"\s+", " ", (item.findtext("title") or "").strip()))
    link = (item.findtext("link") or "").strip()
    src = item.find("source")
    if not title or not link:
        return None, "no news"
    return {"title": title, "url": html.unescape(link),
            "source": (src.text or "").strip() if src is not None else ""}, None


def stock(spec):
    sym, _, q = spec.partition("|")
    symbol = sanitize_symbol(sym)
    out = {"ok": False, "symbol": symbol, "error": ""}
    if not symbol:
        out["error"] = "missing symbol"
        return symbol, out
    quote, qerr = fetch_quote(symbol)
    if quote:
        out.update(quote)
        out["ok"] = True
    else:
        out["error"] = qerr
    hist, _ = cached(f"hist-{symbol}.json", HISTORY_TTL, lambda: _history(symbol))
    out["history"] = hist or []
    if hist and len(hist) >= 2 and out.get("price") is not None:
        prev = out.get("previousClose")
        if prev is None or abs(prev - out["price"]) < 1e-9 or abs(prev - hist[-1]["close"]) < 1e-9:
            out["previousClose"] = hist[-2]["close"]
    query = sanitize_query(q) or f"{symbol} stock"
    safe = re.sub(r"[^a-z0-9]+", "-", query.lower())[:60]
    out["news"], _ = cached(f"news-{safe}.json", NEWS_TTL, lambda: _news(query))
    if not out.get("volumeAlt"):
        out["volumeAlt"] = abbreviate(out.get("volume"))
    return symbol, out


def accounts(path):
    path = os.path.expanduser(path or "")
    if not path:
        return None
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {"error": "accounts file not found", "accounts": []}
    except (OSError, ValueError) as exc:
        return {"error": f"accounts file unreadable: {exc.__class__.__name__}", "accounts": []}
    doc.setdefault("accounts", [])
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", action="append", default=[])
    ap.add_argument("--accounts", default="")
    a = ap.parse_args()
    specs = [s for s in a.stock if s.strip()][:20]
    with ThreadPoolExecutor(max_workers=4) as pool:
        stocks = dict(pool.map(stock, specs))
    print(json.dumps({"stocks": stocks, "accounts": accounts(a.accounts),
                      "marketHours": market_hours_now(), "updatedAt": local_stamp()},
                     separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
