import json
import socket
import pytest
from defusedxml.common import DefusedXmlException
from app.reader import parse_feed, validate_settings, download, weather
from app.db import Base, engine


def test_rss_and_atom_plain_summaries_and_stable_ids():
    rss = b"<rss><channel><item><guid>one</guid><title>Hello &amp; welcome</title><description>&lt;b&gt;Readable&lt;/b&gt; text</description><link>https://example.com/article</link><pubDate>Tue, 20 Oct 2026 10:00:00 GMT</pubDate></item></channel></rss>"
    articles = parse_feed(rss, "https://example.com/feed")
    assert articles[0]["title"] == "Hello & welcome"
    assert "<b>" not in articles[0]["summary"]
    assert articles[0]["published"].startswith("2026-10-20T10:00")
    assert parse_feed(rss, "https://example.com/feed")[0]["id"] == articles[0]["id"]
    atom = b'<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>two</id><title>Atom</title><summary>News</summary><link href="/news"/><updated>2026-10-20T12:00:00Z</updated></entry></feed>'
    assert (
        parse_feed(atom, "https://example.com/feed")[0]["url"]
        == "https://example.com/news"
    )


def test_xml_entities_are_rejected():
    xml = b'<!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/passwd">]><rss><item><title>&secret;</title></item></rss>'
    with pytest.raises(DefusedXmlException):
        parse_feed(xml, "https://example.com/feed")


def test_private_feed_addresses_never_connect(monkeypatch):
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *args, **kwargs: [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 80))
        ],
    )
    monkeypatch.setattr(
        socket,
        "create_connection",
        lambda *args, **kwargs: pytest.fail("Private connection attempted"),
    )
    with pytest.raises(ValueError):
        download("http://localhost/feed")


def test_feed_limit_and_preferences():
    feeds = [
        {"id": str(i), "title": "Feed", "url": "https://example.com/feed"}
        for i in range(3)
    ]
    validate_settings(
        {
            "rssFeeds": json.dumps(feeds),
            "shabbatRefreshSeconds": "60",
            "shabbatStocks": "[]",
        }
    )
    with pytest.raises(ValueError):
        validate_settings(
            {
                "rssFeeds": json.dumps(
                    feeds + [{"id": "4", "url": "https://example.com"}]
                )
            }
        )
    with pytest.raises(ValueError):
        validate_settings({"shabbatRefreshSeconds": "1"})
    with pytest.raises(ValueError):
        validate_settings(
            {"rssFeeds": json.dumps([{"id": "1", "url": "file:///etc/passwd"}])}
        )
    with pytest.raises(ValueError):
        validate_settings(
            {
                "rssFeeds": json.dumps(
                    [{"id": "1", "url": "https://user:password@example.com"}]
                )
            }
        )


def test_weather_failure_is_explicit(monkeypatch):
    import httpx
    from fastapi import HTTPException

    Base.metadata.create_all(engine)
    monkeypatch.setattr(
        httpx,
        "get",
        lambda *a, **kw: (_ for _ in ()).throw(httpx.ConnectError("offline")),
    )
    with pytest.raises(HTTPException) as error:
        weather(31.78, 35.23, "Asia/Jerusalem")
    assert error.value.status_code == 503
