"""Small command interface used by Alfred UI events and a background worker."""

import contextlib
import json
import os
import random
import re
import subprocess
import sys
import time
import uuid

from . import desktop, player
from .api import Spotify, SpotifyError, credentials
from .library import Library
from .storage import (
    BUNDLE_ID,
    Store,
    authorization_generation,
    cache_dir,
    data_dir,
    lock,
    read_json,
    write_json,
)


def spawn(*args):
    subprocess.Popen(
        [sys.executable, "-m", "alfred_spotify", *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def session_path(session=None):
    session = session or os.environ.get("SPOTIFY_SESSION", "")
    if not re.fullmatch(r"[a-f0-9]{32}", session):
        raise ValueError("Invalid player session")
    return cache_dir() / "sessions" / (session + ".json")


@contextlib.contextmanager
def state_lock(path):
    with lock(path.with_suffix(".lock")):
        state = read_json(path, {})
        yield state
        write_json(path, state)


def selected(payload):
    try:
        value = json.loads(payload) if payload else {}
    except ValueError:
        return {}
    return value.get("item", value) if isinstance(value, dict) else {}


def note(store):
    if Spotify().connected() and store.get("library:synced", stale=True):
        return ""
    try:
        credentials()
    except SpotifyError:
        return "Connect Spotify to browse your playlists"
    return "Connect Spotify to browse your saved library"


def rows_for(state, store):
    if state.get("connection") != "connected":
        return connection_rows(state)
    route = state["stack"][-1] if state["stack"] else {"kind": "home"}
    return Library(store, Spotify()).browse(route, state.get("query", ""))


def connection_rows(state):
    from .library import action_row

    title = {
        "credentials": "Set up Spotify",
        "connecting": "Connecting to Spotify…",
        "failed": "Retry Spotify Connection",
        "cleared": "Reopen the player to reconnect",
    }.get(state.get("connection"), "Connect to Spotify")
    if state.get("connection") == "connecting" and state.get("can_reopen"):
        title = "Connect to Spotify"
    return [
        action_row(
            title,
            "connect",
            symbol="person.crop.circle",
            detail=state.get("message", "Connect Spotify to continue"),
        )
    ]


def set_rows(state, rows):
    state["rows"] = rows
    state["row_version"] = uuid.uuid4().hex
    state["selected"] = rows[0] if rows else {}
    state["preview_version"] = uuid.uuid4().hex
    state["preview_path"] = ""
    state["preview_attempted"] = False


def prefix(state):
    path = "/".join(r.get("name") or r["kind"].title() for r in state["stack"])
    return path + "/" if path else ""


def request(state, store):
    state["request"] = uuid.uuid4().hex
    state["pending"] = True
    state["message"] = note(store)
    state["touched"] = time.time()
    set_rows(state, rows_for(state, store))


def row_data(item, index):
    symbol = item.get("symbol") or {
        "track": "music.note",
        "album": "square.stack",
        "artist": "person.fill",
        "playlist": "music.note.list",
    }.get(item["kind"], "info.circle")
    return {
        "uid": item["uri"],
        "row_title.text": item["name"],
        "row_icon.image": {"type": "symbol", "src": symbol},
        "row_key.text": "⌘" + str(index + 1) if index < 9 else "",
        "item": item,
    }


def preview_item(item, store):
    """Use actual music for category previews, matching the Music mini player."""
    item = dict(item)
    target = item.get("target", {}).get("kind")
    if target in {"genres", "artists", "albums", "playlists"} or item.get("action") == "random":
        rows = Library(store, Spotify()).browse({"kind": target or "albums"})
        entries = [row for row in rows if row.get("action") not in {"none", "connect"}]
        noun = {
            "genres": "Genre",
            "artists": "Artist",
            "albums": "Album",
            "playlists": "Playlist",
        }.get(target, "Album")
        count = len(entries)
        if item.get("action") != "random":
            item["name"] = f"{count:,} {noun}{'' if count == 1 else 's'}"
        item["detail"] = (
            "Play an album from your music"
            if item.get("action") == "random"
            else "Connect Spotify to load playlists"
            if target == "playlists" and not Spotify().connected()
            else "Genre information unavailable"
            if target == "genres" and not count
            else ""
        )
        albums = entries if target == "albums" or not target else store.items("album")
        item["image"] = next((album["image"] for album in albums if album.get("image")), "")
    elif item.get("kind") == "artist" and not item.get("image"):
        albums = [
            album
            for album in store.items("album")
            if any(artist["uri"] == item["uri"] for artist in album.get("artists", []))
        ]
        item["image"] = next((album["image"] for album in albums if album.get("image")), "")
    return item


def preview_values(item, path=""):
    artists = ", ".join(a["name"] for a in item.get("artists", []))
    detail = item.get("detail", artists)
    if item.get("kind") == "track":
        detail = " · ".join(filter(None, [artists, item.get("album", {}).get("name", "")]))
    return {
        "preview_art": {"type": "file", "src": path} if path else None,
        "preview_title": item.get("name", ""),
        "preview_detail": detail,
    }


def patch(state, store, force=False, selection_only=False):
    values = {
        "SPOTIFY_SESSION": state["session"],
        "status_text": state.get("message", ""),
    }
    updates = {
        "status": {"text": "{var:status_text}"},
        "reconnect": {
            "hidden": not (state.get("connection") == "connecting" and state.get("can_reopen"))
        },
        **{
            key: {"enabled": state.get("connection") == "connected"}
            for key in ("search", "previous", "toggle", "next")
        },
    }
    if not selection_only and (
        force or state.get("row_version") != os.environ.get("SPOTIFY_SEEN_ROWS")
    ):
        values["SPOTIFY_SEEN_ROWS"] = state["row_version"]
        selected_uri = state.get("selected", {}).get("uri", "")
        values["browser_rows"] = [row_data(item, i) for i, item in enumerate(state.get("rows", []))]
        updates["results"] = {
            "data": {"type": "basic", "src": "{var:browser_rows}"},
            "select": selected_uri,
        }
    if force or state.get("preview_version") != os.environ.get("SPOTIFY_SEEN_PREVIEW"):
        values["SPOTIFY_SEEN_PREVIEW"] = state.get("preview_version", "")
        item = preview_item(state.get("selected", {}), store)
        state["preview_image"] = item.get("image", "")
        image = state.get("preview_path") or desktop.image(store, item.get("image"))
        values.update(preview_values(item, image))
        updates.update(
            {
                "artwork": {"image": "{var:preview_art}"},
                "preview_title": {"text": "{var:preview_title}"},
                "preview_detail": {"text": "{var:preview_detail}"},
            }
        )
    return {"variables": values, "update": {"ids": updates}}


def now_playing(store):
    current = store.get("now-playing")
    if current is None:
        current = player.status()
        store.put("now-playing", current, 2)
    path = desktop.image(store, current.get("image"), download=True)
    if not path:
        indexed = store.item(current.get("uri", "")) or {}
        path = desktop.image(store, indexed.get("image"), download=True)
    return {
        "now_title": current.get("name", "No track currently selected"),
        "now_detail": " · ".join(filter(None, [current.get("artist"), current.get("album")])),
        "now_art": {"type": "file", "src": path}
        if path
        else {"type": "symbol", "src": "music.note"},
        "play_symbol": {
            "type": "symbol",
            "src": "pause.fill" if current.get("playing") else "play.fill",
        },
    }


def init(store):
    session = uuid.uuid4().hex
    state = {
        "session": session,
        "stack": [],
        "query": "",
        "sync": False,
        "auth_seen": read_json(data_dir() / "sign-in.json", {}).get("at"),
        "touched": time.time(),
        "connection": "connected" if Spotify().connected() else "credentials",
        "authorization_generation": authorization_generation(),
    }
    request(state, store)
    if not Spotify().connected():
        try:
            credentials()
        except SpotifyError:
            state["message"] = "Add your Client ID and Client Secret to continue"
        else:
            begin_connection(state)
    write_json(session_path(session), state)
    # Expired player sessions are disposable. Keep them out of the library index.
    for old in (cache_dir() / "sessions").glob("*.json"):
        with contextlib.suppress(OSError):
            if old.stat().st_mtime < time.time() - 86400:
                old.unlink()
                old.with_suffix(".lock").unlink(missing_ok=True)
                old.with_suffix(".worker").unlink(missing_ok=True)
    spawn("worker", session)
    result = patch(state, store, True)
    if state["connection"] != "connected":
        result["sheet"] = connection_sheet(state)
    return result


def begin_connection(state, restart=False):
    progress = read_json(data_dir() / "sign-in.json", {})
    if restart:
        # A browser tab cannot reliably be detected after it is closed. A
        # user-requested retry cancels the old callback and opens a fresh tab.
        with lock(data_dir() / "authorization.lock"):
            write_json(data_dir() / "authorization-generation.json", {"id": uuid.uuid4().hex})
            (data_dir() / "sign-in.json").unlink(missing_ok=True)
        state["authorization_generation"] = authorization_generation()
        state["auth_started_at"] = time.time()
        state["can_reopen"] = True
        spawn("authorize-retry")
    elif progress.get("status") != "waiting" or progress.get("at", 0) < time.time() - 180:
        state["auth_started_at"] = time.time()
        state["can_reopen"] = False
        spawn("authorize")
    else:
        state["auth_started_at"] = progress["at"]
        state["can_reopen"] = True
    state["connection"] = "connecting"
    state["message"] = "Finish connecting in your browser"
    state["error_shown"] = False
    state["pending"] = False
    set_rows(state, connection_rows(state))


def connection_sheet(state):
    failed = state.get("connection") == "failed"
    connecting = state.get("connection") == "connecting"
    cleared = state.get("connection") == "cleared"
    title = (
        "Could not connect to Spotify"
        if failed
        else "Connecting to Spotify"
        if connecting
        else "Connection cleared"
        if cleared
        else "Connect your Spotify library"
    )
    message = (
        state.get("message", "")
        if failed or connecting or cleared
        else (
            "Add your Client ID and Client Secret in workflow settings. "
            "Then reopen the player to sign in through your browser."
        )
    )
    return {
        "id": "setup",
        "root": {
            "type": "view",
            "layout": "inline",
            "direction": "vertical",
            "padding": 20,
            "spacing": 12,
            "components": [
                {"type": "label", "text": title, "font": {"size": 18}},
                {"type": "label", "linebreak": "wordwrap", "text": message},
                {
                    "type": "view",
                    "layout": "inline",
                    "spacing": 8,
                    "components": [
                        *(
                            [
                                {
                                    "type": "button",
                                    "text": "Connect" if connecting else "Try Again",
                                    "events": [
                                        {
                                            "triggers": "actioned",
                                            "action": {
                                                "type": "script",
                                                "src": "run",
                                                "args": ["connect"],
                                            },
                                        }
                                    ],
                                }
                            ]
                            if failed or connecting
                            else []
                        ),
                        {
                            "type": "button",
                            "text": "Workflow Settings…",
                            "events": [
                                {
                                    "triggers": "actioned",
                                    "action": {
                                        "type": "script",
                                        "src": "run",
                                        "args": ["configure"],
                                    },
                                }
                            ],
                        },
                        {
                            "type": "button",
                            "text": "Close Player",
                            "events": [
                                {
                                    "triggers": "actioned",
                                    "action": {"type": "json", "src": {"finish": {}}},
                                }
                            ],
                        },
                    ],
                },
            ],
        },
    }


def show_configuration():
    # This runs only when the user asks the workflow to open its settings.
    script = """function run(argv) {
        Application("com.runningwithcrayons.Alfred").revealWorkflow(argv[0], {configuration: true});
    }"""
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, "--", BUNDLE_ID],
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
    except OSError, subprocess.TimeoutExpired:
        result = None
    if result is None or result.returncode:
        raise SpotifyError("Open Alfred Preferences → Workflows → Spotify Mini Player → Configure.")
    return {"finish": {}}


def clear_connection(store):
    """Invalidate pending callbacks and remove only this workflow's authorization."""
    with lock(data_dir() / "authorization.lock"):
        write_json(data_dir() / "authorization-generation.json", {"id": uuid.uuid4().hex})
        for name in ("authorization.json", "sign-in.json", "api-cooldown.json"):
            (data_dir() / name).unlink(missing_ok=True)
    # Preserve cached desktop music; clear account-specific membership and responses.
    store.db.execute("DELETE FROM saved")
    store.db.execute("DELETE FROM responses WHERE key != 'desktop:scanned'")
    store.commit()


def worker(session):
    path = session_path(session)
    with lock(path.with_suffix(".worker"), blocking=False) as acquired:
        if not acquired:
            return
        store = Store()
        try:
            if store.get("desktop:scanned") is None:
                desktop.index(store)
                store.put("desktop:scanned", True, 300)
            for _ in range(20):
                state = read_json(path, {})
                if not state or state.get("touched", 0) < time.time() - 600:
                    return
                revision = state.get("request")
                if state.get("pending"):
                    message = note(store)
                    try:
                        library = Library(store, Spotify())
                        if (
                            state.get("connection") == "connected"
                            and Spotify().connected()
                            and (state.get("sync") or store.get("library:synced") is None)
                        ):
                            library.sync()
                            message = note(store)
                        route = state["stack"][-1] if state["stack"] else {"kind": "home"}
                        rows = (
                            library.browse(
                                route, state.get("query", ""), network=Spotify().connected()
                            )
                            if state.get("connection") == "connected"
                            else connection_rows(state)
                        )
                    except SpotifyError as error:
                        store.db.rollback()
                        if error.status in (401, 403):
                            state.update(connection="failed", error_shown=False)
                        rows = rows_for(state, store)
                        message = str(error)
                    with state_lock(path) as latest:
                        if latest.get("request") != revision:
                            continue
                        set_rows(latest, rows)
                        if latest.get("connection") != "connected":
                            message = latest["message"]
                        if state.get("connection") == "failed":
                            latest.update(connection="failed", error_shown=False)
                            rows = connection_rows({**latest, "message": message})
                        latest.update(pending=False, sync=False, message=message)
                        state = dict(latest)
                item = preview_item(state.get("selected", {}), store)
                selected_uri = state.get("selected", {}).get("uri")
                image = desktop.image(store, item.get("image"), download=True)
                with state_lock(path) as latest:
                    if latest.get("selected", {}).get("uri") == selected_uri:
                        latest["preview_attempted"] = True
                        if image and image != latest.get("preview_path"):
                            latest["preview_path"] = image
                            latest["preview_version"] = uuid.uuid4().hex
                if read_json(path, {}).get("request") == revision:
                    break
        finally:
            store.close()


def handle(command, args, store):
    if command == "init":
        return init(store)
    if command == "configure":
        return show_configuration()
    path = session_path()
    with state_lock(path) as state:
        if not state:
            raise SpotifyError("Reopen the Spotify player to continue.")
        extra = {}
        item = selected(args[0]) if args else {}
        if command == "activate-index":
            index = int(args[0])
            item = state.get("rows", [])[index] if index < len(state.get("rows", [])) else {}
            command = "activate"
        if state.get("connection") != "connected" and (
            command in {"query", "refresh", "playback"}
            or command == "activate"
            and item.get("action") != "connect"
        ):
            return {"sheet": connection_sheet(state)}
        show_connection = False
        close_connection = False
        if command == "query":
            value = args[0] if args else ""
            breadcrumb = prefix(state)
            if breadcrumb and value == breadcrumb[:-1]:
                state["stack"].pop()
                state["query"] = ""
                extra = {"search": {"text": prefix(state), "focus": True}}
            elif value.startswith(breadcrumb):
                state["query"] = value[len(breadcrumb) :]
            else:
                state["stack"] = []
                state["query"] = value
            request(state, store)
        elif command in {"back", "home"}:
            if command == "back" and state.get("query"):
                state["query"] = ""
            elif state["stack"]:
                state["stack"] = state["stack"][:-1] if command == "back" else []
            request(state, store)
            extra = {"search": {"text": prefix(state), "focus": True}}
        elif command == "refresh":
            state["sync"] = True
            store.db.execute(
                "DELETE FROM responses WHERE key='desktop:scanned' "
                "OR key LIKE 'contents:%' OR key LIKE 'artist-albums:%'"
            )
            store.commit()
            request(state, store)
            state["message"] = "Refreshing from Spotify’s desktop cache and your library…"
        elif command == "preview":
            state["selected"] = item
            state["preview_path"] = ""
            state["preview_attempted"] = False
            state["preview_version"] = uuid.uuid4().hex
            state["touched"] = time.time()
        elif command == "activate":
            action = item.get("action")
            if item.get("kind") in {"album", "artist", "playlist"}:
                state["stack"].append(item)
                state["query"] = ""
                request(state, store)
                extra = {"search": {"text": prefix(state), "focus": True}}
            elif action in {"browse", "catalog"}:
                target = (
                    item.get("target")
                    if action == "browse"
                    else {"kind": "catalog", "query": item["query"], "name": "Spotify Search"}
                )
                state["stack"].append(target)
                state["query"] = ""
                request(state, store)
                extra = {"search": {"text": prefix(state), "focus": True}}
            elif action == "random":
                albums = Library(store, Spotify()).browse({"kind": "albums"})
                if not albums:
                    raise SpotifyError(
                        "Open a few albums in Spotify, or connect your library first."
                    )
                player.action("play", random.choice(albums)["uri"])
            elif action == "open":
                return {"open": {"type": "url", "src": item["play_uri"]}}
            elif action == "connect":
                try:
                    credentials()
                except SpotifyError:
                    return {"sheet": connection_sheet(state)}
                begin_connection(state, restart=True)
                show_connection = True
            elif item.get("kind") == "track" or action == "play":
                if item.get("is_playable") is False or item.get("is_local"):
                    raise SpotifyError("This track cannot be played through Spotify’s catalog.")
                player.action("play", item.get("play_uri") or item["uri"], item.get("context", ""))
        elif command == "playback":
            player.action(args[0])
            store.db.execute("DELETE FROM responses WHERE key='now-playing'")
            store.commit()
        elif command == "connect":
            try:
                credentials()
            except SpotifyError:
                return {"sheet": connection_sheet(state)}
            begin_connection(state, restart=True)
            show_connection = True
        elif command == "poll":
            if state.get("authorization_generation") != authorization_generation():
                state.update(
                    connection="cleared",
                    pending=False,
                    message="Connection cleared. Reopen Spotify Mini Player to sign in.",
                    authorization_generation=authorization_generation(),
                )
                set_rows(state, connection_rows(state))
                result = patch(state, store)
                result["sheet"] = connection_sheet(state)
                return result
            auth_state = read_json(data_dir() / "sign-in.json", {})
            fresh = auth_state.get("at", 0) >= state.get(
                "auth_started_at", float("inf")
            ) and state.get("auth_seen") != auth_state.get("at")
            if fresh and auth_state.get("status") == "connected" and Spotify().connected():
                state["auth_seen"] = auth_state["at"]
                state["connection"] = "connected"
                state["sync"] = True
                request(state, store)
                close_connection = True
            elif fresh and auth_state.get("status") == "error":
                state["auth_seen"] = auth_state["at"]
                state["connection"] = "failed"
                state["message"] = auth_state.get("message", "Could not connect to Spotify.")
                state["pending"] = False
                state["error_shown"] = False
                set_rows(state, connection_rows(state))
            if state.get("connection") == "failed" and not state.get("error_shown"):
                show_connection = True
                state["error_shown"] = True
            state["touched"] = time.time()
        else:
            raise ValueError("Unknown player command")
        # Updating dataview.data dispatches a new selection event. A selection
        # handler must only update the preview, never rebuild its own dataview.
        result = patch(state, store, selection_only=command in {"preview", "playback", "connect"})
        result["update"]["ids"].update(extra)
        if show_connection:
            result["sheet"] = connection_sheet(state)
        elif close_connection:
            result["sheet"] = {"close": "setup"}
            result["update"]["ids"]["search"]["focus"] = True
        session = state["session"]
        needs_worker = state.get("pending") or (
            state.get("preview_image") and not state.get("preview_attempted")
        )
    if needs_worker:
        spawn("worker", session)
    if command in {"poll", "playback"} and state.get("connection") == "connected":
        result["variables"].update(now_playing(store))
        for ident, properties in {
            "now_title": {"text": "{var:now_title}"},
            "now_detail": {"text": "{var:now_detail}"},
            "now_art": {"image": "{var:now_art}"},
            "toggle": {"image": "{var:play_symbol}"},
        }.items():
            result["update"]["ids"].setdefault(ident, {}).update(properties)
    return result


def main(argv=None):
    args = list(argv if argv is not None else sys.argv[1:])
    command = args.pop(0) if args else "init"
    if command in {"init", "migrate"}:
        from .migration import migrate

        migration = migrate()
        if command == "migrate":
            print(json.dumps(migration))
            return
    if command == "init":
        from .configuration import apply_imported_credentials

        apply_imported_credentials()
    if command == "worker":
        worker(args[0])
        return
    if command in {"authorize", "authorize-retry"}:
        from .auth import connect

        connect(wait_for_previous=command == "authorize-retry")
        return
    store = Store()
    try:
        if command == "clear-connection":
            clear_connection(store)
            print("Connection cleared. Open Spotify to sign in again.")
            return
        result = handle(command, args, store)
    except (SpotifyError, ValueError) as error:
        result = {
            "variables": {"status_text": str(error)},
            "update": {"ids": {"status": {"text": "{var:status_text}"}}},
        }
    finally:
        store.close()
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
