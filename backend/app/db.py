import os, uuid
from pathlib import Path
from sqlalchemy import create_engine, Column, String, Integer, Text, Float, Boolean
from sqlalchemy.orm import DeclarativeBase, sessionmaker


def secret(name, default=""):
    path = os.getenv(name + "_FILE")
    return Path(path).read_text().strip() if path else os.getenv(name, default)


url = os.getenv("DATABASE_URL", "sqlite:///./companion.db")
if "{password}" in url:
    from urllib.parse import quote

    url = url.replace("{password}", quote(secret("DB_PASSWORD"), safe=""))
engine = create_engine(
    url,
    **(
        {"connect_args": {"check_same_thread": False}}
        if url.startswith("sqlite")
        else {}
    )
)
Session = sessionmaker(engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class Owner(Base):
    __tablename__ = "owner"
    id = Column(Integer, primary_key=True, default=1)
    login = Column(String, nullable=False)
    password = Column(String, nullable=False)


class Token(Base):
    __tablename__ = "sessions"
    hash = Column(String, primary_key=True)
    family = Column(String, nullable=False)
    kind = Column(String, nullable=False)
    expires = Column(Float, nullable=False)


class Record(Base):
    __tablename__ = "records"
    id = Column(String, primary_key=True)
    kind = Column(String, nullable=False)
    revision = Column(Integer, nullable=False)
    body = Column(Text, nullable=False)
    deleted = Column(Boolean, default=False)


class Change(Base):
    __tablename__ = "change_log"
    sequence = Column(Integer, primary_key=True, autoincrement=True)
    body = Column(Text, nullable=False)


class Receipt(Base):
    __tablename__ = "mutation_receipts"
    id = Column(String, primary_key=True)
    body = Column(Text, nullable=False)


class Upload(Base):
    __tablename__ = "upload_sessions"
    id = Column(String, primary_key=True)
    file_id = Column(String, nullable=False)
    size = Column(Integer, nullable=False)
    checksum = Column(String, nullable=False)
    offset = Column(Integer, default=0)
    complete = Column(Boolean, default=False)


class Version(Base):
    __tablename__ = "file_versions"
    id = Column(String, primary_key=True)
    file_id = Column(String, nullable=False)
    checksum = Column(String, nullable=False)
    size = Column(Integer, nullable=False)
    created = Column(Float, nullable=False)


class Job(Base):
    __tablename__ = "jobs"
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    kind = Column(String, nullable=False)
    due = Column(Float, nullable=False)
    attempts = Column(Integer, default=0)


class Cache(Base):
    __tablename__ = "provider_cache"
    key = Column(String, primary_key=True)
    body = Column(Text, nullable=False)
    expires = Column(Float, nullable=False)
