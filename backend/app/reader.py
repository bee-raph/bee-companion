"""Public RSS/Atom feeds and local weather, with bounded downloads and private-address protection."""

import hashlib
from concurrent.futures import ThreadPoolExecutor
import http.client
import ipaddress
import json
import re
import socket
import ssl
import time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html import unescape
from urllib.parse import urljoin, urlsplit
from defusedxml import ElementTree
import httpx
from fastapi import HTTPException
from sqlalchemy import select
from .db import Cache, Record, Session


def valid_url(value):
    try:
        u = urlsplit(value)
        if (
            u.scheme not in {"http", "https"}
            or not u.hostname
            or u.username
            or u.password
            or u.fragment
            or u.port not in {None, 80, 443}
        ):
            raise ValueError()
        if len(value) > 2048:
            raise ValueError()
        return u
    except ValueError:
        raise ValueError(
            "Use a public HTTP or HTTPS feed URL without credentials"
        ) from None


def validate_settings(body):
    try:
        feeds = json.loads(body.get("rssFeeds", "[]"))
        if not isinstance(feeds, list) or len(feeds) > 3:
            raise ValueError("Configure at most three RSS feeds")
        ids = set()
        for feed in feeds:
            if (
                not isinstance(feed, dict)
                or not isinstance(feed.get("url"), str)
                or not isinstance(feed.get("id"), str)
                or not isinstance(feed.get("title", ""), str)
            ):
                raise ValueError("Invalid RSS feed configuration")
            if feed["id"] in ids or not feed["id"]:
                raise ValueError("Feed IDs must be unique")
            ids.add(feed["id"])
            valid_url(feed["url"])
        interval = int(body.get("shabbatRefreshSeconds", "300"))
        rotation = int(body.get("shabbatRotationSeconds", "15"))
        selected = json.loads(body.get("shabbatStocks", "[]"))
        if not 60 <= interval <= 3600:
            raise ValueError("Refresh interval must be 60–3600 seconds")
        if not 10 <= rotation <= 120:
            raise ValueError("Headline rotation must be 10–120 seconds")
        if (
            not isinstance(selected, list)
            or len(selected) > 6
            or any(not isinstance(x, str) for x in selected)
        ):
            raise ValueError("Select at most six stocks")
    except (TypeError, json.JSONDecodeError):
        raise ValueError("Invalid reader settings") from None


def settings():
    with Session() as db:
        row = db.get(Record, "00000000-0000-0000-0000-000000000001")
        return (
            json.loads(row.body)
            if row and row.kind == "user_settings" and not row.deleted
            else {}
        )


def download(url):
    deadline = time.monotonic() + 15
    for _ in range(4):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("Feed download timed out")
        u = valid_url(url)
        addresses = socket.getaddrinfo(
            u.hostname,
            u.port or (443 if u.scheme == "https" else 80),
            type=socket.SOCK_STREAM,
        )
        if not addresses or any(
            not ipaddress.ip_address(row[4][0]).is_global for row in addresses
        ):
            raise ValueError("Feed address must be public")
        ip = addresses[0][4][0]
        port = u.port or (443 if u.scheme == "https" else 80)
        connection = http.client.HTTPConnection(u.hostname, port, timeout=remaining)
        # Pin the validated IP while keeping TLS certificate verification and SNI for the host.
        sock = socket.create_connection((ip, port), timeout=remaining)
        if u.scheme == "https":
            sock = ssl.create_default_context().wrap_socket(
                sock, server_hostname=u.hostname
            )
        connection.sock = sock
        try:
            path = u.path or "/"
            if u.query:
                path += "?" + u.query
            connection.request(
                "GET",
                path,
                headers={
                    "Host": u.netloc,
                    "User-Agent": "BeeCompanion/0.2 RSS Reader",
                    "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml",
                    "Accept-Encoding": "identity",
                },
            )
            response = connection.getresponse()
            if response.status in {301, 302, 303, 307, 308}:
                location = response.getheader("Location")
                if not location:
                    raise ValueError("Invalid feed redirect")
                url = urljoin(url, location)
                continue
            if response.status != 200:
                raise ValueError("Feed server returned an error")
            data = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("Feed download timed out")
                sock.settimeout(remaining)
                chunk = response.read1(32768)
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > 2 * 1024 * 1024:
                    raise ValueError("Feed exceeds 2 MiB limit")
            return bytes(data), url
        finally:
            connection.close()
    raise ValueError("Too many feed redirects")


def plain(value):
    return unescape(re.sub("<[^>]+>", " ", value or "")).strip()[:4000]


def parse_feed(data, url):
    root = ElementTree.fromstring(data)

    def name(e):
        return e.tag.rsplit("}", 1)[-1].lower()

    def value(node, names):
        return next(
            ("".join(c.itertext()).strip() for c in node if name(c) in names), ""
        )

    output = []
    for node in root.iter():
        if name(node) not in {"item", "entry"}:
            continue
        link = ""
        for child in node:
            if (
                name(child) == "link"
                and child.attrib.get("rel", "alternate") == "alternate"
            ):
                link = child.attrib.get("href") or (child.text or "")
                break
        link = urljoin(url, link)
        try:
            valid_url(link)
        except ValueError:
            link = ""
        title = plain(value(node, {"title"})) or "Untitled"
        stamp = value(node, {"pubdate", "published", "updated", "date"})
        try:
            try:
                dt = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            except ValueError:
                dt = parsedate_to_datetime(stamp)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            stamp = dt.astimezone(timezone.utc).isoformat()
        except (ValueError, TypeError, OverflowError, AttributeError):
            stamp = ""
        ident = value(node, {"guid", "id"}) or link or title + stamp
        output.append(
            {
                "id": hashlib.sha256((url + ident).encode()).hexdigest(),
                "title": title,
                "summary": plain(
                    value(node, {"description", "summary", "content", "encoded"})
                ),
                "url": link,
                "published": stamp,
            }
        )
        if len(output) >= 60:
            break
    unique = {entry["id"]: entry for entry in output}
    return sorted(unique.values(), key=lambda x: x["published"], reverse=True)


def load_feed(feed, interval):
    key = "rss:" + hashlib.sha256(feed["url"].encode()).hexdigest()
    with Session() as db:
        previous = db.get(Cache, key)
    cached = json.loads(previous.body) if previous else None
    base = {
        "id": feed["id"],
        "title": feed.get("title") or urlsplit(feed["url"]).hostname,
        "url": feed["url"],
    }
    if previous and previous.expires > time.time():
        return {**base, **cached, "stale": False}
    try:
        data, url = download(feed["url"])
        payload = {
            "articles": parse_feed(data, url),
            "fetchedAt": datetime.now(timezone.utc).isoformat(),
        }
        with Session.begin() as db:
            db.merge(
                Cache(
                    key=key,
                    body=json.dumps(payload),
                    expires=time.time() + min(interval, 300),
                )
            )
        return {**base, **payload, "stale": False}
    except Exception:
        return {
            **base,
            **(cached or {"articles": [], "fetchedAt": None}),
            "stale": True,
            "error": (
                "Feed unavailable; showing saved articles"
                if cached
                else "Feed unavailable. Check the public RSS or Atom URL."
            ),
        }


def feeds():
    body = settings()
    configured = json.loads(body.get("rssFeeds", "[]"))[:3]
    if not configured:
        return {"feeds": []}
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = [
            executor.submit(
                load_feed, feed, int(body.get("shabbatRefreshSeconds", "300"))
            )
            for feed in configured
        ]
        return {"feeds": [future.result() for future in futures]}


def weather(latitude, longitude, zone):
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise HTTPException(422, "Invalid coordinates")
    key = "weather:" + json.dumps([latitude, longitude, zone])
    with Session() as db:
        cached = db.get(Cache, key)
    if cached and cached.expires > time.time():
        return {**json.loads(cached.body), "stale": False}
    try:
        response = httpx.get(
            "https://api.open-meteo.com/v1/forecast",
            params={
                "latitude": latitude,
                "longitude": longitude,
                "timezone": zone,
                "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m",
                "daily": "temperature_2m_max,temperature_2m_min",
                "forecast_days": 1,
            },
            timeout=15,
        )
        response.raise_for_status()
        data = response.json()
        current = data["current"]
        daily = data["daily"]
        result = {
            "temperature": current["temperature_2m"],
            "feelsLike": current["apparent_temperature"],
            "humidity": current["relative_humidity_2m"],
            "code": current["weather_code"],
            "wind": current["wind_speed_10m"],
            "high": daily["temperature_2m_max"][0],
            "low": daily["temperature_2m_min"][0],
            "timestamp": current["time"],
            "attribution": "Open-Meteo",
        }
        with Session.begin() as db:
            db.merge(Cache(key=key, body=json.dumps(result), expires=time.time() + 600))
        return {**result, "stale": False}
    except Exception:
        if cached:
            return {**json.loads(cached.body), "stale": True}
        raise HTTPException(
            503, "Weather is unavailable; check location and connection"
        ) from None
