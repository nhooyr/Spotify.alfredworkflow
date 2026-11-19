"""Liked Songs membership, using the local index before the public Web API."""

import re

from .api import SpotifyError
from .metadata import from_api

TRACK_URI = re.compile(r"spotify:track:[A-Za-z0-9]{22}\Z")


class LikedSongs:
    def __init__(self, store, spotify):
        self.store = store
        self.spotify = spotify

    def cached(self, uri):
        return (
            self.store.db.execute("SELECT 1 FROM saved WHERE uri=?", (uri,)).fetchone() is not None
        )

    def remember(self, uri, liked):
        if liked:
            self.store.db.execute("INSERT OR IGNORE INTO saved VALUES (?)", (uri,))
        else:
            self.store.db.execute("DELETE FROM saved WHERE uri=?", (uri,))
        self.store.put("liked:" + uri, liked, ttl=60)

    def check(self, uri):
        self.validate(uri)
        cached = self.store.get("liked:" + uri)
        if cached is not None:
            return cached
        result = self.spotify.request("/me/library/contains", {"uris": uri})
        if not isinstance(result, list) or len(result) != 1 or not isinstance(result[0], bool):
            raise SpotifyError("Spotify returned an invalid Liked Songs response.")
        self.remember(uri, result[0])
        return result[0]

    def save(self, uri):
        self.validate(uri)
        if not self.spotify.has_scope("user-library-modify"):
            raise SpotifyError("Run spotify reauth once to allow saving songs, then connect again.")
        item = self.store.item(uri)
        if not item:
            item = from_api(self.spotify.request("/tracks/" + uri.rsplit(":", 1)[1]), "track")
            if not item or item["uri"] != uri:
                raise SpotifyError("Spotify could not load this song. Try again.")
        self.spotify.request("/me/library", {"uris": uri}, method="PUT")
        self.store.put_item(item)
        self.remember(uri, True)
        # The new song must immediately appear in native search and Songs.
        self.store.db.execute("DELETE FROM responses WHERE key='search:snapshot'")
        self.store.commit()
        return True

    @staticmethod
    def validate(uri):
        if not TRACK_URI.fullmatch(uri):
            raise SpotifyError("Only Spotify songs can be saved to Liked Songs.")
