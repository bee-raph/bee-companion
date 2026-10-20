import hashlib, json, os, secrets, time, uuid
from collections import defaultdict, deque
from pathlib import Path
from typing import Literal
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import FastAPI, Depends, HTTPException, Header, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool
from .concurrency import singleflight
from pydantic import BaseModel, Field
from sqlalchemy import select, text
from .db import (
    Session,
    engine,
    Owner,
    Token,
    Record,
    Change,
    Receipt,
    Upload,
    Version,
    Cache,
)

app = FastAPI(title="Bee Companion", version="1.0.0")
root = Path(os.getenv("FILES_ROOT", "./files"))
root.mkdir(parents=True, exist_ok=True)
ph = PasswordHasher()
attempts = defaultdict(deque)
KINDS = {
    "crm_contacts",
    "crm_actions",
    "crm_attachments",
    "tasks",
    "notes",
    "folders",
    "files",
    "task_attachments",
    "note_attachments",
    "reminder_attachments",
    "reminders",
    "reminder_occurrences",
    "user_settings",
    "watchlist_items",
}


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def lock(db):
    if engine.dialect.name == "postgresql":
        db.execute(text("SELECT pg_advisory_xact_lock(731927)"))


def auth(authorization: str = Header(default="")):
    token = authorization.removeprefix("Bearer ")
    with Session() as db:
        row = db.get(Token, digest(token))
        if not row or row.kind != "access" or row.expires < time.time():
            raise HTTPException(401, "Sign in required")
        return row.family


class Login(BaseModel):
    login: str
    password: str


class Refresh(BaseModel):
    token: str


def issue(db, family=None):
    family = family or str(uuid.uuid4())
    result = {}
    for kind, duration in [("access", 900), ("refresh", 2592000)]:
        token = secrets.token_urlsafe(48)
        db.add(
            Token(
                hash=digest(token),
                family=family,
                kind=kind,
                expires=time.time() + duration,
            )
        )
        result[kind + "Token"] = token
    return result


@app.get("/api/v1/instance")
def instance():
    return {
        "instanceID": os.getenv("INSTANCE_ID", "development"),
        "instanceName": os.getenv("INSTANCE_NAME", "Companion"),
        "apiVersion": 1,
        "schemaVersion": 1,
    }


@app.get("/health/live")
def live():
    return {"status": "ok"}


@app.get("/health/ready")
def ready():
    with Session() as db:
        db.execute(select(Owner).limit(1))
    return {"status": "ready"}


@app.post("/api/v1/auth/login")
def login(body: Login, request: Request):
    key = request.client.host
    now = time.time()
    queue = attempts[key]
    while queue and queue[0] < now - 60:
        queue.popleft()
    if len(queue) >= 5:
        raise HTTPException(429, "Try again in a minute")
    queue.append(now)
    with Session.begin() as db:
        owner = db.get(Owner, 1)
        try:
            if not owner or owner.login != body.login:
                raise ValueError()
            ph.verify(owner.password, body.password)
        except (VerificationError, ValueError):
            raise HTTPException(401, "Invalid credentials")
        queue.clear()
        return issue(db)


@app.post("/api/v1/auth/refresh")
def refresh(body: Refresh):
    with Session.begin() as db:
        lock(db)
        row = db.get(Token, digest(body.token))
        if not row or row.kind != "refresh" or row.expires < time.time():
            raise HTTPException(401, "Expired session")
        family = row.family
        for item in db.scalars(select(Token).where(Token.family == family)):
            db.delete(item)
        return issue(db, family)


@app.post("/api/v1/auth/logout")
def logout(family=Depends(auth)):
    with Session.begin() as db:
        for item in db.scalars(select(Token).where(Token.family == family)):
            db.delete(item)
    return {"ok": True}


class Mutation(BaseModel):
    operationID: uuid.UUID
    id: uuid.UUID
    kind: str
    expectedRevision: int = Field(ge=0)
    body: dict[str, str]
    deleted: bool = False


class Push(BaseModel):
    mutations: list[Mutation] = Field(max_length=100)


def encoded(row):
    return {
        "id": row.id,
        "kind": row.kind,
        "revision": row.revision,
        "body": json.loads(row.body),
        "deleted": row.deleted,
    }


@app.post("/api/v1/sync/push", dependencies=[Depends(auth)])
def push(payload: Push):
    results = []
    with Session.begin() as db:
        lock(db)
        for m in payload.mutations:
            op = str(m.operationID)
            receipt = db.get(Receipt, op)
            if receipt:
                results.append(json.loads(receipt.body))
                continue
            if m.kind == "user_settings":
                from .reader import validate_settings

                try:
                    validate_settings(m.body)
                except ValueError as error:
                    raise HTTPException(422, str(error))
            if m.kind.startswith("crm_") and not m.deleted:
                from .crm import validate_crm

                try:
                    validate_crm(m.kind, m.body, db)
                except ValueError as error:
                    raise HTTPException(422, str(error))
            if m.kind not in KINDS:
                raise HTTPException(422, "Unknown record kind")
            if m.kind in {"files", "folders"}:
                name = m.body.get("title", "")
                if (
                    not name
                    or name in {".", ".."}
                    or "/" in name
                    or "\\" in name
                    or len(name) > 255
                ):
                    raise HTTPException(422, "Invalid file or folder name")
                parent = m.body.get("parent", "")
                visited = {str(m.id)}
                while parent:
                    if parent in visited:
                        raise HTTPException(422, "Folder cycle")
                    visited.add(parent)
                    ancestor = db.get(Record, parent)
                    if not ancestor or ancestor.kind != "folders" or ancestor.deleted:
                        raise HTTPException(422, "Invalid parent folder")
                    parent = json.loads(ancestor.body).get("parent", "")
            row = db.get(Record, str(m.id))
            if row and row.kind != m.kind:
                raise HTTPException(409, "Record kind cannot change")
            if (row.revision if row else 0) != m.expectedRevision:
                results.append(
                    {
                        "operationID": op,
                        "status": "conflict",
                        "server": encoded(row) if row else None,
                    }
                )
                continue
            if not row:
                row = Record(id=str(m.id), kind=m.kind, revision=0)
                db.add(row)
            row.revision += 1
            row.body = json.dumps(m.body)
            row.deleted = m.deleted
            result = {"operationID": op, "status": "applied", "record": encoded(row)}
            db.add(Change(body=json.dumps(encoded(row))))
            db.add(Receipt(id=op, body=json.dumps(result)))
            db.flush()
            results.append(result)
    return {"results": results}


@app.get("/api/v1/sync/pull", dependencies=[Depends(auth)])
def pull(cursor: int = 0):
    if cursor < 0:
        raise HTTPException(422, "Invalid cursor")
    with Session() as db:
        rows = list(
            db.scalars(
                select(Change)
                .where(Change.sequence > cursor)
                .order_by(Change.sequence)
                .limit(200)
            )
        )
        return {
            "changes": [json.loads(r.body) for r in rows],
            "cursor": rows[-1].sequence if rows else cursor,
            "hasMore": len(rows) == 200,
        }


class UploadRequest(BaseModel):
    fileID: uuid.UUID
    size: int = Field(ge=0, le=10 * 1024**3)
    checksum: str = Field(pattern=r"^[a-f0-9]{64}$")


@app.post("/api/v1/files/uploads", dependencies=[Depends(auth)])
def upload_create(body: UploadRequest):
    ident = str(uuid.uuid4())
    (root / (ident + ".part")).touch()
    with Session.begin() as db:
        db.add(
            Upload(
                id=ident,
                file_id=str(body.fileID),
                size=body.size,
                checksum=body.checksum,
                offset=0,
            )
        )
    return {"id": ident, "offset": 0}


@app.get("/api/v1/files/uploads/{ident}", dependencies=[Depends(auth)])
def upload_status(ident: uuid.UUID):
    with Session() as db:
        row = db.get(Upload, str(ident))
        if not row:
            raise HTTPException(404)
        return {"id": row.id, "offset": row.offset, "complete": row.complete}


@app.put("/api/v1/files/uploads/{ident}", dependencies=[Depends(auth)])
async def upload_chunk(ident: uuid.UUID, request: Request, offset: int):
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > 8 * 1024 * 1024:
            raise HTTPException(413, "Maximum chunk is 8 MiB")
    return await run_in_threadpool(store_upload_chunk, ident, offset, data)


def store_upload_chunk(ident, offset, data):
    with Session.begin() as db:
        lock(db)
        row = db.get(Upload, str(ident))
        if not row:
            raise HTTPException(404)
        if row.complete or row.offset != offset:
            raise HTTPException(409, "Offset mismatch")
        if offset + len(data) > row.size:
            raise HTTPException(413)
        with (root / (row.id + ".part")).open("r+b") as stream:
            stream.seek(offset)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        row.offset += len(data)
        return {"offset": row.offset}


@app.post("/api/v1/files/uploads/{ident}/complete", dependencies=[Depends(auth)])
@singleflight(lambda ident: "upload-complete:" + str(ident))
def upload_complete(ident: uuid.UUID):
    with Session() as db:
        row = db.get(Upload, str(ident))
        if not row:
            raise HTTPException(404)
        if row.complete:
            return {"versionID": row.id}
        if row.offset != row.size:
            raise HTTPException(409, "Incomplete upload")
        temporary = root / (row.id + ".part")
        target = root / row.id
        source = temporary if temporary.exists() else target
        if not source.exists():
            raise HTTPException(409, "Incomplete upload")
        expected_checksum = row.checksum
        size = row.size
    # Complete-sized uploads cannot accept additional bytes; hash outside the sync lock.
    try:
        stream = source.open("rb")
    except FileNotFoundError:
        stream = target.open("rb")
    with stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    if checksum != expected_checksum:
        raise HTTPException(422, "Checksum mismatch")
    with Session.begin() as db:
        lock(db)
        row = db.get(Upload, str(ident))
        if not row:
            raise HTTPException(404)
        if row.complete:
            return {"versionID": row.id}
        if row.offset != size or row.checksum != expected_checksum:
            raise HTTPException(409, "Incomplete upload")
        if temporary.exists():
            temporary.replace(target)
        db.add(
            Version(
                id=row.id,
                file_id=row.file_id,
                checksum=checksum,
                size=row.size,
                created=time.time(),
            )
        )
        row.complete = True
        return {"versionID": row.id}


@app.get("/api/v1/files/{ident}/content", dependencies=[Depends(auth)])
def download(ident: uuid.UUID):
    with Session() as db:
        version = db.scalar(
            select(Version)
            .where(Version.file_id == str(ident))
            .order_by(Version.created.desc())
            .limit(1)
        )
        if not version:
            raise HTTPException(404)
        return FileResponse(
            root / version.id, headers={"X-Content-SHA256": version.checksum}
        )


@app.get("/api/v1/market/search", dependencies=[Depends(auth)])
def market_search(q: str):
    from .market import search

    return search(q)


@app.get("/api/v1/market/quotes", dependencies=[Depends(auth)])
def market_quotes(symbols: str):
    from .market import quotes

    return quotes(symbols)


@app.get("/api/v1/calendar/hebrew", dependencies=[Depends(auth)])
def hebrew(
    year: int,
    latitude: float | None = None,
    longitude: float | None = None,
    timezone: str = "Asia/Jerusalem",
    israel: bool = True,
):
    import httpx

    if not 1900 <= year <= 2200:
        raise HTTPException(422, "Invalid year")
    params = {
        "v": 1,
        "cfg": "json",
        "year": year,
        "maj": "on",
        "min": "on",
        "mod": "on",
        "nx": "on",
        "ss": "on",
        "mf": "on",
        "s": "on",
        "o": "on",
        "i": "on" if israel else "off",
    }
    if latitude is not None and longitude is not None:
        if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
            raise HTTPException(422, "Invalid coordinates")
        params.update(
            {
                "geo": "pos",
                "latitude": latitude,
                "longitude": longitude,
                "tzid": timezone,
                "c": "on",
            }
        )
    key = json.dumps(params, sort_keys=True)
    with Session() as db:
        cached = db.get(Cache, key)
        if cached and cached.expires > time.time():
            return json.loads(cached.body)
    try:
        response = httpx.get("https://www.hebcal.com/hebcal", params=params, timeout=15)
        response.raise_for_status()
        body = response.json()
    except Exception:
        if cached:
            return json.loads(cached.body)
        raise HTTPException(503, "Hebrew calendar unavailable offline")
    with Session.begin() as db:
        db.merge(
            Cache(key=key, body=json.dumps(body), expires=time.time() + 86400 * 30)
        )
    return body


@app.delete("/api/v1/files/{ident}", dependencies=[Depends(auth)])
def purge_file(ident: uuid.UUID, confirm: bool = False):
    with Session.begin() as db:
        lock(db)
        row = db.get(Record, str(ident))
        if not row or row.kind not in {"files", "folders"}:
            raise HTTPException(404)
        if not row.deleted:
            raise HTTPException(409, "Move to trash first")
        attachments = [
            r
            for r in db.scalars(
                select(Record).where(
                    Record.kind.in_(
                        ["task_attachments", "note_attachments", "reminder_attachments"]
                    ),
                    Record.deleted == False,
                )
            )
            if json.loads(r.body).get("fileID") == str(ident)
        ]
        if attachments and not confirm:
            raise HTTPException(
                409, "File is attached to other items; explicit confirmation required"
            )
        children = [
            r
            for r in db.scalars(
                select(Record).where(Record.kind.in_(["files", "folders"]))
            )
            if json.loads(r.body).get("parent") == str(ident)
            and json.loads(r.body).get("purged") != "true"
        ]
        if children:
            raise HTTPException(409, "Empty the folder before permanent deletion")
        versions = list(
            db.scalars(select(Version).where(Version.file_id == str(ident)))
        )
        for version in versions:
            # Remove references transactionally; orphan cleanup removes bytes after commit.
            db.delete(version)
        body = json.loads(row.body)
        body["purged"] = "true"
        row.body = json.dumps(body)
        row.revision += 1
        db.add(Change(body=json.dumps(encoded(row))))
    return {"ok": True}


@app.get("/api/v1/calendar/zmanim", dependencies=[Depends(auth)])
def zmanim(
    date: str, latitude: float, longitude: float, timezone: str = "Asia/Jerusalem"
):
    from datetime import date as Date
    from .market import cached
    import httpx

    try:
        Date.fromisoformat(date)
    except ValueError:
        raise HTTPException(422, "Invalid date")
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise HTTPException(422, "Invalid coordinates")

    def fetch():
        response = httpx.get(
            "https://www.hebcal.com/zmanim",
            params={
                "cfg": "json",
                "date": date,
                "latitude": latitude,
                "longitude": longitude,
                "tzid": timezone,
            },
            timeout=15,
        )
        response.raise_for_status()
        return response.json()

    return cached(
        "zmanim:" + json.dumps([date, latitude, longitude, timezone]), 86400, fetch
    )


@app.get("/api/v1/rss/feeds", dependencies=[Depends(auth)])
def rss_feeds():
    from .reader import feeds

    return feeds()


@app.get("/api/v1/weather", dependencies=[Depends(auth)])
def local_weather(latitude: float, longitude: float, timezone: str = "Asia/Jerusalem"):
    from .reader import weather

    return weather(latitude, longitude, timezone)
