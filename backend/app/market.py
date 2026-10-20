"""London Strategic Edge adapter; credentials never leave this process."""

import json, threading, time
from concurrent.futures import ThreadPoolExecutor
from .concurrency import keyed_lock
from datetime import datetime, timezone
from fastapi import HTTPException
from lse import LSE, LSEError
from .db import Session, Cache, secret

_guard = threading.Lock()
_calls = []


def cached(key, ttl, fetch):
    with keyed_lock(key):
        with Session() as db:
            previous = db.get(Cache, key)
            if previous and previous.expires > time.time():
                return json.loads(previous.body)
        with _guard:
            now = time.time()
            _calls[:] = [stamp for stamp in _calls if stamp > now - 60]
            if len(_calls) >= 60:
                raise HTTPException(
                    429, "Market provider request budget exhausted; retry shortly"
                )
            _calls.append(now)
        try:
            result = fetch()
        except Exception as error:
            if previous:
                result = json.loads(previous.body)
                if isinstance(result, dict):
                    result["stale"] = True
                return result
            if isinstance(error, HTTPException):
                raise
            # Never surface SDK exceptions: some include authenticated URLs.
            status = getattr(error, "status", None)
            raise HTTPException(
                429 if status == 429 else 503,
                "London Strategic Edge is unavailable or rejected the request",
            ) from None
        with Session.begin() as db:
            db.merge(Cache(key=key, body=json.dumps(result), expires=now + ttl))
        return result


def client():
    key = secret("LSE_API_KEY")
    if not key:
        raise HTTPException(
            503, "Configure London Strategic Edge API key on the backend"
        )
    return LSE(api_key=key, timeout=20)


def search(query):
    query = query.strip().lower()
    if not query:
        return {"instruments": []}
    catalog = cached("lse:catalog", 86400, lambda: client().catalog())
    results = [
        r
        for r in catalog
        if query in r.get("symbol", "").lower() or query in r.get("name", "").lower()
    ]
    results.sort(
        key=lambda r: (r.get("symbol", "").lower() != query, r.get("symbol", ""))
    )
    return {"instruments": results[:30]}


def quote(symbol):
    c = client()
    minute = c.candles(symbol, "1m", limit=1, order="desc")
    daily = c.candles(symbol, "1d", limit=5, order="desc")
    if not minute:
        raise HTTPException(404, "No candles available for instrument")
    latest = minute[0]
    stamp = latest["timestamp"]
    day = stamp[:10]
    # Use a daily bar strictly before the latest minute's session date.
    prior = next((row for row in daily if row["timestamp"][:10] < day), None)
    price = float(latest["close"])
    previous = float(prior["close"]) if prior else None
    change = price - previous if previous is not None else None
    return {
        "symbol": symbol,
        "price": price,
        "change": change,
        "changePercent": 100 * change / previous if previous else None,
        "timestamp": stamp,
        "source": "1-minute candle close",
        "previousClose": previous,
        "sessionDate": day,
    }


def quotes(symbols):
    names = list(dict.fromkeys(s.strip() for s in symbols.split(",") if s.strip()))
    if len(names) > 30 or any(len(s) > 80 for s in names):
        raise HTTPException(422, "Maximum 30 symbols per request")

    def load(symbol):
        try:
            return cached("lse:quote:" + symbol, 60, lambda: quote(symbol))
        except HTTPException as error:
            return {"symbol": symbol, "error": error.detail}

    if not names:
        return {"quotes": []}
    with ThreadPoolExecutor(max_workers=min(4, len(names))) as executor:
        return {"quotes": list(executor.map(load, names))}
