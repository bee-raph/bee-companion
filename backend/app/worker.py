import logging, os, time
from pathlib import Path
from sqlalchemy import select
from .db import Session, Job, Version, Upload, engine
from sqlalchemy import text
from .maintenance import backup

logging.basicConfig(level=logging.INFO)


def retain():
    archives = sorted(
        Path(os.getenv("BACKUPS_ROOT", "/backups")).glob("companion-*.tar.gz"),
        reverse=True,
    )
    keep = set(archives[:7])
    weeks = set()
    for path in archives:
        stamp = time.strptime(path.name, "companion-%Y%m%d-%H%M%S.tar.gz")
        week = time.strftime("%G-%V", stamp)
        if week not in weeks and len(weeks) < 4:
            keep.add(path)
            weeks.add(week)
    for path in archives:
        if path not in keep:
            path.unlink()


def cleanup():
    root = Path(os.getenv("FILES_ROOT", "/files"))
    with Session.begin() as db:
        if engine.dialect.name == "postgresql":
            db.execute(text("SELECT pg_advisory_xact_lock(731927)"))
        referenced = set(db.scalars(select(Version.id)))
        active = set(db.scalars(select(Upload.id).where(Upload.complete == False)))
        for path in root.iterdir():
            if (
                path.is_file()
                and path.name not in referenced
                and path.stem not in active
                and path.stat().st_mtime < time.time() - 86400
            ):
                path.unlink()


def run_once():
    with Session.begin() as db:
        job = db.scalar(
            select(Job)
            .where(Job.due <= time.time())
            .with_for_update(skip_locked=True)
            .limit(1)
        )
        if job:
            try:
                if job.kind != "backup":
                    raise ValueError("Unknown job")
                backup()
                retain()
                job.due = time.time() + 86400
                job.attempts = 0
            except Exception:
                logging.exception("Job failed")
                job.attempts += 1
                job.due = time.time() + min(3600, 60 * 2 ** min(job.attempts, 6))
        elif not db.scalar(select(Job).where(Job.kind == "backup")):
            db.add(Job(kind="backup", due=time.time() + 86400))


if __name__ == "__main__":
    while True:
        try:
            run_once()
            cleanup()
        except Exception:
            logging.exception("Worker iteration failed")
        time.sleep(30)
