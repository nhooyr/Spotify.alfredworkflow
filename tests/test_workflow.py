import io
import json
import os
import plistlib
import struct
import tempfile
import threading
import time
import unittest
import uuid
import zipfile
import zlib
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

from alfred_spotify import auth as auth_module
from alfred_spotify import controller, desktop, metadata
from alfred_spotify.api import Spotify, SpotifyError
from alfred_spotify.auth import authorization_url
from alfred_spotify.library import Library
from alfred_spotify.storage import Store, read_json, write_json

TRACK_ID = "1" * 32
ALBUM_ID = "2" * 32
ARTIST_ID = "3" * 32
IMAGE_ID = "4" * 40
TRACK = {
    "gid": TRACK_ID,
    "name": "A track",
    "duration": 123000,
    "number": 2,
    "artist": [{"gid": ARTIST_ID, "name": "Björk"}],
    "album": {
        "gid": ALBUM_ID,
        "name": "An album",
        "date": {"year": 2026},
        "artist": [{"gid": ARTIST_ID, "name": "Björk"}],
        "cover_group": {"image": [{"file_id": IMAGE_ID}]},
    },
}


def cache_file(path, url, body, version=5, checksum=None):
    key = b"1/0/_dk_https://spotify.com https://spotify.com " + url.encode()
    header = struct.pack("<QIIII", desktop.INITIAL_MAGIC, version, len(key), 0, 0)
    footer1 = struct.pack(
        "<QIIII", desktop.FINAL_MAGIC, 1, zlib.crc32(body) if checksum is None else checksum, 0, 0
    )
    headers = b"These response headers are not read"
    footer0 = struct.pack("<QIIII", desktop.FINAL_MAGIC, 0, 0, len(headers), 0)
    path.write_bytes(header + key + body + footer1 + headers + footer0)


class Isolated(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.cache = self.root / "desktop"
        self.cache.mkdir()
        self.env = patch.dict(
            os.environ,
            {
                "alfred_workflow_data": str(self.root / "data"),
                "alfred_workflow_cache": str(self.root / "cache"),
                "SPOTIFY_DESKTOP_CACHE": str(self.cache),
                "SPOTIFY_CLIENT_ID": "a" * 32,
                "SPOTIFY_CLIENT_SECRET": "fake-secret",
            },
        )
        self.env.start()
        self.no_artwork_network = patch(
            "alfred_spotify.desktop.urlopen", side_effect=OSError("offline test")
        )
        self.no_artwork_network.start()
        self.store = Store()

    def tearDown(self):
        self.store.close()
        self.no_artwork_network.stop()
        self.env.stop()
        self.temp.cleanup()


class DesktopTests(Isolated):
    def test_reuses_an_existing_cover_size_before_downloading_another(self):
        full = "ab67616d0000b273" + "a" * 24
        cached = "ab67616d00004851" + "a" * 24
        jpeg = b"\xff\xd8\xffcached rendition"
        cache_file(self.cache / "cover_0", "https://i.scdn.co/image/" + cached, jpeg)
        desktop.index(self.store)
        with patch("alfred_spotify.desktop.urlopen", side_effect=AssertionError("network")):
            path = desktop.image(self.store, "https://i.scdn.co/image/" + full, download=True)
        self.assertEqual(Path(path).read_bytes(), jpeg)

    def test_index_reuses_metadata_and_artwork_without_network_or_writes(self):
        import gzip

        metadata_path = self.cache / "metadata_0"
        image_path = self.cache / "image_0"
        cache_file(
            metadata_path,
            "https://spclient.wg.spotify.com/metadata/4/track/" + TRACK_ID,
            gzip.compress(json.dumps(TRACK).encode()),
        )
        jpeg = b"\xff\xd8\xff" + b"image bytes"
        cache_file(image_path, "https://i.scdn.co/image/" + IMAGE_ID, jpeg)
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.cache.iterdir()}
        self.assertEqual(desktop.index(self.store), 1)
        track = self.store.items("track")[0]
        self.assertEqual(track["name"], "A track")
        self.assertEqual(track["duration_ms"], 123000)
        self.assertEqual(track["album"]["year"], "2026")
        with patch("alfred_spotify.desktop.urlopen", side_effect=AssertionError("network")):
            image = desktop.image(self.store, track["image"], download=True)
        self.assertEqual(Path(image).read_bytes(), jpeg)
        self.assertEqual(desktop.index(self.store), 0)
        self.assertEqual(
            before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.cache.iterdir()}
        )
        image_path.unlink()
        self.assertEqual(desktop.image(self.store, track["image"]), image)

    def test_invalid_cache_files_and_non_music_urls_are_ignored(self):
        cache_file(
            self.cache / "corrupt_0",
            "https://i.scdn.co/image/" + IMAGE_ID,
            b"\xff\xd8\xff",
            checksum=123,
        )
        cache_file(self.cache / "unknown_0", "https://i.scdn.co/image/other", b"image", version=6)
        cache_file(self.cache / "secret_0", "https://accounts.spotify.com/token", b"private")
        (self.cache / "truncated_0").write_bytes(b"truncated")
        desktop.index(self.store)
        self.assertIsNone(desktop.image(self.store, "https://i.scdn.co/image/" + IMAGE_ID))
        urls = [r[0] for r in self.store.db.execute("SELECT url FROM desktop")]
        self.assertNotIn("https://accounts.spotify.com/token", urls)

    def test_zstd_metadata_and_utf8(self):
        from compression import zstd

        cache_file(
            self.cache / "zstd_0",
            "https://spclient.wg.spotify.com/metadata/4/track/" + TRACK_ID,
            zstd.compress(json.dumps(TRACK).encode()),
        )
        self.assertEqual(desktop.index(self.store), 1)
        self.assertEqual(self.store.items("artist")[0]["name"], "Björk")


class APITests(Isolated):
    def tokens(self, expired=False):
        write_json(
            self.root / "data/authorization.json",
            {
                "client_id": "a" * 32,
                "access_token": "old-access",
                "refresh_token": "refresh",
                "expires_at": 0 if expired else time.time() + 3600,
            },
        )

    def test_refresh_keeps_refresh_token_and_uses_basic_auth(self):
        self.tokens(True)
        requests = []

        def opener(request, **kwargs):
            requests.append(request)
            if request.full_url.endswith("/api/token"):
                self.assertTrue(request.get_header("Authorization").startswith("Basic "))
                return io.BytesIO(b'{"access_token":"new","expires_in":3600}')
            self.assertEqual(request.get_header("Authorization"), "Bearer new")
            return io.BytesIO(b'{"items":[]}')

        self.assertEqual(Spotify(opener).request("/me/tracks"), {"items": []})
        self.assertEqual(
            read_json(self.root / "data/authorization.json")["refresh_token"], "refresh"
        )
        self.assertEqual(len(requests), 2)
        self.assertEqual((self.root / "data/authorization.json").stat().st_mode & 0o777, 0o600)

    def test_401_refreshes_once_and_retries(self):
        self.tokens()
        calls = []

        def opener(request, **kwargs):
            calls.append(request.full_url)
            if len(calls) == 1:
                raise HTTPError(request.full_url, 401, "expired", {}, io.BytesIO(b"{}"))
            if request.full_url.endswith("/api/token"):
                return io.BytesIO(b'{"access_token":"new","expires_in":3600}')
            return io.BytesIO(b'{"items":[]}')

        self.assertEqual(Spotify(opener).request("/me/tracks"), {"items": []})
        self.assertEqual(len(calls), 3)

    def test_pagination_rejects_foreign_host_before_transmitting_tokens(self):
        self.tokens()
        calls = []

        def opener(request, **kwargs):
            calls.append(request.full_url)
            return io.BytesIO(b'{"items":[],"next":"https://example.org/steal"}')

        with self.assertRaisesRegex(SpotifyError, "invalid library page"):
            list(Spotify(opener).pages("/me/tracks"))
        self.assertEqual(len(calls), 1)

    def test_quota_cooldown_does_not_repeatedly_request(self):
        self.tokens()
        calls = []

        def opener(request, **kwargs):
            calls.append(request.full_url)
            raise HTTPError(
                request.full_url,
                429,
                "quota",
                {"Retry-After": "60"},
                io.BytesIO(b'{"error":{"reason":"QUOTA_EXCEEDED"}}'),
            )

        client = Spotify(opener)
        for _ in range(2):
            with self.assertRaisesRegex(SpotifyError, "quota"):
                client.request("/me/tracks")
        self.assertEqual(len(calls), 1)

    def test_oauth_url_contains_state_and_loopback_but_no_secret(self):
        redirect_uri = "http://127.0.0.1:49152/spotify_callback"
        url = authorization_url("a" * 32, "random-state", redirect_uri)
        args = parse_qs(urlsplit(url).query)
        self.assertEqual(args["state"], ["random-state"])
        self.assertEqual(args["redirect_uri"], [redirect_uri])
        self.assertNotIn("fake-secret", url)

    def test_callback_uses_assigned_port_and_rejects_wrong_host_path_and_state(self):
        from http.server import HTTPServer

        servers = []
        threads = []
        responses = []
        redirects = []

        def server_factory(address, handler):
            self.assertEqual(address, ("127.0.0.1", 0))
            server = HTTPServer(address, handler)
            servers.append(server)
            return server

        def open_browser(url):
            args = parse_qs(urlsplit(url).query)
            state = args["state"][0]
            redirect_uri = args["redirect_uri"][0]
            redirects.append(redirect_uri)
            redirect = urlsplit(redirect_uri)
            port = servers[0].server_port
            self.assertEqual(redirect.hostname, "127.0.0.1")
            self.assertEqual(redirect.port, port)
            self.assertEqual(redirect.path, "/spotify_callback")
            self.assertGreater(port, 0)

            def callback():
                for path, supplied_state, host in (
                    ("/callback", state, redirect.netloc),
                    ("/spotify/callback", state, redirect.netloc),
                    ("/spotify_callback", state, f"localhost:{port}"),
                    ("/spotify_callback", "forged-state", redirect.netloc),
                    ("/spotify_callback", state, redirect.netloc),
                ):
                    request = Request(
                        f"http://127.0.0.1:{port}{path}?code=test-code&state={supplied_state}",
                        headers={"Host": host},
                    )
                    try:
                        with urlopen(request, timeout=5) as response:
                            responses.append(response.status)
                    except HTTPError as error:
                        responses.append(error.code)
                        error.close()

            thread = threading.Thread(target=callback)
            thread.start()
            threads.append(thread)
            return True

        with (
            patch.object(auth_module, "HTTPServer", server_factory),
            patch.object(auth_module.webbrowser, "open", open_browser),
            patch.object(Spotify, "token_request", return_value="test-token") as exchange,
        ):
            auth_module.connect()
            for thread in threads:
                thread.join(timeout=5)
        self.assertEqual(responses, [400, 400, 400, 400, 200])
        exchange.assert_called_once_with(
            {
                "grant_type": "authorization_code",
                "code": "test-code",
                "redirect_uri": redirects[0],
            }
        )
        self.assertEqual(read_json(self.root / "data/sign-in.json")["status"], "connected")
        self.assertEqual(servers[0].fileno(), -1)

    def test_local_callback_start_failure_is_reported(self):
        with (
            patch.object(auth_module, "HTTPServer", side_effect=OSError("test failure")),
            patch.object(auth_module.webbrowser, "open") as open_browser,
        ):
            auth_module.connect()
        open_browser.assert_not_called()
        status = read_json(self.root / "data/sign-in.json")
        self.assertEqual(status["status"], "error")
        self.assertIn("Could not start local Spotify sign-in", status["message"])


class BrowserTests(Isolated):
    def setUp(self):
        super().setUp()
        self.item = metadata.from_desktop("track", TRACK)
        for item in (self.item, self.item["album"], *self.item["artists"]):
            self.store.put_item(item)
            self.store.db.execute("INSERT INTO saved VALUES (?)", (item["uri"],))
        self.store.commit()
        write_json(
            self.root / "data/authorization.json",
            {
                "client_id": "a" * 32,
                "access_token": "test-access",
                "refresh_token": "test-refresh",
                "expires_at": time.time() + 3600,
            },
        )
        self.store.put("library:synced", time.time(), 86400)

    def test_cached_search_and_browsing_do_not_call_api(self):
        api = Spotify()
        with patch.object(api, "request", side_effect=AssertionError("network")):
            browser = Library(self.store, api)
            self.assertEqual(browser.search("bjork")[0]["uri"], self.item["uri"])
            self.assertEqual(len(browser.browse({"kind": "artists"})), 1)
            self.assertEqual(len(browser.browse(self.item["album"])), 2)

    def test_failed_sync_preserves_existing_membership(self):
        self.store.db.execute("INSERT OR IGNORE INTO saved VALUES (?)", (self.item["uri"],))
        self.store.commit()
        api = Spotify()

        def pages(path, *args, **kwargs):
            if path == "/me/playlists":
                raise SpotifyError("network unavailable")
            return iter([])

        with patch.object(api, "pages", side_effect=pages), self.assertRaises(SpotifyError):
            Library(self.store, api).sync()
        self.assertEqual(self.store.items("track", saved=True), [self.item])

    def test_navigation_filter_and_backspace(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
            session = result["variables"]["SPOTIFY_SESSION"]
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                controller.handle("activate-index", ["1"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(controller.prefix(state), "Artists/")
                controller.handle("query", ["Artists/bjork"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(len(state["rows"]), 1)
                controller.handle("query", ["Artists"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(state["stack"], [])
                self.assertEqual(len(state["rows"]), 5)

    def test_stale_background_result_cannot_replace_new_navigation(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
        session = result["variables"]["SPOTIFY_SESSION"]
        path = controller.session_path(session)
        self.store.put("desktop:scanned", True)
        original = Library.browse
        switched = False

        def browse(instance, route, query="", network=False):
            nonlocal switched
            if not switched:
                switched = True
                with controller.state_lock(path) as state:
                    state["request"] = uuid.uuid4().hex
                    state["stack"] = [{"kind": "artists"}]
            return original(instance, route, query, network)

        with patch.object(Library, "browse", browse):
            controller.worker(session)
        state = read_json(path)
        self.assertEqual(state["stack"], [{"kind": "artists"}])
        self.assertEqual(state["rows"][0]["kind"], "artist")

    def test_selection_event_never_rebuilds_the_list_that_triggered_it(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
            session = result["variables"]["SPOTIFY_SESSION"]
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                result = controller.handle("preview", [json.dumps({"item": self.item})], self.store)
        self.assertNotIn("results", result["update"]["ids"])
        self.assertIn("artwork", result["update"]["ids"])
        self.assertEqual(result["variables"]["preview_title"], "A track")

    def test_malicious_playback_uri_is_rejected_without_running_a_script(self):
        from alfred_spotify import player

        with patch.object(player, "run") as run:
            with self.assertRaises(ValueError):
                player.action("play", 'spotify:track:"; do shell script "bad"')
            run.assert_not_called()


class ConnectionTests(Isolated):
    def init_player(self):
        result = controller.init(self.store)
        session = result["variables"]["SPOTIFY_SESSION"]
        return session, controller.session_path(session)

    def test_valid_credentials_open_browser_authorization_once_on_launch(self):
        with patch("alfred_spotify.controller.spawn") as spawn:
            session, path = self.init_player()
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                controller.handle("poll", [], self.store)
                controller.handle("poll", [], self.store)
        self.assertEqual(sum(call.args == ("authorize",) for call in spawn.call_args_list), 1)
        state = read_json(path)
        self.assertEqual(state["connection"], "connecting")
        self.assertEqual(state["rows"][0]["action"], "connect")

    def test_reopening_pending_sign_in_shows_connect_without_another_automatic_tab(self):
        write_json(self.root / "data/sign-in.json", {"status": "waiting", "at": time.time()})
        with patch("alfred_spotify.controller.spawn") as spawn:
            result = controller.init(self.store)
        self.assertFalse(result["update"]["ids"]["reconnect"]["hidden"])
        state = read_json(controller.session_path(result["variables"]["SPOTIFY_SESSION"]))
        self.assertEqual(state["rows"][0]["name"], "Connect to Spotify")
        self.assertFalse(any(call.args == ("authorize",) for call in spawn.call_args_list))

    def test_connect_button_restarts_a_pending_callback_and_opens_a_fresh_tab(self):
        write_json(self.root / "data/sign-in.json", {"status": "waiting", "at": time.time()})
        with patch("alfred_spotify.controller.spawn") as spawn:
            session, path = self.init_player()
            before = read_json(path).get("authorization_generation")
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                result = controller.handle("connect", [], self.store)
                followup = controller.handle("poll", [], self.store)
        state = read_json(path)
        self.assertNotEqual(state["authorization_generation"], before)
        self.assertEqual(state["connection"], "connecting")
        self.assertFalse((self.root / "data/sign-in.json").exists())
        self.assertIn(unittest.mock.call("authorize-retry"), spawn.call_args_list)
        self.assertFalse(result["update"]["ids"]["reconnect"]["hidden"])
        self.assertNotIn("sheet", followup)

    def test_missing_credentials_show_setup_and_do_not_open_browser(self):
        with (
            patch.dict(os.environ, {"SPOTIFY_CLIENT_ID": "", "SPOTIFY_CLIENT_SECRET": ""}),
            patch("alfred_spotify.controller.spawn") as spawn,
        ):
            result = controller.init(self.store)
        self.assertIn("sheet", result)
        self.assertFalse(result["update"]["ids"]["toggle"]["enabled"])
        self.assertFalse(any(call.args == ("authorize",) for call in spawn.call_args_list))
        self.assertNotIn("Browse Cached Music", json.dumps(result))

    def test_corrupt_authorization_restarts_browser_sign_in(self):
        write_json(self.root / "data/authorization.json", ["invalid state"])
        with patch("alfred_spotify.controller.spawn") as spawn:
            session, path = self.init_player()
        self.assertEqual(read_json(path)["connection"], "connecting")
        self.assertIn(unittest.mock.call("authorize"), spawn.call_args_list)

    def test_failed_connection_blocks_browsing_and_surfaces_error_once(self):
        with patch("alfred_spotify.controller.spawn"):
            session, path = self.init_player()
            state = read_json(path)
            write_json(
                self.root / "data/sign-in.json",
                {
                    "status": "error",
                    "message": "Sign-in was cancelled",
                    "at": state["auth_started_at"] + 1,
                },
            )
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                result = controller.handle("poll", [], self.store)
                self.assertIn("Sign-in was cancelled", json.dumps(result))
                self.assertIn("sheet", result)
                self.assertNotIn("sheet", controller.handle("poll", [], self.store))
                blocked = controller.handle("query", ["music"], self.store)
                self.assertIn("sheet", blocked)
        state = read_json(path)
        self.assertEqual(state["connection"], "failed")
        self.assertFalse(state["pending"])
        self.assertTrue(all(row["action"] == "connect" for row in state["rows"]))

    def test_successful_connection_unlocks_player_and_closes_setup(self):
        with (
            patch("alfred_spotify.controller.spawn"),
            patch("alfred_spotify.player.status", return_value={"running": False}),
        ):
            session, path = self.init_player()
            state = read_json(path)
            write_json(
                self.root / "data/authorization.json",
                {
                    "client_id": "a" * 32,
                    "access_token": "test-access",
                    "refresh_token": "test-refresh",
                    "expires_at": time.time() + 3600,
                },
            )
            write_json(
                self.root / "data/sign-in.json",
                {
                    "status": "connected",
                    "at": state["auth_started_at"] + 1,
                },
            )
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                result = controller.handle("poll", [], self.store)
        self.assertEqual(result["sheet"], {"close": "setup"})
        self.assertTrue(result["update"]["ids"]["toggle"]["enabled"])
        self.assertEqual(read_json(path)["connection"], "connected")
        self.assertEqual(len(read_json(path)["rows"]), 5)

    def test_settings_use_documented_alfred_command_and_current_bundle_id(self):
        with patch("alfred_spotify.controller.subprocess.run") as run:
            run.return_value.returncode = 0
            self.assertEqual(controller.show_configuration(), {"finish": {}})
        self.assertEqual(run.call_args.args[0][-1], "com.aqsnow.alfred.spotify")
        self.assertIn("revealWorkflow", run.call_args.args[0][4])

    def test_clear_connection_preserves_credentials_and_cached_music_then_reconnects(self):
        item = metadata.from_desktop("track", TRACK)
        self.store.put_item(item)
        self.store.db.execute("INSERT INTO saved VALUES (?)", (item["uri"],))
        self.store.commit()
        self.store.put("library:synced", time.time())
        write_json(
            self.root / "data/authorization.json",
            {
                "client_id": "a" * 32,
                "access_token": "test",
                "refresh_token": "test",
                "expires_at": time.time() + 3600,
            },
        )
        write_json(self.root / "data/sign-in.json", {"status": "connected", "at": time.time()})
        controller.clear_connection(self.store)
        self.assertFalse(Spotify().connected())
        self.assertEqual(os.environ["SPOTIFY_CLIENT_ID"], "a" * 32)
        self.assertEqual(os.environ["SPOTIFY_CLIENT_SECRET"], "fake-secret")
        self.assertEqual(self.store.item(item["uri"]), item)
        self.assertIsNone(self.store.get("library:synced"))
        self.assertFalse((self.root / "data/sign-in.json").exists())
        with patch("alfred_spotify.controller.spawn") as spawn:
            self.init_player()
        self.assertIn(unittest.mock.call("authorize"), spawn.call_args_list)

    def test_clear_connection_cancels_pending_browser_authorization(self):
        from http.server import HTTPServer

        servers = []

        def server_factory(address, handler):
            server = HTTPServer(("127.0.0.1", 0), handler)
            servers.append(server)
            return server

        def open_browser(url):
            controller.clear_connection(self.store)
            return True

        with (
            patch.object(auth_module, "HTTPServer", server_factory),
            patch.object(auth_module.webbrowser, "open", open_browser),
            patch.object(Spotify, "token_request") as exchange,
        ):
            auth_module.connect()
        exchange.assert_not_called()
        self.assertFalse((self.root / "data/authorization.json").exists())
        self.assertFalse((self.root / "data/sign-in.json").exists())
        self.assertEqual(servers[0].fileno(), -1)


class PackageTests(unittest.TestCase):
    def test_package_has_native_ui_correct_launchers_and_no_private_files(self):
        root = Path(__file__).resolve().parents[1]
        path = root / "dist/Spotify.alfredworkflow"
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            self.assertFalse(
                any(
                    "authorization.json" in name or ".sqlite" in name or ".pyc" in name
                    for name in names
                )
            )
            info = plistlib.loads(archive.read("info.plist"))
            self.assertEqual(info["name"], "Spotify")
            self.assertEqual(info["description"], "Spotify Mini Player")
            self.assertEqual(info["bundleid"], "com.aqsnow.alfred.spotify")
            self.assertTrue(archive.read("icon.png").startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertFalse(
                any(name.endswith(("prefs.plist", "client-credentials.json")) for name in names)
            )
            self.assertEqual(info["connections"]["HOTKEY"][0]["destinationuid"], "PLAYER")
            self.assertIn(
                "alfred://runtrigger/com.aqsnow.alfred.spotify/clear-connection/", info["readme"]
            )
            trigger = next(o for o in info["objects"] if o["uid"] == "CLEAR_CONNECTION")
            self.assertTrue(trigger["config"]["availableviaurlhandler"])
            self.assertEqual(len(info["userconfigurationconfig"]), 2)
            self.assertEqual(
                info["variablesdontexport"], ["SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET"]
            )
            native = json.loads(archive.read("Spotify.alfredui/ui.json"))
            self.assertEqual(native["bundleid"], "com.aqsnow.alfred.spotify.player")
            self.assertIn("http://127.0.0.1/spotify_callback", info["readme"])
            self.assertTrue(native["variablesconfig"]["SPOTIFY_CLIENT_SECRET"]["scriptenv"])
            self.assertIn("Spotify.alfredui/alfred_spotify/controller.py", names)
            self.assertTrue(archive.getinfo("Spotify.alfredui/run").external_attr >> 16 & 0o111)


if __name__ == "__main__":
    unittest.main()
