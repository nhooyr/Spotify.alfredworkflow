"""Browse the desktop metadata index, filling misses through the public API."""

import time
import unicodedata

from .api import SpotifyError
from .metadata import from_api


def folded(value):
    return "".join(
        c for c in unicodedata.normalize("NFKD", value.casefold()) if not unicodedata.combining(c)
    )


def matching(items, query):
    terms = folded(query).split()
    return [
        item
        for item in items
        if all(
            term
            in folded(
                " ".join(
                    [
                        item["name"],
                        item.get("album", {}).get("name", ""),
                        *[artist["name"] for artist in item.get("artists", [])],
                    ]
                )
            )
            for term in terms
        )
    ]


def unique(items):
    return list({item["uri"]: item for item in items if item and item.get("uri")}.values())


def action_row(name, action, **values):
    return {"name": name, "kind": "action", "action": action, "uri": action, **values}


class Library:
    def __init__(self, store, spotify):
        self.store = store
        self.spotify = spotify

    def sync(self):
        """Commit membership only when all four paginated reads have succeeded."""
        items = []
        for value in self.spotify.pages("/me/tracks"):
            items.append(from_api(value.get("track"), "track"))
        for value in self.spotify.pages("/me/albums"):
            album = from_api(value.get("album"), "album")
            items.append(album)
            if album:
                tracks = (value.get("album") or {}).get("tracks", {}).get("items", [])
                for track in tracks:
                    track = from_api(track, "track")
                    if track:
                        track["album"] = album
                        self.store.put_item(track)
        items.extend(
            from_api(value, "artist")
            for value in self.spotify.pages("/me/following", {"type": "artist"}, nested="artists")
        )
        items.extend(from_api(value, "playlist") for value in self.spotify.pages("/me/playlists"))
        items = [item for item in items if item]
        self.store.db.execute("DELETE FROM saved")
        for item in items:
            self.store.put_item(item)
            self.store.db.execute("INSERT OR IGNORE INTO saved VALUES (?)", (item["uri"],))
            for artist in item.get("artists", []):
                self.store.put_item(artist)
                self.store.db.execute("INSERT OR IGNORE INTO saved VALUES (?)", (artist["uri"],))
        self.store.put("library:synced", time.time(), ttl=86400)

    def browse(self, route, query="", network=False):
        kind = route.get("kind", "home")
        connected = self.spotify.connected()
        has_library = self.store.get("library:synced", stale=True) is not None
        saved_only = connected and has_library
        if kind == "home":
            if query:
                items = self.search(query, False)
                if connected:
                    items.append(
                        action_row(
                            f"Search Spotify for “{query}”",
                            "catalog",
                            query=query,
                            symbol="magnifyingglass",
                        )
                    )
                return items
            return [
                action_row("Genres", "browse", target={"kind": "genres"}, symbol="opticaldisc"),
                action_row("Artists", "browse", target={"kind": "artists"}, symbol="person.fill"),
                action_row("Albums", "browse", target={"kind": "albums"}, symbol="music.note"),
                action_row(
                    "Playlists", "browse", target={"kind": "playlists"}, symbol="music.note.list"
                ),
                action_row("Random Album", "random", symbol="shuffle"),
            ]
        if kind in {"artists", "albums", "playlists", "tracks"}:
            if kind == "playlists" and not connected:
                return [
                    action_row(
                        "Connect to Spotify",
                        "connect",
                        symbol="person.crop.circle",
                        detail="Connect your account to browse your playlists.",
                    )
                ]
            singular = {
                "artists": "artist",
                "albums": "album",
                "playlists": "playlist",
                "tracks": "track",
            }[kind]
            items = self.store.items(singular, saved=saved_only)
            if kind == "albums" and saved_only:
                items = unique(
                    [
                        *items,
                        *[
                            t["album"]
                            for t in self.store.items("track", saved=True)
                            if t.get("album", {}).get("uri")
                        ],
                    ]
                )
        elif kind == "catalog":
            return self.search(route["query"], network)
        elif kind == "genres":
            genres = sorted(
                {
                    g
                    for item in self.store.items("artist", saved=saved_only)
                    for g in item.get("genres", [])
                }
            )
            items = [
                action_row(
                    g.title(),
                    "browse",
                    target={"kind": "genre", "genre": g, "name": g.title()},
                    symbol="opticaldisc",
                )
                for g in genres
            ]
            if not items:
                items = [
                    action_row(
                        "No genre information available",
                        "none",
                        detail=(
                            "Spotify no longer provides genre tags in desktop metadata. "
                            "Browse Artists or Albums instead."
                        ),
                    )
                ]
        elif kind == "genre":
            items = [
                a
                for a in self.store.items("artist", saved=saved_only)
                if route["genre"] in a.get("genres", [])
            ]
        elif kind == "artist":
            artist = self.store.item(route["uri"]) or route
            items = artist.get("albums", [])
            items += [
                a
                for a in self.store.items("album")
                if any(v["uri"] == route["uri"] for v in a.get("artists", []))
            ]
            key = "artist-albums:" + route["uri"]
            cached = self.store.get(key)
            if network and not cached and not items:
                items = [
                    from_api(value, "album")
                    for value in self.spotify.pages(
                        "/artists/" + route["id"] + "/albums", {"include_groups": "album,single"}
                    )
                ]
                items = [item for item in items if item]
                self.store.put(key, items)
            elif cached:
                items = cached
            items = [
                action_row(
                    "Play all tracks by " + route["name"],
                    "play",
                    play_uri=route["uri"],
                    symbol="play.fill",
                ),
                *unique(items),
            ]
        elif kind in {"album", "playlist"}:
            item = self.store.item(route["uri"]) or route
            items = item.get("tracks", [])
            if kind == "album" and not items:
                items = [
                    t
                    for t in self.store.items("track")
                    if t.get("album", {}).get("uri") == route["uri"]
                ]
                items.sort(key=lambda t: (t.get("disc_number", 0), t.get("track_number", 0)))
            key = "contents:" + route["uri"]
            cached = self.store.get(key)
            if network and not cached and not (kind == "album" and item.get("tracks")):
                endpoint = (
                    f"/albums/{route['id']}/tracks"
                    if kind == "album"
                    else f"/playlists/{route['id']}/items"
                )
                try:
                    items = []
                    for value in self.spotify.pages(endpoint):
                        value = (
                            value.get("item", value.get("track")) if kind == "playlist" else value
                        )
                        track = from_api(value, "track")
                        if track:
                            if kind == "album":
                                track["album"], track["image"] = item, item.get("image", "")
                            items.append(track)
                    self.store.put(key, items)
                except SpotifyError as error:
                    if kind != "playlist" or error.status != 403:
                        raise
                    items = [
                        action_row(
                            "Open playlist in Spotify",
                            "open",
                            play_uri=route["uri"],
                            detail="Spotify exposes playlist contents to owners and collaborators.",
                        )
                    ]
            elif cached is not None:
                items = cached
            for track in items:
                if track.get("kind") == "track":
                    track["context"] = route["uri"]
            items = [
                action_row(
                    "Play " + route["name"], "play", play_uri=route["uri"], symbol="play.fill"
                ),
                *items,
            ]
        else:
            items = []
        if kind in {"artists", "albums", "playlists", "genre"}:
            items = sorted(items, key=lambda x: folded(x["name"]))
        return matching(items, query) if query else items

    def search(self, query, network=False):
        local = matching(self.store.items(), query)
        key = "search:" + query.casefold().strip()
        remote = self.store.get(key)
        if network and remote is None:
            result = self.spotify.request(
                "/search", {"q": query, "type": "track,album,artist,playlist", "limit": 10}
            )
            remote = [
                from_api(value, kind)
                for kind in ("track", "album", "artist", "playlist")
                for value in (result.get(kind + "s") or {}).get("items", [])
            ]
            remote = [item for item in remote if item]
            self.store.put(key, remote, 900)
            for item in remote:
                self.store.put_item(item)
            self.store.commit()
        result = unique([*(remote or []), *local])
        return result[:200]
