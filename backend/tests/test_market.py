import time
from app import market
from fastapi import HTTPException
import pytest


class Provider:
    def candles(self, symbol, timeframe, **kwargs):
        if timeframe == "1m":
            return [{"timestamp": "2026-10-20T12:00:00Z", "close": 105}]
        return [
            {"timestamp": "2026-10-20T00:00:00Z", "close": 104},
            {"timestamp": "2026-10-19T00:00:00Z", "close": 100},
        ]


def test_previous_completed_session(monkeypatch):
    monkeypatch.setattr(market, "client", lambda: Provider())
    result = market.quote("AAPL")
    assert result["previousClose"] == 100
    assert result["change"] == 5 and result["changePercent"] == 5
    assert result["source"] == "1-minute candle close"


def test_missing_prior_does_not_invent_change(monkeypatch):
    class OnlyCurrent(Provider):
        def candles(self, symbol, timeframe, **kwargs):
            return [{"timestamp": "2026-10-20T00:00:00Z", "close": 105}]

    monkeypatch.setattr(market, "client", lambda: OnlyCurrent())
    assert market.quote("AAPL")["changePercent"] is None


def test_limit_and_duplicate_symbols(monkeypatch):
    monkeypatch.setattr(market, "cached", lambda key, ttl, fn: fn())
    monkeypatch.setattr(market, "quote", lambda symbol: {"symbol": symbol, "price": 1})
    assert len(market.quotes("AAPL,AAPL")["quotes"]) == 1
    with pytest.raises(HTTPException):
        market.quotes(",".join(str(i) for i in range(31)))


def test_empty_search_does_not_contact_provider(monkeypatch):
    def unexpected(*args):
        raise AssertionError("Empty searches must not load the catalog")

    monkeypatch.setattr(market, "cached", unexpected)
    assert market.search("   ") == {"instruments": []}


def test_quotes_fetch_independent_symbols_concurrently_and_keep_order(monkeypatch):
    import threading

    barrier = threading.Barrier(4)

    def quote(symbol):
        barrier.wait(timeout=2)
        return {"symbol": symbol}

    monkeypatch.setattr(market, "cached", lambda key, ttl, fn: fn())
    monkeypatch.setattr(market, "quote", quote)
    assert market.quotes("A,B,C,D")["quotes"] == [{"symbol": name} for name in "ABCD"]
