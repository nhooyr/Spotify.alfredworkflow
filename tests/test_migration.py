import tempfile
import unittest
from pathlib import Path

from alfred_spotify.configuration import SEED
from alfred_spotify.migration import LEGACY_BUNDLE_IDS, MARKER, migrate
from alfred_spotify.storage import BUNDLE_ID, Store, read_json, write_json


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.old_data = root / "data" / LEGACY_BUNDLE_IDS[0]
        self.data = root / "data" / BUNDLE_ID
        self.old_cache = root / "cache" / LEGACY_BUNDLE_IDS[0]
        self.cache = root / "cache" / BUNDLE_ID
        self.old_data.mkdir(parents=True)
        self.old_cache.mkdir(parents=True)
        self.token = {
            "client_id": "test-client",
            "access_token": "test-access",
            "refresh_token": "test-refresh",
            "expires_at": 9999999999,
        }
        self.credentials = {"SPOTIFY_CLIENT_ID": "test-client", "SPOTIFY_CLIENT_SECRET": "secret"}
        write_json(self.old_data / SEED, self.credentials)
        write_json(self.old_data / "authorization.json", self.token)
        write_json(self.old_data / "sign-in.json", {"status": "waiting"})
        (self.old_data / "authorization.lock").touch()
        self.item = {"uri": "spotify:track:test", "kind": "track", "name": "Cached Track"}
        self.old = Store(self.old_cache / "index.sqlite3")
        self.old.db.execute("PRAGMA journal_mode=WAL")
        self.old.put_item(self.item)
        self.old.db.execute("INSERT INTO saved VALUES (?)", (self.item["uri"],))
        self.old.db.execute("INSERT INTO desktop VALUES ('cached-image', 1, 'image-url', 24, 100)")
        self.old.put("library:synced", 123, 86400)
        self.old.put("desktop:scanned", True, 86400)
        (self.old_cache / "artwork").mkdir()
        (self.old_cache / "artwork/cover.img").write_bytes(b"cached-cover")
        (self.old_cache / "sessions").mkdir()
        write_json(self.old_cache / "sessions/old-session.json", {"pending": True})

    def tearDown(self):
        self.old.close()
        self.temp.cleanup()

    def test_copies_live_sqlite_authorization_and_artwork_without_old_sessions(self):
        report = migrate(self.data, self.cache)
        self.assertEqual(report["errors"], [])
        self.assertTrue(report["authorization"])
        self.assertTrue(report["credentials"])
        self.assertEqual(read_json(self.data / SEED), self.credentials)
        self.assertEqual((self.data / SEED).stat().st_mode & 0o777, 0o600)
        self.assertEqual(report["source"], LEGACY_BUNDLE_IDS[0])
        self.assertEqual(report["artwork"], 1)
        self.assertEqual(read_json(self.data / "authorization.json"), self.token)
        self.assertEqual((self.data / "authorization.json").stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.data / "sign-in.json").exists())
        self.assertFalse((self.cache / "sessions").exists())
        self.assertEqual((self.cache / "artwork/cover.img").read_bytes(), b"cached-cover")
        new = Store(self.cache / "index.sqlite3")
        try:
            self.assertEqual(new.item(self.item["uri"]), self.item)
            self.assertEqual(new.items(saved=True), [self.item])
            self.assertEqual(new.get("library:synced"), 123)
            self.assertEqual(new.db.execute("SELECT count(*) FROM desktop").fetchone()[0], 1)
        finally:
            new.close()
        self.assertEqual(read_json(self.old_data / "authorization.json"), self.token)
        self.assertEqual(self.old.item(self.item["uri"]), self.item)
        self.assertTrue((self.old_cache / "sessions/old-session.json").exists())

    def test_keeps_newer_destination_data_and_does_not_mix_accounts(self):
        self.data.mkdir(parents=True)
        self.cache.mkdir(parents=True)
        newer_token = self.token | {"access_token": "new-account-access"}
        write_json(self.data / "authorization.json", newer_token)
        newer_credentials = self.credentials | {"SPOTIFY_CLIENT_SECRET": "newer-secret"}
        write_json(self.data / SEED, newer_credentials)
        new = Store(self.cache / "index.sqlite3")
        new.put_item(self.item | {"name": "Newer Track"})
        new.put("library:synced", 456, 86400)
        new.close()
        (self.cache / "artwork").mkdir()
        (self.cache / "artwork/cover.img").write_bytes(b"newer-cover")
        report = migrate(self.data, self.cache)
        self.assertFalse(report["authorization"])
        self.assertEqual(read_json(self.data / "authorization.json"), newer_token)
        self.assertFalse(report["credentials"])
        self.assertEqual(read_json(self.data / SEED), newer_credentials)
        self.assertEqual((self.cache / "artwork/cover.img").read_bytes(), b"newer-cover")
        new = Store(self.cache / "index.sqlite3")
        try:
            self.assertEqual(new.item(self.item["uri"])["name"], "Newer Track")
            self.assertEqual(new.get("library:synced"), 456)
            self.assertEqual(new.items(saved=True), [])
        finally:
            new.close()

    def test_runs_once_and_does_not_undo_clear_connection(self):
        migrate(self.data, self.cache)
        (self.data / "authorization.json").unlink()
        (self.data / SEED).unlink()
        write_json(self.data / "authorization-generation.json", {"id": "cleared"})
        report = migrate(self.data, self.cache)
        self.assertTrue(report["already_imported"])
        self.assertFalse((self.data / "authorization.json").exists())
        self.assertTrue((self.data / MARKER).exists())
        self.assertFalse((self.data / SEED).exists())

    def test_does_not_restore_authorization_cleared_before_first_import(self):
        self.data.mkdir(parents=True)
        write_json(self.data / "authorization-generation.json", {"id": "cleared"})
        report = migrate(self.data, self.cache)
        self.assertFalse(report["authorization"])
        self.assertFalse((self.data / "authorization.json").exists())
        new = Store(self.cache / "index.sqlite3")
        try:
            self.assertIsNotNone(new.item(self.item["uri"]))
            self.assertEqual(new.items(saved=True), [])
            self.assertIsNone(new.get("library:synced"))
        finally:
            new.close()

    def test_newest_source_clear_takes_precedence_over_original_authorization(self):
        original_data = self.data.parent / LEGACY_BUNDLE_IDS[1]
        write_json(original_data / "authorization.json", self.token)
        (self.old_data / "authorization.json").unlink()
        write_json(self.old_data / "authorization-generation.json", {"id": "source-cleared"})
        report = migrate(self.data, self.cache)
        self.assertEqual(report["source"], LEGACY_BUNDLE_IDS[0])
        self.assertFalse(report["authorization"])
        self.assertFalse((self.data / "authorization.json").exists())
        self.assertEqual(
            read_json(self.data / "authorization-generation.json"), {"id": "source-cleared"}
        )
        new = Store(self.cache / "index.sqlite3")
        try:
            self.assertIsNotNone(new.item(self.item["uri"]))
            self.assertEqual(new.items(saved=True), [])
        finally:
            new.close()

    def test_falls_back_to_original_bundle_when_newer_source_is_absent(self):
        self.old.close()
        original_data = self.old_data.with_name(LEGACY_BUNDLE_IDS[1])
        original_cache = self.old_cache.with_name(LEGACY_BUNDLE_IDS[1])
        self.old_data.rename(original_data)
        self.old_cache.rename(original_cache)
        self.old = Store(original_cache / "index.sqlite3")
        report = migrate(self.data, self.cache)
        self.assertEqual(report["source"], LEGACY_BUNDLE_IDS[1])
        self.assertTrue(report["authorization"])
        self.assertEqual(read_json(self.data / "authorization.json"), self.token)
        self.assertEqual((self.cache / "artwork/cover.img").read_bytes(), b"cached-cover")


if __name__ == "__main__":
    unittest.main()
