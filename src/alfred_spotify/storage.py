"""Small private index; Spotify's caches are always opened read-only."""

import contextlib
import fcntl
import json
import os
import sqlite3
import tempfile
import time
from pathlib import Path

BUNDLE_ID = "ca.aqsnow.alfred.spotify"


def data_dir():
    path = Path(
        os.environ.get("alfred_workflow_data")
        or (Path.home() / "Library/Application Support/Alfred/Workflow Data" / BUNDLE_ID)
    )
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def cache_dir():
    path = Path(
        os.environ.get("alfred_workflow_cache")
        or (Path.home() / "Library/Caches/com.runningwithcrayons.Alfred/Workflow Data" / BUNDLE_ID)
    )
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def read_json(path, default=None):
    try:
        value = json.loads(path.read_text())
        if isinstance(default, dict) and not isinstance(value, dict):
            return default
        return value
    except OSError, ValueError:
        return default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def authorization_generation():
    return read_json(data_dir() / "authorization-generation.json", {}).get("id", "")


@contextlib.contextmanager
def lock(path, blocking=True):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a+") as stream:
        os.chmod(path, 0o600)
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


class Store:
    def __init__(self, path=None):
        path = path or cache_dir() / "index.sqlite3"
        self.db = sqlite3.connect(path, timeout=10)
        os.chmod(path, 0o600)
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS items (
                uri TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
                payload TEXT NOT NULL, richness INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS items_kind ON items(kind);
            CREATE TABLE IF NOT EXISTS saved (uri TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS responses (
                key TEXT PRIMARY KEY, payload TEXT NOT NULL, expires REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS desktop (
                path TEXT PRIMARY KEY, stamp INTEGER NOT NULL, url TEXT NOT NULL,
                offset INTEGER NOT NULL, length INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS desktop_url ON desktop(url);
        """)

    def close(self):
        self.db.close()

    def put_item(self, item):
        if not item or not item.get("uri") or not item.get("name"):
            return
        previous = self.item(item["uri"])
        if previous:
            item = previous | item
            for key in ("image", "tracks", "albums", "artists", "year"):
                if not item.get(key) and previous.get(key):
                    item[key] = previous[key]
        richness = len(item.get("tracks", [])) * 10 + len(item.get("albums", []))
        self.db.execute(
            """
            INSERT INTO items VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(uri) DO UPDATE SET kind=excluded.kind, name=excluded.name,
                payload=excluded.payload, richness=excluded.richness
            WHERE excluded.richness >= items.richness
        """,
            (item["uri"], item["kind"], item["name"], json.dumps(item), richness),
        )

    def item(self, uri):
        row = self.db.execute("SELECT payload FROM items WHERE uri=?", (uri,)).fetchone()
        return json.loads(row[0]) if row else None

    def items(self, kind=None, saved=False):
        query = "SELECT payload FROM items"
        if saved:
            query += " JOIN saved USING(uri)"
        args = ()
        if kind:
            query += " WHERE kind=?"
            args = (kind,)
        return [json.loads(row[0]) for row in self.db.execute(query, args)]

    def display_items(self):
        """Metadata needed by the browser, without nested album/playlist contents."""
        return [
            json.loads(row[0])
            for row in self.db.execute(
                "SELECT json_remove(payload, '$.tracks', '$.albums', '$.album.tracks', "
                "'$.album.albums') FROM items"
            )
        ]

    def get(self, key, stale=False):
        row = self.db.execute(
            "SELECT payload, expires FROM responses WHERE key=?", (key,)
        ).fetchone()
        if row and (stale or row[1] > time.time()):
            return json.loads(row[0])
        return None

    def put(self, key, value, ttl=3600):
        self.db.execute(
            "INSERT OR REPLACE INTO responses VALUES (?, ?, ?)",
            (key, json.dumps(value), time.time() + ttl),
        )
        self.db.commit()

    def commit(self):
        self.db.commit()
