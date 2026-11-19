import importlib.util
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
from urllib.parse import parse_qs, urlencode, urlsplit
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
        self.no_background = patch("alfred_spotify.controller.spawn")
        self.no_background.start()
        self.no_artwork_network = patch(
            "alfred_spotify.desktop.urlopen", side_effect=OSError("offline test")
        )
        self.no_artwork_network.start()
        self.store = Store()

    def tearDown(self):
        self.store.close()
        self.no_artwork_network.stop()
        self.no_background.stop()
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

    def test_mosaic_playlist_cover_reuses_desktop_cache(self):
        url = "https://mosaic.scdn.co/640/" + "a" * 40
        jpeg = b"\xff\xd8\xffplaylist mosaic"
        cache_file(self.cache / "mosaic_0", url, jpeg)
        desktop.index(self.store)
        with patch("alfred_spotify.desktop.urlopen", side_effect=AssertionError("network")):
            path = desktop.image(self.store, url, download=True)
        self.assertEqual(Path(path).read_bytes(), jpeg)

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

    def test_pkce_exchange_and_refresh_use_client_id_without_client_secret(self):
        requests = []

        def opener(request, **kwargs):
            requests.append(request)
            self.assertIsNone(request.get_header("Authorization"))
            fields = parse_qs(request.data.decode())
            self.assertEqual(fields["client_id"], ["a" * 32])
            self.assertNotIn("client_secret", fields)
            if fields["grant_type"] == ["authorization_code"]:
                self.assertEqual(fields["code_verifier"], ["test-verifier"])
                return io.BytesIO(
                    b'{"access_token":"pkce-access","refresh_token":"pkce-refresh",'
                    b'"expires_in":3600}'
                )
            self.assertEqual(fields["grant_type"], ["refresh_token"])
            self.assertEqual(fields["refresh_token"], ["pkce-refresh"])
            self.assertNotIn("code_verifier", fields)
            return io.BytesIO(b'{"access_token":"pkce-renewed","expires_in":3600}')

        client = Spotify(opener)
        self.assertEqual(
            client.token_request(
                {
                    "grant_type": "authorization_code",
                    "code": "test-code",
                    "code_verifier": "test-verifier",
                    "redirect_uri": "http://127.0.0.1:49152/spotify_callback",
                }
            ),
            "pkce-access",
        )
        with patch.dict(os.environ, {"SPOTIFY_CLIENT_SECRET": ""}):
            self.assertEqual(client.access_token(force=True), "pkce-renewed")
        token = read_json(self.root / "data/authorization.json")
        self.assertTrue(token["pkce"])
        self.assertEqual(token["refresh_token"], "pkce-refresh")
        self.assertNotIn("code_verifier", token)
        self.assertNotIn("client_secret", token)
        self.assertEqual(len(requests), 2)

    def test_pkce_challenge_matches_rfc_7636_example(self):
        verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        self.assertEqual(auth_module.pkce_challenge(verifier), expected)

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
        url = authorization_url("a" * 32, "random-state", redirect_uri, "test-challenge")
        args = parse_qs(urlsplit(url).query)
        self.assertEqual(args["state"], ["random-state"])
        self.assertEqual(args["code_challenge_method"], ["S256"])
        self.assertEqual(args["code_challenge"], ["test-challenge"])
        self.assertEqual(args["redirect_uri"], [redirect_uri])
        self.assertNotIn("fake-secret", url)

    def test_callback_uses_assigned_port_and_rejects_wrong_host_path_and_state(self):
        from http.server import HTTPServer

        servers = []
        threads = []
        responses = []
        redirects = []
        challenges = []
        response_bodies = []

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
            challenges.append(args["code_challenge"][0])
            self.assertEqual(args["code_challenge_method"], ["S256"])
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
                            response_bodies.append(response.read())
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
        self.assertIn(b"window.close()", response_bodies[-1])
        self.assertNotIn(b"test-code", response_bodies[-1])
        self.assertNotIn(b"You can close this tab", response_bodies[-1])
        exchange.assert_called_once()
        fields = exchange.call_args.args[0]
        self.assertRegex(fields["code_verifier"], r"^[a-zA-Z0-9_-]{43,128}$")
        self.assertEqual(auth_module.pkce_challenge(fields["code_verifier"]), challenges[0])
        self.assertEqual(
            fields,
            {
                "grant_type": "authorization_code",
                "code": "test-code",
                "code_verifier": fields["code_verifier"],
                "redirect_uri": redirects[0],
            },
        )
        self.assertEqual(read_json(self.root / "data/sign-in.json")["status"], "connected")
        self.assertEqual(servers[0].fileno(), -1)

    def test_callback_preserves_spotify_server_error_instead_of_reporting_cancellation(self):
        from http.server import HTTPServer

        threads = []
        pages = []

        def open_browser(url):
            params = parse_qs(urlsplit(url).query)
            callback_url = (
                params["redirect_uri"][0]
                + "?"
                + urlencode(
                    {
                        "error": "server_error",
                        "state": params["state"][0],
                        "ubi": "private-diagnostic-value",
                    }
                )
            )

            def callback():
                with urlopen(callback_url, timeout=5) as response:
                    pages.append(response.read().decode())

            thread = threading.Thread(target=callback)
            thread.start()
            threads.append(thread)
            return True

        with (
            patch.object(auth_module, "HTTPServer", HTTPServer),
            patch.object(auth_module.webbrowser, "open", open_browser),
            patch.object(Spotify, "token_request") as exchange,
        ):
            auth_module.connect()
            for thread in threads:
                thread.join(timeout=5)
        exchange.assert_not_called()
        status = read_json(self.root / "data/sign-in.json")
        self.assertEqual(status["status"], "error")
        self.assertIn("server_error", status["message"])
        self.assertIn("Try Again", status["message"])
        self.assertNotIn("cancelled", status["message"])
        self.assertEqual(pages, [status["message"]])
        self.assertNotIn("private-diagnostic-value", json.dumps(status))
        self.assertFalse((self.root / "data/authorization.json").exists())

    def test_authorization_errors_distinguish_denied_access_and_invalid_permissions(self):
        denied = str(auth_module.authorization_error("access_denied"))
        permissions = str(auth_module.authorization_error("invalid_scope"))
        self.assertIn("did not grant access", denied)
        self.assertIn("requested permissions", permissions)
        self.assertNotIn("cancelled", permissions)
        self.assertIn("unknown_error", str(auth_module.authorization_error("bad\nerror")))

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

    def test_home_menu_order_is_playlists_albums_artists_songs(self):
        rows = Library(self.store, Spotify()).browse({"kind": "home"})
        self.assertEqual([row["name"] for row in rows], ["Playlists", "Albums", "Artists", "Songs"])

    def test_songs_contains_only_liked_tracks_even_before_library_sync(self):
        unliked = self.item | {"uri": "spotify:track:cached-only", "name": "Cached only"}
        self.store.put_item(unliked)
        self.store.commit()
        browser = Library(self.store, Spotify())
        for synced in (True, False):
            with self.subTest(synced=synced):
                if not synced:
                    self.store.db.execute("DELETE FROM responses WHERE key='library:synced'")
                    self.store.commit()
                with patch.object(
                    browser.spotify, "request", side_effect=AssertionError("network")
                ):
                    songs = browser.browse({"kind": "songs"})
                self.assertEqual([song["uri"] for song in songs], [self.item["uri"]])

    def test_selecting_song_plays_liked_track(self):
        with (
            patch("alfred_spotify.controller.spawn"),
            patch("alfred_spotify.player.action") as play,
        ):
            result = controller.init(self.store)
            with patch.dict(
                os.environ, {"SPOTIFY_SESSION": result["variables"]["SPOTIFY_SESSION"]}
            ):
                controller.handle("activate-index", ["3"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(controller.prefix(state), "Songs/")
                controller.handle("activate", [json.dumps(state["rows"][0])], self.store)
        play.assert_called_once_with("play", self.item["uri"], "")

    def test_cached_search_and_browsing_do_not_call_api(self):
        api = Spotify()
        with patch.object(api, "request", side_effect=AssertionError("network")):
            browser = Library(self.store, api)
            self.assertEqual(browser.search("bjork")[0]["uri"], self.item["album"]["uri"])
            self.assertEqual(len(browser.browse({"kind": "artists"})), 1)
            self.assertEqual(len(browser.browse(self.item["album"])), 2)

    def test_search_groups_playlists_albums_artists_and_tracks(self):
        for kind in ("track", "artist", "playlist", "album"):
            self.store.put_item(
                {"uri": "spotify:" + kind + ":priority", "kind": kind, "name": "Priority match"}
            )
        self.store.commit()
        rows = Library(self.store, Spotify()).search("priority")
        self.assertEqual([item["kind"] for item in rows], ["playlist", "album", "artist", "track"])

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
                controller.handle("activate-index", ["2"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(controller.prefix(state), "Artists/")
                controller.handle("query", ["Artists/bjork"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(len(state["rows"]), 1)
                controller.handle("query", ["Artists"], self.store)
                state = read_json(controller.session_path())
                self.assertEqual(state["stack"], [])
                self.assertEqual(len(state["rows"]), 4)

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

    def test_home_rows_have_unique_ids_and_enter_can_activate_the_selection(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
            self.assertEqual(len({r["uid"] for r in result["variables"]["browser_rows"]}), 4)
            with patch.dict(
                os.environ, {"SPOTIFY_SESSION": result["variables"]["SPOTIFY_SESSION"]}
            ):
                controller.handle(
                    "activate",
                    [json.dumps(result["variables"]["browser_rows"][0]["item"])],
                    self.store,
                )
                self.assertEqual(
                    controller.prefix(read_json(controller.session_path())), "Playlists/"
                )

    def test_typing_filters_natively_without_rebuilding_or_rewriting_the_session(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
            with patch.dict(
                os.environ, {"SPOTIFY_SESSION": result["variables"]["SPOTIFY_SESSION"]}
            ):
                first = controller.handle("query", ["b"], self.store)
                provider = first["update"]["ids"]["results"]["data"]
                self.assertEqual(provider["filter"]["matchmode"], "wordmatchanyorder")
                before = controller.session_path().read_bytes()
                with patch(
                    "alfred_spotify.controller.request", side_effect=AssertionError("rebuilt")
                ):
                    self.assertEqual(controller.handle("query", ["bjork"], self.store), {})
                self.assertEqual(controller.session_path().read_bytes(), before)

    def test_initial_category_preview_uses_cached_art_without_a_selection_event(self):
        playlist = {
            "uri": "spotify:playlist:cached",
            "kind": "playlist",
            "name": "Cached playlist",
            "image": self.item["image"],
        }
        self.store.put_item(playlist)
        self.store.db.execute("INSERT INTO saved VALUES (?)", (playlist["uri"],))
        self.store.commit()
        jpeg = b"\xff\xd8\xffinitial cover"
        cache_file(self.cache / "initial_0", self.item["image"], jpeg)
        desktop.index(self.store)
        result = controller.init(self.store)
        self.assertEqual(Path(result["variables"]["preview_art"]["src"]).read_bytes(), jpeg)
        state = read_json(controller.session_path(result["variables"]["SPOTIFY_SESSION"]))
        self.assertEqual(state["preview_image"], self.item["image"])

    def test_thin_rows_keep_playlist_playback_context(self):
        item = self.item | {"context": "spotify:playlist:1234567890123456789012"}
        payload = controller.row_data(item, 0)["item"]
        with patch.dict(os.environ, {"SPOTIFY_SESSION": uuid.uuid4().hex}):
            with patch("alfred_spotify.player.action") as play:
                controller.handle("activate", [json.dumps(payload)], self.store)
        play.assert_called_once_with("play", self.item["uri"], item["context"])

    def test_large_datasets_do_not_bloat_the_mutable_session(self):
        rows = [self.item | {"uri": f"spotify:track:{i}"} for i in range(100)]
        state = {"session": uuid.uuid4().hex}
        controller.set_rows(state, rows)
        self.assertEqual(len(state["rows"]), 9)
        self.assertEqual(controller.rows_in(state), rows)

    def test_warm_search_reuses_prepared_rows_and_keeps_enter_correct_after_filtering(self):
        with patch("alfred_spotify.controller.spawn"):
            controller.warm_search(self.store)
            result = controller.init(self.store)
            with patch.dict(
                os.environ, {"SPOTIFY_SESSION": result["variables"]["SPOTIFY_SESSION"]}
            ):
                with patch.object(
                    self.store, "display_items", side_effect=AssertionError("rescanned")
                ):
                    result = controller.handle("query", ["bjork"], self.store)
                self.assertTrue(result["variables"]["browser_rows"])
                self.assertEqual(result["functions"]["ids"]["results"], "filterdata")
                row = next(
                    r for r in result["variables"]["browser_rows"] if r["item"]["kind"] == "track"
                )
                with patch("alfred_spotify.player.action") as play:
                    controller.handle("activate", [json.dumps(row["item"])], self.store)
                play.assert_called_once_with("play", self.item["uri"], "")

    def test_failed_sync_cannot_expose_warmed_search_results(self):
        controller.warm_search(self.store)
        result = controller.init(self.store)
        session = result["variables"]["SPOTIFY_SESSION"]
        with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
            controller.handle("query", ["bjork"], self.store)
        with controller.state_lock(controller.session_path(session)) as state:
            state["sync"] = True
        with patch.object(
            Library, "sync", side_effect=SpotifyError("Connection expired", status=401)
        ):
            controller.worker(session)
        state = read_json(controller.session_path(session))
        self.assertEqual(state["connection"], "failed")
        self.assertNotIn("search_snapshot", state)
        self.assertEqual(state["rows"][0]["action"], "connect")

    def test_filtered_shortcut_uses_visible_row_and_missing_selection_does_nothing(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
            with patch.dict(
                os.environ, {"SPOTIFY_SESSION": result["variables"]["SPOTIFY_SESSION"]}
            ):
                controller.handle("query", ["a track"], self.store)
                with patch("alfred_spotify.player.action") as play:
                    controller.handle("activate-index", ["0", "a track"], self.store)
                    play.assert_called_once_with("play", self.item["uri"], "")
                    controller.handle("activate", [""], self.store)
                    self.assertEqual(play.call_count, 1)

    def test_search_song_dispatches_before_session_or_network_work(self):
        with patch.dict(os.environ, {"SPOTIFY_SESSION": uuid.uuid4().hex}):
            with (
                patch(
                    "alfred_spotify.controller.state_lock",
                    side_effect=AssertionError("session lock"),
                ),
                patch("alfred_spotify.player.status", side_effect=AssertionError("status query")),
                patch(
                    "alfred_spotify.desktop.urlopen", side_effect=AssertionError("artwork download")
                ),
                patch("alfred_spotify.player.action") as play,
            ):
                result = controller.handle(
                    "activate", [json.dumps({"uri": self.item["uri"], "kind": "track"})], self.store
                )
        play.assert_called_once_with("play", self.item["uri"], "")
        self.assertEqual(result["variables"]["now_title"], self.item["name"])
        self.assertEqual(result["variables"]["play_symbol"]["src"], "pause.fill")

    def test_pause_updates_icon_without_waiting_for_spotify_status(self):
        self.store.put("now-playing", {"playing": True, "name": "Playing"}, 10)
        with (
            patch.dict(os.environ, {"SPOTIFY_SESSION": uuid.uuid4().hex}),
            patch("alfred_spotify.player.action") as play,
            patch("alfred_spotify.player.status", side_effect=AssertionError("status query")),
        ):
            result = controller.handle("playback", ["toggle"], self.store)
        play.assert_called_once_with("toggle")
        self.assertEqual(
            result["variables"]["play_symbol"],
            {"type": "symbol", "src": "play.fill", "size": {"height": 18}},
        )

    def test_cover_load_precedes_slow_library_sync(self):
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
        session = result["variables"]["SPOTIFY_SESSION"]
        events = []
        self.store.db.execute("DELETE FROM responses WHERE key='library:synced'")
        self.store.commit()
        with (
            patch(
                "alfred_spotify.controller.load_preview",
                side_effect=lambda *args, **kwargs: events.append("cover"),
            ),
            patch("alfred_spotify.desktop.index"),
            patch(
                "alfred_spotify.library.Library.sync",
                side_effect=lambda *args: events.append("sync"),
            ),
        ):
            controller.worker(session)
        self.assertEqual(events[:3], ["cover", "cover", "sync"])

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

    def test_async_start_ignores_events_until_session_is_ready(self):
        with patch.dict(os.environ, {"SPOTIFY_SESSION": ""}):
            self.assertEqual(controller.handle("poll", [], self.store), {})
            self.assertEqual(controller.handle("activate-index", ["0"], self.store), {})
        with patch("alfred_spotify.controller.spawn"):
            result = controller.init(self.store)
        self.assertTrue(controller.session_path(result["variables"]["SPOTIFY_SESSION"]).exists())
        self.assertEqual(result["pulse"], {"interval": 0.1})
        self.assertTrue(result["update"]["ids"]["results"]["enabled"])

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

    def test_client_id_alone_can_start_pkce_sign_in(self):
        with (
            patch.dict(os.environ, {"SPOTIFY_CLIENT_SECRET": ""}),
            patch("alfred_spotify.controller.spawn") as spawn,
        ):
            _, path = self.init_player()
        self.assertEqual(read_json(path)["connection"], "connecting")
        self.assertIn(unittest.mock.call("authorize"), spawn.call_args_list)

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

    def test_initial_sign_in_and_connect_both_show_connection_dialog(self):
        with patch("alfred_spotify.controller.spawn"):
            initial = controller.init(self.store)
            session = initial["variables"]["SPOTIFY_SESSION"]
            with patch.dict(os.environ, {"SPOTIFY_SESSION": session}):
                retry = controller.handle("connect", [], self.store)
        for result in (initial, retry):
            sheet = result["sheet"]
            self.assertEqual(sheet["id"], "setup")
            self.assertEqual(sheet["root"]["components"][0]["text"], "Connecting to Spotify")
            buttons = sheet["root"]["components"][-1]["components"]
            self.assertEqual(
                [button["text"] for button in buttons],
                ["Connect", "Workflow Settings…", "Close Player"],
            )

    def test_close_player_action_dismisses_dialog_and_finishes_without_clearing_sign_in(self):
        waiting = {"status": "waiting", "at": time.time()}
        write_json(self.root / "data/sign-in.json", waiting)
        for state in ("credentials", "connecting", "failed", "cleared"):
            with self.subTest(state=state):
                sheet = controller.connection_sheet({"connection": state})
                buttons = sheet["root"]["components"][-1]["components"]
                close_button = next(
                    button for button in buttons if button["text"] == "Close Player"
                )
                event = close_button["events"][0]
                self.assertEqual(event["triggers"], "actioned")
                self.assertEqual(event["action"]["type"], "json")
                self.assertEqual(
                    event["action"]["src"],
                    {"sheet": {"close": sheet["id"]}, "finish": {"args": ""}},
                )
        self.assertEqual(read_json(self.root / "data/sign-in.json"), waiting)

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
        self.assertEqual(len(read_json(path)["rows"]), 4)

    def test_settings_use_documented_alfred_command_and_current_bundle_id(self):
        with patch("alfred_spotify.controller.subprocess.run") as run:
            run.return_value.returncode = 0
            self.assertEqual(
                controller.show_configuration(),
                {"sheet": {"close": "setup"}, "finish": {"args": ""}},
            )
        self.assertEqual(run.call_args.args[0][-1], "ca.aqsnow.alfred.spotify")
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
    def test_direct_build_excludes_private_files_without_staging(self):
        source_root = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location(
            "workflow_build", source_root / "scripts/build.py"
        )
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures = {
                "README.md": "Fixture workflow",
                "workflow/run": "#!/bin/sh\nexit 0\n",
                "workflow/icon.png": "fixture icon",
                "workflow/prefs.plist": "private preferences",
                "workflow/Spotify.alfredui/ui.json": "old embedded UI",
                "workflow/nested/client-credentials.json": "private credentials",
                "src/alfred_spotify/__init__.py": "# fixture package",
                "src/alfred_spotify/controller.py": "# fixture controller",
                "src/alfred_spotify/__pycache__/controller.pyc": "compiled bytecode",
                "src/alfred_spotify/.env": "private environment",
            }
            for name, contents in fixtures.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            native = {
                "show": b"native launcher",
                "Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer": b"native host",
            }
            with (
                patch.object(builder, "ROOT", root),
                patch.object(builder, "native_files", return_value=native),
                patch("builtins.print") as output,
            ):
                builder.build()
            output.assert_called_once_with(Path("dist/Spotify.alfredworkflow"))
            self.assertFalse((root / "build").exists())
            with zipfile.ZipFile(root / "dist/Spotify.alfredworkflow") as archive:
                self.assertEqual(
                    set(archive.namelist()),
                    {
                        "README.md",
                        "info.plist",
                        "icon.png",
                        "run",
                        "show",
                        "Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer",
                        "lib/alfred_spotify/__init__.py",
                        "lib/alfred_spotify/controller.py",
                    },
                )
                for name in (
                    "run",
                    "show",
                    "Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer",
                ):
                    self.assertEqual(archive.getinfo(name).external_attr >> 16 & 0o777, 0o755)

    def test_package_uses_native_show_client_and_preserves_settings(self):
        root = Path(__file__).resolve().parents[1]
        with zipfile.ZipFile(root / "dist/Spotify.alfredworkflow") as archive:
            names = archive.namelist()
            self.assertFalse(
                any(
                    "authorization.json" in name
                    or ".sqlite" in name
                    or ".pyc" in name
                    or "Spotify.alfredui" in name
                    for name in names
                )
            )
            info = plistlib.loads(archive.read("info.plist"))
            self.assertEqual(info["name"], "Spotify")
            self.assertEqual(info["description"], "Spotify Mini Player")
            self.assertEqual(info["bundleid"], "ca.aqsnow.alfred.spotify")
            self.assertEqual(info["createdby"], "Adam Quinn Snow")
            self.assertTrue(archive.read("icon.png").startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(info["connections"]["HOTKEY"][0]["destinationuid"], "HOTKEY_PLAYER")
            hotkey_action = next(item for item in info["objects"] if item["uid"] == "HOTKEY_PLAYER")
            self.assertEqual(hotkey_action["config"]["script"], "exec ./show --hotkey")
            hotkey = next(item for item in info["objects"] if item["uid"] == "HOTKEY")
            self.assertEqual(hotkey["config"]["argument"], 0)
            self.assertEqual(hotkey["config"]["modsmode"], 2)
            player = next(item for item in info["objects"] if item["uid"] == "PLAYER")
            self.assertEqual(player["type"], "alfred.workflow.action.script")
            self.assertEqual(player["config"]["script"], "exec ./show")
            self.assertTrue(player["config"]["concurrently"])
            self.assertEqual(len(info["userconfigurationconfig"]), 2)
            self.assertEqual(
                info["variablesdontexport"], ["SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET"]
            )
            refresh = next(item for item in info["objects"] if item["uid"] == "REAUTH")
            self.assertEqual(refresh["config"]["keyword"], "spotify reauth")
            self.assertEqual(info["connections"]["REAUTH"][0]["destinationuid"], "CLEAR_ACTION")
            self.assertIn("spotify reauth", info["readme"])
            self.assertIn("lib/alfred_spotify/resident.py", names)
            app = plistlib.loads(archive.read("Spotify Mini Player.app/Contents/Info.plist"))
            self.assertTrue(app["LSUIElement"])
            self.assertEqual(app["CFBundleIdentifier"], "ca.aqsnow.alfred.spotify.player")
            self.assertIn("NSAppleEventsUsageDescription", app)
            # Both binaries must be universal Mach-O, including the fast client.
            for name in ("show", "Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer"):
                self.assertEqual(archive.read(name)[:4], bytes.fromhex("cafebabe"))


if __name__ == "__main__":
    unittest.main()
