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


@pytest.mark.parametrize("language", ["en", "he", "fr", "ru", "es"])
def test_language_setting_sync_roundtrip(client, language):
    h = headers(client)
    body = {"language": language}
    m = mutation(kind="user_settings", body=body)
    m["id"] = "00000000-0000-0000-0000-000000000001"
    response = client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]})
    assert response.status_code == 200
    assert (
        client.get("/api/v1/sync/pull", headers=h).json()["changes"][0]["body"] == body
    )


def test_unsupported_language_rejected(client):
    h = headers(client)
    m = mutation(kind="user_settings", body={"language": "xx"})
    assert (
        client.post("/api/v1/sync/push", headers=h, json={"mutations": [m]}).status_code
        == 422
    )


def test_all_content_and_complete_settings_persist_in_backend(client):
    from app.main import KINDS
    from app.db import Record

    h = headers(client)
    settings = {
        "language": "he",
        "clocks": "Asia/Jerusalem,Europe/Paris,America/New_York",
        "city": "Jerusalem",
        "latitude": "31.78",
        "longitude": "35.23",
        "timezone": "Asia/Jerusalem",
        "israel": "true",
        "rssFeeds": json.dumps(
            [{"id": "news", "title": "News", "url": "https://example.com/feed"}]
        ),
        "shabbatRefreshSeconds": "300",
        "shabbatStocks": '["stock-id"]',
        "selectedCalendars": '["work-calendar", "home-calendar"]',
        "agendaRange": "Week",
    }
    mutations = []
    for kind in sorted(KINDS - {"crm_contacts", "crm_actions", "crm_attachments"}):
        body = (
            settings
            if kind == "user_settings"
            else {
                "title": "Test content",
                "description": "שלום",
                "text": "Full body",
                "status": "Done" if kind == "tasks" else "To do",
                "archived": "true" if kind == "tasks" else "false",
            }
        )
        if kind == "notes":
            body.update(
                {
                    "format": "rtf",
                    "rtf": "e1xydGYxIEhlbGxvfQ==",
                    "rtfd": "opaque-image-bearing-data",
                }
            )
        if kind.endswith("_attachments"):
            body.update({"ownerID": str(uuid.uuid4()), "fileID": str(uuid.uuid4())})
        mutations.append(mutation(kind=kind, body=body))
    contact = crm_contact()
    action = mutation(
        kind="crm_actions",
        body={
            "title": "Call",
            "contactID": contact["id"],
            "actionType": "Phone call",
            "date": "2026-10-20T10:00:00Z",
        },
    )
    file = next(m for m in mutations if m["kind"] == "files")
    mutations.extend(
        [
            contact,
            action,
            mutation(
                kind="crm_attachments",
                body={
                    "ownerID": action["id"],
                    "fileID": file["id"],
                },
            ),
        ]
    )
    response = client.post(
        "/api/v1/sync/push", headers=h, json={"mutations": mutations}
    )
    assert response.status_code == 200
    assert all(result["status"] == "applied" for result in response.json()["results"])
    # Verify database persistence independently of the push response.
    with Session() as db:
        for change in mutations:
            saved = db.get(Record, change["id"])
            assert saved is not None
            assert saved.kind == change["kind"]
            assert json.loads(saved.body) == change["body"]
    assert client.post("/api/v1/auth/logout", headers=h).status_code == 200
    h = headers(client)
    changes = client.get("/api/v1/sync/pull", headers=h).json()["changes"]
    assert {change["kind"] for change in changes} == KINDS
    assert (
        next(change["body"] for change in changes if change["kind"] == "user_settings")
        == settings
    )


def crm_contact(**body):
    return mutation(
        kind="crm_contacts",
        body={
            "title": "Acme שלום",
            "identityType": "Company",
            "contactType": "Client",
            "emails": "hello@example.com\nbilling@example.com",
            "mobiles": "+972501234567",
            "addresses": "1 Main Street, Tel Aviv\n2 Rue Exemple, Paris",
            **body,
        },
    )


def test_crm_round_trip_documents_actions_reminders(client):
    h = headers(client)
    contact = crm_contact(
        format="rtf",
        text="Contact note with image",
        rtf="e1xydGYxIEhlbGxvfQ==",
        rtfd="opaque-image-bearing-data",
    )
    action = mutation(
        kind="crm_actions",
        body={
            "title": "Invoice follow-up",
            "contactID": contact["id"],
            "actionType": "Invoice sent",
            "description": "Discuss payment schedule",
            "date": "2026-10-20T10:00:00Z",
            "reminderDate": "2026-10-21T10:00:00Z",
        },
    )
    file = mutation(kind="files", body={"title": "invoice.pdf", "parent": ""})
    links = [
        mutation(
            kind="crm_attachments", body={"ownerID": owner["id"], "fileID": file["id"]}
        )
        for owner in (contact, action)
    ]
    reminder = mutation(
        kind="reminders",
        body={
            "title": action["body"]["title"],
            "actionID": action["id"],
            "contactID": contact["id"],
            "date": "2026-10-21T10:00:00Z",
            "recurrence": "Once",
        },
    )
    records = [contact, action, file, *links, reminder]
    result = client.post("/api/v1/sync/push", headers=h, json={"mutations": records})
    assert result.status_code == 200, result.text
    assert all(r["status"] == "applied" for r in result.json()["results"])
    pulled = client.get("/api/v1/sync/pull", headers=h).json()["changes"]
    assert {r["id"] for r in pulled} == {r["id"] for r in records}
    for sent in records:
        assert next(r for r in pulled if r["id"] == sent["id"])["body"] == sent["body"]
    updated = {
        **contact,
        "operationID": str(uuid.uuid4()),
        "expectedRevision": 1,
        "body": {**contact["body"], "contactType": "Provider"},
    }
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [updated]}
        ).json()["results"][0]["record"]["revision"]
        == 2
    )
    stale = {**contact, "operationID": str(uuid.uuid4()), "expectedRevision": 1}
    assert (
        client.post("/api/v1/sync/push", headers=h, json={"mutations": [stale]}).json()[
            "results"
        ][0]["status"]
        == "conflict"
    )
    tombstones = [
        {
            **r,
            "operationID": str(uuid.uuid4()),
            "expectedRevision": 2 if r is contact else 1,
            "deleted": True,
        }
        for r in reversed(records)
    ]
    result = client.post("/api/v1/sync/push", headers=h, json={"mutations": tombstones})
    assert result.status_code == 200
    assert all(r["record"]["deleted"] for r in result.json()["results"])


@pytest.mark.parametrize(
    "body",
    [
        {"title": " "},
        {"contactType": "Invalid"},
        {"identityType": "Invalid"},
        {"mobiles": "0501234567"},
    ],
)
def test_crm_rejects_invalid_contact(client, body):
    result = client.post(
        "/api/v1/sync/push",
        headers=headers(client),
        json={"mutations": [crm_contact(**body)]},
    )
    assert result.status_code == 422


def test_crm_rejects_dangling_references_and_bad_dates(client):
    h = headers(client)
    action = mutation(
        kind="crm_actions",
        body={
            "title": "Call",
            "contactID": str(uuid.uuid4()),
            "actionType": "Phone call",
            "date": "2026-10-20T10:00:00Z",
        },
    )
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [action]}
        ).status_code
        == 422
    )
    contact = crm_contact()
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [contact]}
        ).status_code
        == 200
    )
    action["body"]["contactID"] = contact["id"]
    for key, value in [
        ("actionType", "Other"),
        ("date", "yesterday"),
        ("reminderDate", "2026-10-21"),
    ]:
        invalid = {**action, "body": {**action["body"], key: value}}
        assert (
            client.post(
                "/api/v1/sync/push", headers=h, json={"mutations": [invalid]}
            ).status_code
            == 422
        )
    link = mutation(
        kind="crm_attachments",
        body={"ownerID": contact["id"], "fileID": str(uuid.uuid4())},
    )
    assert (
        client.post(
            "/api/v1/sync/push", headers=h, json={"mutations": [link]}
        ).status_code
        == 422
    )
