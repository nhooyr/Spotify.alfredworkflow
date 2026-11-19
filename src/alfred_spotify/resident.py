"""Persistent library/authentication worker for the native player.

The native process owns filtering, drawing, and playback. This worker stays alive
and only handles library navigation, cache misses, and the Spotify sign-in flow.
"""

import hashlib
import json
import os
import queue
import signal
import sqlite3
import sys
import threading
import time

from . import controller, desktop
from .api import Spotify, SpotifyError, credentials
from .configuration import apply_imported_credentials
from .library import prioritize
from .likes import LikedSongs
from .migration import migrate
from .storage import Store, cache_dir, read_json


def native_row(item, artwork):
    url = item.get("image", "")
    path = artwork.get(hashlib.sha256(url.encode()).hexdigest(), "") if url else ""
    artists = ", ".join(a["name"] for a in item.get("artists", []))
    detail = item.get("detail", artists)
    if item.get("kind") == "track":
        detail = " · ".join(filter(None, [artists, item.get("album", {}).get("name", "")]))
    return {
        "item": {
            key: item[key]
            for key in (
                "uri",
                "name",
                "kind",
                "context",
                "action",
                "target",
                "play_uri",
                "query",
                "is_local",
                "is_playable",
            )
            if key in item
        },
        "name": item.get("name", ""),
        "uri": item.get("uri", ""),
        "kind": item.get("kind", ""),
        "detail": detail,
        "art": path,
        "symbol": item.get("symbol")
        or {
            "track": "music.note",
            "album": "square.stack",
            "artist": "person.fill",
            "playlist": "music.note.list",
        }.get(item.get("kind"), "music.note"),
        "match": " ".join([item.get("name", ""), artists, item.get("album", {}).get("name", "")]),
    }


class Backend:
    def __init__(self, emit):
        self.emit = emit
        self.store = Store()
        self.catalog_version = ""
        self.artwork = {}
        self.session = ""
        self.like_tasks = queue.Queue()
        self.like_results = queue.Queue()
        self.like_thread = None
        self.stopped = threading.Event()

    def close(self):
        self.stopped.set()
        self.like_tasks.put(None)
        if self.like_thread:
            self.like_thread.join(timeout=0.1)
        self.store.close()

    def start(self):
        self.publish(controller.init(self.store), "init")

    def state(self):
        return read_json(controller.session_path(self.session), {}) if self.session else {}

    def publish(self, result, command, request=None):
        variables = result.get("variables", {})
        self.session = variables.get("SPOTIFY_SESSION", self.session)
        for key in ("SPOTIFY_SESSION", "SPOTIFY_SEEN_ROWS", "SPOTIFY_SEEN_PREVIEW"):
            if key in variables:
                os.environ[key] = str(variables[key])
        state = self.state()
        if "browser_rows" in variables:
            self.artwork = {p.stem: str(p) for p in (cache_dir() / "artwork").glob("*.img")}
        message = {
            "type": "update",
            "command": command,
            "request": request,
            "connection": state.get("connection", "credentials"),
            "message": state.get("message", ""),
            "route_kind": state["stack"][-1]["kind"] if state.get("stack") else "home",
            "prefix": controller.prefix(state),
            "selected": state.get("selected", {}).get("uri", ""),
            "preview_complete": bool(state.get("preview_attempted")),
            "variables": {k: v for k, v in variables.items() if k != "browser_rows"},
        }
        if command == "reset":
            message["close_player"] = True
        if "browser_rows" in variables:
            # Read the original rows once; the AppKit table retains them in memory.
            message["rows"] = [native_row(item, self.artwork) for item in controller.rows_in(state)]
        search = result.get("update", {}).get("ids", {}).get("search", {})
        if "text" in search:
            message["search_text"] = search["text"]
        self.emit(message)
        self.send_catalog()

    def send_catalog(self):
        snapshot = self.store.get("search:snapshot")
        if not snapshot or snapshot["version"] == self.catalog_version:
            return
        rows = read_json(cache_dir() / "search" / (snapshot["version"] + ".rows.json"))
        if rows is None:
            return
        self.catalog_version = snapshot["version"]
        self.artwork = {p.stem: str(p) for p in (cache_dir() / "artwork").glob("*.img")}
        self.emit(
            {
                "type": "catalog",
                "rows": [native_row(item, self.artwork) for item in prioritize(rows)],
            }
        )

    def liked_action(self, message):
        """Runs off the navigation thread; each task owns its SQLite connection."""
        uri = (message.get("args") or [""])[0]
        saving = message.get("command") == "save"
        store = Store()
        likes = LikedSongs(store, Spotify())
        try:
            liked = likes.save(uri) if saving else likes.check(uri)
            self.like_results.put({"type": "liked", "uri": uri, "liked": liked, "saved": saving})
        except (SpotifyError, ValueError, OSError, sqlite3.Error) as error:
            self.like_results.put(
                {
                    "type": "liked",
                    "uri": uri,
                    "liked": likes.cached(uri),
                    "error": str(error) if saving else "",
                }
            )
        finally:
            store.close()

    def drain_likes(self):
        changed = False
        while True:
            try:
                result = self.like_results.get_nowait()
            except queue.Empty:
                break
            self.emit(result)
            changed |= result.get("saved", False)
        if changed and self.session:
            controller.warm_search(self.store)
            with controller.state_lock(controller.session_path(self.session)) as state:
                if state.get("connection") == "connected":
                    controller.set_rows(
                        state, controller.Library(self.store, Spotify()).browse(state["stack"][-1])
                    )
            self.publish(controller.handle("poll", [], self.store, include_playback=False), "liked")

    def queue_like(self, message):
        uri = (message.get("args") or [""])[0]
        LikedSongs.validate(uri)
        if message["command"] == "liked":
            self.emit(
                {
                    "type": "liked",
                    "uri": uri,
                    "liked": LikedSongs(self.store, Spotify()).cached(uri),
                    "cached": True,
                }
            )
        if self.like_thread is None:

            def work():
                while not self.stopped.is_set():
                    task = self.like_tasks.get()
                    if task is None:
                        return
                    self.liked_action(task)

            self.like_thread = threading.Thread(target=work, daemon=True)
            self.like_thread.start()
        self.like_tasks.put(message)

    def handle(self, message):
        self.drain_likes()
        command = message.get("command", "poll")
        if command in ("liked", "save"):
            self.queue_like(message)
            return
        if command == "image":
            url = (message.get("args") or [""])[0]

            def fetch():
                store = Store()
                try:
                    path = desktop.image(store, url, download=True)
                    self.emit({"type": "artwork", "url": url, "path": path or ""})
                finally:
                    store.close()

            threading.Thread(target=fetch, daemon=True).start()
            return
        if command == "reset":
            controller.clear_connection(self.store)
            result = controller.handle("poll", [], self.store, include_playback=False)
        elif command == "show":
            state = self.state()
            if state.get("connection") == "cleared" or (
                state.get("connection") == "connected" and not Spotify().connected()
            ):
                with controller.state_lock(controller.session_path(self.session)) as current:
                    try:
                        credentials(require_secret=False)
                    except SpotifyError:
                        current.update(
                            connection="credentials", message="Add your Client ID to continue"
                        )
                        controller.set_rows(current, controller.connection_rows(current))
                    else:
                        controller.begin_connection(current)
            result = controller.handle("poll", [], self.store, include_playback=False)
        else:
            args = message.get("args", [])
            result = controller.handle(command, args, self.store, include_playback=False)
        self.publish(result, command, message.get("request"))


def run():
    migrate()
    apply_imported_credentials()
    incoming = queue.Queue()
    stopped = threading.Event()
    output_lock = threading.Lock()

    def emit(message):
        with output_lock:
            print(json.dumps(message, ensure_ascii=False, separators=(",", ":")), flush=True)

    def read_commands():
        for line in sys.stdin:
            try:
                message = json.loads(line)
                if isinstance(message, dict):
                    incoming.put(message)
            except ValueError:
                emit({"type": "error", "message": "Invalid player request."})
        stopped.set()

    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    threading.Thread(target=read_commands, daemon=True).start()
    backend = Backend(emit)
    try:
        backend.start()
        next_poll = 0
        while not stopped.is_set():
            try:
                message = incoming.get(timeout=0.25)
            except queue.Empty:
                message = None
            if message is None and time.monotonic() >= next_poll:
                message = {"command": "poll"}
            if message is None:
                continue
            try:
                backend.handle(message)
            except (SpotifyError, ValueError, OSError, sqlite3.Error) as error:
                emit({"type": "error", "message": str(error), "request": message.get("request")})
            next_poll = time.monotonic() + 0.5
    finally:
        backend.close()
        for child in controller.CHILDREN:
            if child.poll() is None:
                child.terminate()
