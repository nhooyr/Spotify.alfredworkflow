import hashlib
import json
import time
from unittest.mock import patch

from test_workflow import TRACK, Isolated

from alfred_spotify import controller, metadata
from alfred_spotify.resident import Backend, native_row
from alfred_spotify.storage import read_json, write_json


class ResidentTests(Isolated):
    def setUp(self):
        super().setUp()
        self.track = metadata.from_desktop("track", TRACK)
        self.store.put_item(self.track)
        self.store.db.execute("INSERT INTO saved VALUES (?)", (self.track["uri"],))
        self.store.put("library:synced", time.time())
        write_json(
            self.root / "data/authorization.json",
            {
                "client_id": "a" * 32,
                "access_token": "access",
                "refresh_token": "refresh",
                "expires_at": time.time() + 3600,
            },
        )
        self.messages = []
        self.backend = Backend(self.messages.append)

    def tearDown(self):
        self.backend.close()
        super().tearDown()

    def test_initialization_and_reopening_reuse_the_same_session(self):
        self.backend.start()
        session = self.backend.session
        with patch.object(controller, "init", side_effect=AssertionError("recreated player")):
            self.backend.handle({"command": "show"})
            self.backend.handle({"command": "show"})
        self.assertEqual(self.backend.session, session)
        self.assertEqual(
            [row["name"] for row in self.messages[0]["rows"]],
            ["Playlists", "Albums", "Artists", "Songs"],
        )

    def test_preview_does_not_reload_the_native_table(self):
        self.backend.start()
        self.backend.handle({"command": "preview", "args": [json.dumps(self.track)], "request": 12})
        update = self.messages[-1]
        self.assertNotIn("rows", update)
        self.assertEqual(update["selected"], self.track["uri"])
        self.assertEqual(update["request"], 12)

    def test_catalog_is_sent_once_and_contains_cached_art(self):
        path = self.root / "cover.img"
        path.write_bytes(b"image")
        self.backend.artwork = {hashlib.sha256(self.track["image"].encode()).hexdigest(): str(path)}
        controller.warm_search(self.store)
        self.backend.send_catalog()
        self.backend.send_catalog()
        catalogs = [message for message in self.messages if message["type"] == "catalog"]
        self.assertEqual(len(catalogs), 1)
        self.assertEqual(catalogs[0]["rows"][0]["name"], self.track["name"])

    def test_native_rows_do_not_send_nested_album_contents_back_for_playback(self):
        item = self.track | {"tracks": [self.track] * 500, "context": "spotify:playlist:test"}
        model = native_row(item, {})
        self.assertNotIn("tracks", model["item"])
        self.assertNotIn("album", model["item"])
        self.assertEqual(model["item"]["context"], "spotify:playlist:test")
        self.assertIn("Björk", model["match"])

    def test_native_worker_never_polls_spotify_playback(self):
        self.backend.start()
        with patch(
            "alfred_spotify.player.status",
            side_effect=AssertionError("playback belongs to the host"),
        ):
            self.backend.handle({"command": "poll"})

    def test_pending_connection_can_be_reopened_without_reinitializing(self):
        self.backend.start()
        with controller.state_lock(controller.session_path(self.backend.session)) as state:
            state.update(connection="connecting", can_reopen=False)
        self.backend.handle({"command": "show"})
        self.assertNotIn("sheet", self.messages[-1])
        self.assertEqual(self.messages[-1]["connection"], "connecting")

    def test_reset_clears_login_keeps_client_keys_and_reconnects_on_next_show(self):
        self.backend.start()
        settings = {"SPOTIFY_CLIENT_ID": "a" * 32, "SPOTIFY_CLIENT_SECRET": "test-secret"}
        write_json(self.root / "data/client-credentials.json", settings)
        self.backend.handle({"command": "reset", "request": 3})
        self.assertFalse((self.root / "data/authorization.json").exists())
        self.assertEqual(read_json(self.root / "data/client-credentials.json"), settings)
        self.assertEqual(self.messages[-1]["connection"], "cleared")
        self.assertTrue(self.messages[-1]["close_player"])
        self.assertIsNotNone(self.store.item(self.track["uri"]))
        with patch.object(
            controller, "begin_connection", wraps=controller.begin_connection
        ) as connect:
            self.backend.handle({"command": "show"})
        connect.assert_called_once()
        self.assertEqual(self.messages[-1]["connection"], "connecting")

    def test_externally_cleared_connection_reconnects_when_warm_player_reopens(self):
        self.backend.start()
        controller.clear_connection(self.store)
        self.backend.handle({"command": "poll"})
        self.assertEqual(self.messages[-1]["connection"], "cleared")
        self.backend.handle({"command": "show"})
        self.assertEqual(self.messages[-1]["connection"], "connecting")

    def test_all_connection_states_stay_inline_without_a_dialog(self):
        self.backend.start()
        for connection in ("credentials", "connecting", "failed", "cleared"):
            with self.subTest(connection=connection):
                with controller.state_lock(controller.session_path(self.backend.session)) as state:
                    state.update(connection=connection, message="Connection status")
                self.backend.publish({"sheet": controller.connection_sheet(state)}, "poll")
                self.assertNotIn("sheet", self.messages[-1])
                self.assertEqual(self.messages[-1]["message"], "Connection status")

    def test_connected_library_does_not_show_a_connect_hint_while_syncing(self):
        self.store.db.execute("DELETE FROM responses WHERE key='library:synced'")
        self.store.commit()
        self.assertEqual(controller.note(self.store), "")
