import hashlib, json, os, tempfile, uuid
from pathlib import Path

os.environ["DATABASE_URL"] = "sqlite:///" + tempfile.mktemp(suffix=".sqlite")
os.environ["FILES_ROOT"] = tempfile.mkdtemp()
from fastapi.testclient import TestClient
from app.main import app, ph, attempts
from app.db import Base, engine, Session, Owner
import pytest


@pytest.fixture(autouse=True)
def reset():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    attempts.clear()
    with Session.begin() as db:
        db.add(Owner(id=1, login="owner", password=ph.hash("correct horse battery")))


@pytest.fixture
def client():
    return TestClient(app)


def headers(c):
    result = c.post(
        "/api/v1/auth/login",
        json={"login": "owner", "password": "correct horse battery"},
    )
    assert result.status_code == 200
    return {"Authorization": "Bearer " + result.json()["accessToken"]}


def mutation(**kw):
    return {
        "operationID": str(uuid.uuid4()),
        "id": str(uuid.uuid4()),
        "kind": "tasks",
        "expectedRevision": 0,
        "body": {"title": "שלום"},
        **kw,
    }


def test_auth_and_rotation(client):
    assert client.get("/api/v1/sync/pull").status_code == 401
    assert (
        client.post(
            "/api/v1/auth/login", json={"login": "other", "password": "wrong"}
        ).status_code
        == 401
    )
    session = client.post(
        "/api/v1/auth/login",
        json={"login": "owner", "password": "correct horse battery"},
    ).json()
    response = client.post(
        "/api/v1/auth/refresh", json={"token": session["refreshToken"]}
    )
    assert response.status_code == 200
    assert (
        client.post(
            "/api/v1/auth/refresh", json={"token": session["refreshToken"]}
        ).status_code
        == 401
    )
    assert (
        client.get(
            "/api/v1/sync/pull",
            headers={"Authorization": "Bearer " + session["accessToken"]},
        ).status_code
        == 401
    )


def test_mutation_retry_and_conflict(client):
    h = headers(client)
    m = mutation()
    a = client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]}).json()
    assert a["results"][0]["record"]["revision"] == 1
    assert (
        client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]}).json() == a
    )
    conflict = client.post(
        "/api/v1/sync/push",
        headers=h,
        json={"mutations": [{**m, "operationID": str(uuid.uuid4())}]},
    ).json()
    assert conflict["results"][0]["status"] == "conflict"
    page = client.get("/api/v1/sync/pull", headers=h).json()
    assert len(page["changes"]) == 1
    assert page["changes"][0]["body"]["title"] == "שלום"
    assert (
        client.get(
            "/api/v1/sync/pull", headers=h, params={"cursor": page["cursor"]}
        ).json()["changes"]
        == []
    )


def test_invalid_kind_and_identity(client):
    h = headers(client)
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [mutation(kind="owner")]}
        ).status_code
        == 422
    )
    m = mutation()
    client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]})
    assert (
        client.post(
            "/api/v1/sync/push",
            headers=h,
            json={
                "mutations": [
                    {
                        **m,
                        "operationID": str(uuid.uuid4()),
                        "kind": "notes",
                        "expectedRevision": 1,
                    }
                ]
            },
        ).status_code
        == 409
    )


def test_resume_checksum_and_download(client):
    h = headers(client)
    data = "attachment שלום".encode()
    fid = str(uuid.uuid4())
    start = client.post(
        "/api/v1/files/uploads",
        headers=h,
        json={
            "fileID": fid,
            "size": len(data),
            "checksum": hashlib.sha256(data).hexdigest(),
        },
    ).json()["id"]
    assert (
        client.put(
            f"/api/v1/files/uploads/{start}?offset=0", headers=h, content=data[:3]
        ).json()["offset"]
        == 3
    )
    assert (
        client.post(f"/api/v1/files/uploads/{start}/complete", headers=h).status_code
        == 409
    )
    assert (
        client.put(
            f"/api/v1/files/uploads/{start}?offset=0", headers=h, content=data
        ).status_code
        == 409
    )
    assert (
        client.put(
            f"/api/v1/files/uploads/{start}?offset=3", headers=h, content=data[3:]
        ).status_code
        == 200
    )
    assert (
        client.post(f"/api/v1/files/uploads/{start}/complete", headers=h).status_code
        == 200
    )
    assert (
        client.post(f"/api/v1/files/uploads/{start}/complete", headers=h).status_code
        == 200
    )
    assert client.get(f"/api/v1/files/{fid}/content", headers=h).content == data
    assert client.get(f"/api/v1/files/{fid}/content").status_code == 401
    assert client.get("/api/v1/files/not-a-uuid/content", headers=h).status_code == 422


def test_checksum_failure(client):
    h = headers(client)
    ident = client.post(
        "/api/v1/files/uploads",
        headers=h,
        json={"fileID": str(uuid.uuid4()), "size": 1, "checksum": "0" * 64},
    ).json()["id"]
    client.put(f"/api/v1/files/uploads/{ident}?offset=0", headers=h, content=b"a")
    assert (
        client.post(f"/api/v1/files/uploads/{ident}/complete", headers=h).status_code
        == 422
    )
    assert (
        client.get(f"/api/v1/files/uploads/{ident}", headers=h).json()["complete"]
        == False
    )


def test_login_throttle(client):
    for _ in range(5):
        assert (
            client.post(
                "/api/v1/auth/login", json={"login": "owner", "password": "wrong"}
            ).status_code
            == 401
        )
    assert (
        client.post(
            "/api/v1/auth/login", json={"login": "owner", "password": "wrong"}
        ).status_code
        == 429
    )


def test_folder_cycles_and_permanent_delete(client):
    h = headers(client)
    folder = mutation(kind="folders", body={"title": "Folder"})
    r = client.post("/api/v1/sync/push", headers=h, json={"mutations": [folder]})
    assert r.status_code == 200
    cycle = {
        **folder,
        "operationID": str(uuid.uuid4()),
        "expectedRevision": 1,
        "body": {"title": "Folder", "parent": folder["id"]},
    }
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [cycle]}
        ).status_code
        == 422
    )
    file = mutation(kind="files", body={"title": "File", "parent": folder["id"]})
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [file]}
        ).status_code
        == 200
    )
    for item in [file, folder]:
        item.update(operationID=str(uuid.uuid4()), expectedRevision=1, deleted=True)
        assert (
            client.post(
                "/api/v1/sync/push", headers=h, json={"mutations": [item]}
            ).status_code
            == 200
        )
    assert client.delete("/api/v1/files/" + folder["id"], headers=h).status_code == 409
    assert client.delete("/api/v1/files/" + file["id"], headers=h).status_code == 200
    assert client.delete("/api/v1/files/" + folder["id"], headers=h).status_code == 200


def test_path_names_rejected(client):
    h = headers(client)
    for name in ["../secret", "..", "/tmp", "folder/file"]:
        assert (
            client.post(
                "/api/v1/sync/push",
                headers=h,
                json={"mutations": [mutation(kind="files", body={"title": name})]},
            ).status_code
            == 422
        )


def test_reader_settings_sync_and_limit(client):
    h = headers(client)
    body = {
        "rssFeeds": json.dumps(
            [{"id": "feed", "title": "News", "url": "https://example.com/feed"}]
        ),
        "shabbatRefreshSeconds": "300",
        "shabbatStocks": "[]",
    }
    m = mutation(kind="user_settings", body=body)
    r = client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]})
    assert r.status_code == 200
    assert (
        client.get("/api/v1/sync/pull", headers=h).json()["changes"][0]["body"] == body
    )
    m = mutation(
        kind="user_settings",
        body={
            "rssFeeds": json.dumps(
                [{"id": str(i), "url": "https://example.com/feed"} for i in range(4)]
            )
        },
    )
    assert (
        client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]}).status_code
        == 422
    )
    assert client.get("/api/v1/rss/feeds").status_code == 401
    assert client.get("/api/v1/weather?latitude=0&longitude=0").status_code == 401
