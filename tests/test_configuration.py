import contextlib
import io
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from alfred_spotify import configuration, controller
from alfred_spotify.migration import LEGACY_BUNDLE_IDS
from alfred_spotify.storage import BUNDLE_ID, write_json


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.data = self.base / "data"
        self.root = self.base / "user.workflow.TEST"
        module = self.root / "Spotify.alfredui/alfred_spotify/configuration.py"
        module.parent.mkdir(parents=True)
        (self.root / "info.plist").write_bytes(plistlib.dumps({"bundleid": BUNDLE_ID}))
        self.env = patch.dict(
            os.environ,
            {
                "alfred_workflow_data": str(self.data),
                "alfred_workflow_uid": self.root.name,
                "SPOTIFY_CLIENT_ID": "",
                "SPOTIFY_CLIENT_SECRET": "",
            },
        )
        self.env.start()
        self.module = patch.object(configuration, "__file__", str(module))
        self.module.start()
        self.values = {"SPOTIFY_CLIENT_ID": "a" * 32, "SPOTIFY_CLIENT_SECRET": "test-secret"}
        write_json(self.data / configuration.SEED, self.values)

    def tearDown(self):
        self.module.stop()
        self.env.stop()
        self.temp.cleanup()

    def test_fills_installed_settings_and_preserves_other_preferences(self):
        prefs = self.root / "prefs.plist"
        prefs.write_bytes(plistlib.dumps({"unrelated_setting": "keep"}))
        self.assertTrue(configuration.apply_imported_credentials())
        settings = plistlib.loads(prefs.read_bytes())
        self.assertEqual(settings, self.values | {"unrelated_setting": "keep"})
        self.assertEqual(configuration.credential_values(), tuple(self.values.values()))
        self.assertEqual(prefs.stat().st_mode & 0o777, 0o600)

    def test_does_not_overwrite_existing_or_partly_configured_settings(self):
        prefs = self.root / "prefs.plist"
        prefs.write_bytes(plistlib.dumps({"SPOTIFY_CLIENT_ID": "different"}))
        self.assertFalse(configuration.apply_imported_credentials())
        self.assertEqual(configuration.credential_values(), ("different", ""))

    def test_does_not_restore_settings_after_user_clears_them(self):
        configuration.apply_imported_credentials()
        (self.root / "prefs.plist").write_bytes(plistlib.dumps({key: "" for key in self.values}))
        self.assertFalse(configuration.apply_imported_credentials())
        self.assertEqual(configuration.credential_values(), ("", ""))

    def test_never_writes_credentials_into_source_or_staging_tree(self):
        module = self.base / "build/Spotify/Spotify.alfredui/alfred_spotify/configuration.py"
        module.parent.mkdir(parents=True)
        with patch.object(configuration, "__file__", str(module)):
            self.assertFalse(configuration.apply_imported_credentials())
        self.assertFalse((self.base / "build/Spotify/prefs.plist").exists())

    def test_first_launch_migrates_credentials_before_filling_settings(self):
        (self.data / configuration.SEED).unlink()
        legacy = self.data.parent / LEGACY_BUNDLE_IDS[0]
        write_json(legacy / configuration.SEED, self.values)
        with (
            patch.dict(os.environ, {"alfred_workflow_cache": str(self.base / "cache" / BUNDLE_ID)}),
            patch.object(controller, "handle", return_value={}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            controller.main(["init"])
        self.assertEqual(plistlib.loads((self.root / "prefs.plist").read_bytes()), self.values)
        self.assertTrue((self.data / configuration.MARKER).is_file())


if __name__ == "__main__":
    unittest.main()
