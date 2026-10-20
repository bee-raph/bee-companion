import argparse, fcntl, getpass, hashlib, json, os, shutil, subprocess, tarfile, tempfile, time
from pathlib import Path
from sqlalchemy import select, text, delete
from argon2 import PasswordHasher
from .db import Session, Owner, Token, Version, secret, engine


def pg_env():
    u = engine.url
    return {
        **os.environ,
        "PGPASSWORD": secret("DB_PASSWORD"),
        "PGHOST": u.host or "db",
        "PGUSER": u.username or "companion",
        "PGDATABASE": u.database or "companion",
    }


def backup():
    destination = Path(os.getenv("BACKUPS_ROOT", "./backups"))
    destination.mkdir(parents=True, exist_ok=True)
    # Backup jobs serialize separately from record and upload mutations.
    with (destination / ".backup.lock").open("a") as backup_lock:
        fcntl.flock(backup_lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(dir=destination) as temporary:
            work = Path(temporary)
            objects = work / "objects"
            objects.mkdir()
            manifest = {
                "schemaVersion": 1,
                "instanceID": os.getenv("INSTANCE_ID"),
                "created": time.time(),
                "files": {},
            }
            with Session.begin() as db:
                if engine.dialect.name == "postgresql":
                    db.execute(text("SELECT pg_advisory_xact_lock(731927)"))
                subprocess.run(
                    ["pg_dump", "-Fc", "-f", str(work / "database.dump")],
                    env=pg_env(),
                    check=True,
                )
                for version in db.scalars(select(Version)):
                    source = Path(os.getenv("FILES_ROOT", "./files")) / version.id
                    target = objects / version.id
                    try:
                        os.link(source, target)
                    except OSError:
                        shutil.copyfile(source, target)
                    manifest["files"][version.id] = version.checksum
            # Pinned immutable objects remain available if orphan cleanup unlinks their originals.
            for ident, expected in manifest["files"].items():
                with (objects / ident).open("rb") as stream:
                    checksum = hashlib.file_digest(stream, "sha256").hexdigest()
                if checksum != expected:
                    raise RuntimeError("Stored object checksum mismatch: " + ident)
            with (work / "database.dump").open("rb") as stream:
                manifest["databaseChecksum"] = hashlib.file_digest(
                    stream, "sha256"
                ).hexdigest()
            (work / "manifest.json").write_text(json.dumps(manifest, indent=2))
            name = time.strftime("companion-%Y%m%d-%H%M%S") + ".tar.gz"
            partial = destination / (name + ".partial")
            with tarfile.open(partial, "w:gz") as archive:
                for item in work.iterdir():
                    archive.add(item, arcname=item.name)
            partial.rename(destination / name)
    print(destination / name)
    return destination / name


def restore(path):
    with tempfile.TemporaryDirectory() as temporary:
        with tarfile.open(path, "r:gz") as archive:
            for member in archive.getmembers():
                parts = Path(member.name).parts
                allowed = member.name in {"manifest.json", "database.dump"} or (
                    len(parts) == 2 and parts[0] == "objects"
                )
                if member.isdir() and member.name == "objects":
                    continue
                if not allowed or not member.isfile():
                    raise RuntimeError("Unsafe backup member")
                if len(parts) == 2:
                    import uuid

                    uuid.UUID(parts[1])
                destination = Path(temporary) / member.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, destination.open(
                    "wb"
                ) as output:
                    shutil.copyfileobj(source, output)
        work = Path(temporary)
        manifest = json.loads((work / "manifest.json").read_text())
        if manifest["schemaVersion"] != 1:
            raise RuntimeError("Unsupported backup version")
        if "databaseChecksum" in manifest:
            with (work / "database.dump").open("rb") as stream:
                if (
                    hashlib.file_digest(stream, "sha256").hexdigest()
                    != manifest["databaseChecksum"]
                ):
                    raise RuntimeError("Invalid database checksum")
        for ident, checksum in manifest["files"].items():
            import uuid

            uuid.UUID(ident)
            with (work / "objects" / ident).open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                    raise RuntimeError("Invalid backup checksum")
        subprocess.run(
            [
                "pg_restore",
                "--clean",
                "--if-exists",
                "--no-owner",
                "--single-transaction",
                "-d",
                pg_env()["PGDATABASE"],
                str(work / "database.dump"),
            ],
            env=pg_env(),
            check=True,
        )
        target = Path(os.getenv("FILES_ROOT", "./files"))
        target.mkdir(parents=True, exist_ok=True)
        for ident in manifest["files"]:
            shutil.copyfile(work / "objects" / ident, target / ident)
    with Session.begin() as db:
        db.execute(delete(Token))
    print("Restore complete; sessions revoked. Sign in again.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command", choices=["owner", "reset-password", "backup", "restore"]
    )
    parser.add_argument("--login")
    parser.add_argument("--archive")
    args = parser.parse_args()
    if args.command == "backup":
        backup()
        return
    if args.command == "restore":
        restore(args.archive)
        return
    if args.command == "owner":
        with Session() as db:
            if db.get(Owner, 1):
                print("Owner already exists")
                return
    password = getpass.getpass("Owner password: ")
    if len(password) < 12:
        raise SystemExit("Use at least 12 characters")
    with Session.begin() as db:
        owner = db.get(Owner, 1)
        if args.command == "owner" and owner:
            print("Owner already exists")
            return
        if not owner:
            if not args.login:
                raise SystemExit("--login is required")
            owner = Owner(id=1, login=args.login)
            db.add(owner)
        owner.password = PasswordHasher().hash(password)
        db.execute(delete(Token))


if __name__ == "__main__":
    main()
