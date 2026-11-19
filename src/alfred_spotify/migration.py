"""One-time import from a previous bundle, without overwriting newer data."""

import contextlib
import os
import shutil
import sqlite3
import tempfile
import time
from pathlib import Path

from .configuration import SEED, values
from .storage import Store, cache_dir, data_dir, lock, read_json, write_json

LEGACY_BUNDLE_IDS = ("com.aqsnow.alfred-spotify", "io.nhooyr.alfred-spotify")
MARKER = ".legacy-import.json"


def copy_missing(source, destination):
    """Publish a complete private file atomically, only if it does not exist."""
    if source.is_symlink() or not source.is_file() or destination.exists():
        return False
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".import-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as stream:
            shutil.copyfileobj(stream, output)
        try:
            os.link(temporary, destination)
        except FileExistsError:
            return False
        return True
    finally:
        Path(temporary).unlink(missing_ok=True)


def import_database(source, destination, reuse_account):
    """Snapshot a possibly open SQLite database, then merge missing records."""
    if source.is_symlink() or not source.is_file():
        return {}
    fd, temporary = tempfile.mkstemp(prefix=".legacy-index-", dir=destination.parent)
    os.close(fd)
    snapshot = Path(temporary)
    store = None
    try:
        deadline = time.monotonic() + 15

        def progress(status, remaining, total):
            if time.monotonic() > deadline:
                raise TimeoutError("The old cache is busy; migration will retry on the next open.")

        with contextlib.closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as old:
            with contextlib.closing(sqlite3.connect(snapshot)) as backup:
                old.backup(backup, pages=256, progress=progress, sleep=0.01)
        store = Store(destination)
        store.db.execute("ATTACH DATABASE ? AS legacy", (str(snapshot),))
        store.db.execute("BEGIN IMMEDIATE")
        copied = {}
        tables = [
            (
                "items",
                "uri, kind, name, payload, richness",
                "" if reuse_account else " WHERE kind != 'playlist'",
            ),
            ("desktop", "path, stamp, url, offset, length", ""),
            (
                "responses",
                "key, payload, expires",
                "" if reuse_account else " WHERE key='desktop:scanned'",
            ),
        ]
        if reuse_account:
            tables.append(("saved", "uri", ""))
        for table, columns, condition in tables:
            before = store.db.total_changes
            store.db.execute(
                f"INSERT OR IGNORE INTO main.{table} ({columns}) "
                f"SELECT {columns} FROM legacy.{table}{condition}"
            )
            copied[table] = store.db.total_changes - before
        store.commit()
        return copied
    finally:
        if store:
            store.close()
        snapshot.unlink(missing_ok=True)


def migrate(data_target=None, cache_target=None):
    data_target = Path(data_target) if data_target is not None else data_dir()
    cache_target = Path(cache_target) if cache_target is not None else cache_dir()
    report = {
        "authorization": False,
        "credentials": False,
        "artwork": 0,
        "records": {},
        "errors": [],
    }
    # The newest source owns account state, including a deliberately cleared connection.
    source_id = next(
        (
            bundle_id
            for bundle_id in LEGACY_BUNDLE_IDS
            if (data_target.parent / bundle_id).is_dir()
            or (cache_target.parent / bundle_id).is_dir()
        ),
        None,
    )
    if source_id is None:
        return report
    data_source = data_target.parent / source_id
    cache_source = cache_target.parent / source_id
    report["source"] = source_id
    data_target.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache_target.mkdir(parents=True, exist_ok=True, mode=0o700)
    with lock(data_target / ".legacy-import.lock"):
        previous = read_json(data_target / MARKER, {})
        if previous:
            return {**previous, "already_imported": True}
        try:
            old_credentials = data_source / SEED
            if not old_credentials.is_symlink() and all(values(read_json(old_credentials, {}))):
                report["credentials"] = copy_missing(old_credentials, data_target / SEED)
            with lock(data_target / "authorization.lock"):
                old_auth_path = data_source / "authorization.json"
                old_auth = read_json(old_auth_path, {}) if not old_auth_path.is_symlink() else {}
                new_auth = read_json(data_target / "authorization.json", {})
                cleared = (data_target / "authorization-generation.json").exists()
                valid = all(
                    isinstance(old_auth.get(k), str) and old_auth[k]
                    for k in ("client_id", "access_token", "refresh_token")
                )
                if valid and not new_auth and not cleared:
                    report["authorization"] = copy_missing(
                        old_auth_path, data_target / "authorization.json"
                    )
                if not new_auth and not cleared:
                    copy_missing(
                        data_source / "authorization-generation.json",
                        data_target / "authorization-generation.json",
                    )
                reuse_account = bool(report["authorization"] or (valid and new_auth == old_auth))
            report["records"] = import_database(
                cache_source / "index.sqlite3", cache_target / "index.sqlite3", reuse_account
            )
            artwork = cache_source / "artwork"
            if artwork.is_dir() and not artwork.is_symlink():
                for source in artwork.glob("*.img"):
                    report["artwork"] += int(
                        copy_missing(source, cache_target / "artwork" / source.name)
                    )
            # Never copy sessions, process locks, or an old pending sign-in.
            write_json(data_target / MARKER, report)
        except (OSError, sqlite3.Error, TimeoutError) as error:
            report["errors"].append(str(error))
    return report
