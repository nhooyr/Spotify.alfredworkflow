import io
import json
import threading
import time
from unittest.mock import Mock, patch

from test_workflow import TRACK, Isolated

from alfred_spotify import controller, metadata
from alfred_spotify.api import SCOPES, Spotify, SpotifyError
from alfred_spotify.likes import LikedSongs
from alfred_spotify.resident import Backend
from alfred_spotify.storage import read_json, write_json


class LikedSongsTests(Isolated):
    def setUp(self):
        super().setUp()
        self.track = metadata.from_desktop("track", TRACK)
        self.uri = self.track["uri"]
        self.store.put_item(self.track)
        self.store.commit()
        self.api = Mock()
        self.api.has_scope.return_value = True
        self.likes = LikedSongs(self.store, self.api)

    def test_initial_membership_reuses_local_index(self):
        self.assertFalse(self.likes.cached(self.uri))
        self.store.db.execute("INSERT INTO saved VALUES (?)", (self.uri,))
        self.assertTrue(self.likes.cached(self.uri))
        self.api.request.assert_not_called()

    def test_check_updates_membership_and_reuses_short_cache(self):
        self.api.request.return_value = [True]
        self.assertTrue(self.likes.check(self.uri))
        self.assertTrue(self.likes.cached(self.uri))
        self.assertTrue(self.likes.check(self.uri))
        self.api.request.assert_called_once_with("/me/library/contains", {"uris": self.uri})

    def test_check_reflects_removal_in_desktop(self):
        self.store.db.execute("INSERT INTO saved VALUES (?)", (self.uri,))
        self.api.request.return_value = [False]
        self.assertFalse(self.likes.check(self.uri))
        self.assertFalse(self.likes.cached(self.uri))

    def test_invalid_check_never_claims_membership(self):
        for result in ({}, [1], [], [True, False]):
            with self.subTest(result=result):
                self.api.request.return_value = result
                with self.assertRaises(SpotifyError):
                    self.likes.check(self.uri)
                self.assertFalse(self.likes.cached(self.uri))

    def test_save_uses_universal_library_endpoint_and_invalidates_search(self):
        self.store.put("search:snapshot", {"version": "old"})
        self.assertTrue(self.likes.save(self.uri))
        self.api.request.assert_called_once_with("/me/library", {"uris": self.uri}, method="PUT")
        self.assertTrue(self.likes.cached(self.uri))
        self.assertIsNone(self.store.get("search:snapshot"))
        self.assertEqual(self.store.items("track", saved=True)[0]["uri"], self.uri)

    def test_save_failure_does_not_claim_a_song_is_liked(self):
        self.api.request.side_effect = SpotifyError("No permission", 403)
        with self.assertRaisesRegex(SpotifyError, "No permission"):
            self.likes.save(self.uri)
        self.assertFalse(self.likes.cached(self.uri))

    def test_missing_save_scope_requests_reauth_without_api_call(self):
        self.api.has_scope.return_value = False
        with self.assertRaisesRegex(SpotifyError, "spotify reauth"):
            self.likes.save(self.uri)
        self.api.request.assert_not_called()

    def test_unknown_track_loads_metadata_before_saving(self):
        other = "spotify:track:" + "b" * 22
        value = {"uri": other, "type": "track", "id": "b" * 22, "name": "Another song"}
        self.api.request.side_effect = [value, {}]
        self.assertTrue(self.likes.save(other))
        self.assertEqual(self.store.item(other)["name"], "Another song")
        self.assertTrue(self.likes.cached(other))
        self.assertEqual(self.api.request.call_args_list[0].args[0], "/tracks/" + "b" * 22)

    def test_only_track_uris_can_be_saved(self):
        for uri in ("spotify:local:a", "spotify:album:" + "a" * 22, "track:x", self.uri + "/extra"):
            with self.subTest(uri=uri), self.assertRaises(SpotifyError):
                self.likes.save(uri)
        self.api.request.assert_not_called()

    def test_new_login_and_refresh_preserve_granted_scopes(self):
        responses = iter(
            [
                {"access_token": "one", "refresh_token": "refresh", "scope": SCOPES},
                {"access_token": "two"},
            ]
        )
        api = Spotify(lambda *_, **__: io.BytesIO(json.dumps(next(responses)).encode()))
        api.token_request({"grant_type": "authorization_code", "code_verifier": "verifier"})
        self.assertTrue(api.has_scope("user-library-modify"))
        api.token_request({"grant_type": "refresh_token", "refresh_token": "refresh"})
        self.assertTrue(api.has_scope("user-library-modify"))
        self.assertEqual(read_json(api.path)["scope"], SCOPES)


class ResidentLikedSongsTests(Isolated):
    def setUp(self):
        super().setUp()
        self.track = metadata.from_desktop("track", TRACK)
        self.uri = self.track["uri"]
        self.store.put_item(self.track)
        self.store.put("library:synced", time.time())
        write_json(
            self.root / "data/authorization.json",
            {
                "client_id": "a" * 32,
                "access_token": "access",
                "refresh_token": "refresh",
                "expires_at": time.time() + 3600,
                "scope": SCOPES,
            },
        )
        self.messages = []
        self.backend = Backend(self.messages.append)
        self.backend.start()

    def tearDown(self):
        self.backend.close()
        super().tearDown()

    def test_saved_song_updates_open_songs_menu_and_catalog(self):
        with controller.state_lock(controller.session_path(self.backend.session)) as state:
            state["stack"] = [{"kind": "songs"}]
        api = Mock()
        api.connected.return_value = True
        api.has_scope.return_value = True
        with patch("alfred_spotify.resident.Spotify", return_value=api):
            self.backend.liked_action({"command": "save", "args": [self.uri]})
            self.backend.drain_likes()
        liked = [m for m in self.messages if m["type"] == "liked"]
        self.assertEqual(
            liked[-1], {"type": "liked", "uri": self.uri, "liked": True, "saved": True}
        )
        updates = [m for m in self.messages if m.get("command") == "liked"]
        self.assertEqual(updates[-1]["rows"][0]["uri"], self.uri)
        self.assertTrue(any(m["type"] == "catalog" for m in self.messages))

    def test_save_failure_is_tied_to_its_track_and_does_not_mutate_cache(self):
        api = Mock()
        api.has_scope.return_value = False
        with patch("alfred_spotify.resident.Spotify", return_value=api):
            self.backend.liked_action({"command": "save", "args": [self.uri]})
            self.backend.drain_likes()
        result = self.messages[-1]
        self.assertEqual(result["uri"], self.uri)
        self.assertFalse(result["liked"])
        self.assertIn("spotify reauth", result["error"])

    def test_membership_requests_do_not_block_navigation(self):
        started = threading.Event()
        release = threading.Event()

        def wait_for_release(message):
            started.set()
            release.wait(timeout=3)

        with patch.object(self.backend, "liked_action", side_effect=wait_for_release):
            try:
                self.backend.handle({"command": "liked", "args": [self.uri]})
                self.assertTrue(started.wait(timeout=1))
                self.assertEqual(self.messages[-1]["type"], "liked")
                self.assertTrue(self.messages[-1]["cached"])
                self.backend.handle({"command": "poll"})
                self.assertEqual(self.messages[-1]["command"], "poll")
            finally:
                release.set()
                self.backend.close()
