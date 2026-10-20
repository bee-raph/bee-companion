#!/usr/bin/env python3
"""Exercise a running instance without logging credentials or provider keys."""

import hashlib, json, sys, uuid
from pathlib import Path
import httpx

runtime = Path(sys.argv[1] if len(sys.argv) > 1 else ".runtime")
config = json.loads((runtime / "client.companion-instance.json").read_text())
password = (runtime / "initial-login.txt").read_text().split("Password: ")[1].strip()
c = httpx.Client(base_url=config["apiBaseURL"], timeout=60)
assert c.get("/api/v1/instance").json()["instanceID"] == config["instanceID"]
assert c.get("/api/v1/sync/pull").status_code == 401
r = c.post("/api/v1/auth/login", json={"login": "owner", "password": password})
r.raise_for_status()
c.headers["Authorization"] = "Bearer " + r.json()["accessToken"]
ident = str(uuid.uuid4())
mutation = {
    "operationID": str(uuid.uuid4()),
    "id": ident,
    "kind": "notes",
    "expectedRevision": 0,
    "body": {
        "title": "Smoke test שלום",
        "format": "markdown",
        "text": "Backup verification",
    },
    "deleted": False,
}
r = c.post("/api/v1/sync/push", json={"mutations": [mutation]})
r.raise_for_status()
assert r.json()["results"][0]["status"] == "applied"
assert c.post("/api/v1/sync/push", json={"mutations": [mutation]}).json() == r.json()
content = b"companion integration test"
file_id = str(uuid.uuid4())
u = c.post(
    "/api/v1/files/uploads",
    json={
        "fileID": file_id,
        "size": len(content),
        "checksum": hashlib.sha256(content).hexdigest(),
    },
)
u.raise_for_status()
upload = u.json()["id"]
c.put(
    f"/api/v1/files/uploads/{upload}?offset=0", content=content[:5]
).raise_for_status()
assert c.get(f"/api/v1/files/uploads/{upload}").json()["offset"] == 5
c.put(
    f"/api/v1/files/uploads/{upload}?offset=5", content=content[5:]
).raise_for_status()
c.post(f"/api/v1/files/uploads/{upload}/complete").raise_for_status()
assert c.get(f"/api/v1/files/{file_id}/content").content == content
pull = c.get("/api/v1/sync/pull")
pull.raise_for_status()
assert any(x["id"] == ident for x in pull.json()["changes"])
search = c.get("/api/v1/market/search", params={"q": "AAPL"})
search.raise_for_status()
assert any(x["symbol"] == "AAPL" for x in search.json()["instruments"])
quotes = c.get("/api/v1/market/quotes", params={"symbols": "AAPL"})
quotes.raise_for_status()
assert quotes.json()["quotes"][0].get("price") is not None
print(
    "PASS: identity, authentication, idempotent sync, Hebrew content, resumable files, checksums, market search and quotes"
)
(runtime / "smoke-manifest.json").write_text(
    json.dumps(
        {
            "noteID": ident,
            "fileID": file_id,
            "checksum": hashlib.sha256(content).hexdigest(),
        }
    )
)
c.post("/api/v1/auth/logout").raise_for_status()
