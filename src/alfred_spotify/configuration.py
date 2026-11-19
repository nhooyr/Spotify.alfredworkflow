"""Import explicitly copied credentials into an installed workflow's settings."""

import os
import plistlib
import tempfile
from pathlib import Path

from .storage import BUNDLE_ID, data_dir, read_json, write_json

KEYS = ("SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET")
SEED = "client-credentials.json"
MARKER = ".credentials-imported.json"


def values(mapping):
    return tuple(
        value.strip() if isinstance(value, str) else ""
        for value in (mapping.get(key, "") for key in KEYS)
    )


def installed_root():
    root = Path(__file__).resolve().parents[2]
    if not root.name.startswith("user.workflow."):
        return None
    uid = os.environ.get("alfred_workflow_uid")
    if uid and uid != root.name:
        return None
    try:
        info = plistlib.loads((root / "info.plist").read_bytes())
    except OSError, ValueError, plistlib.InvalidFileException:
        return None
    return root if info.get("bundleid") == BUNDLE_ID else None


def read_preferences(root):
    try:
        prefs = plistlib.loads((root / "prefs.plist").read_bytes())
        return prefs if isinstance(prefs, dict) else {}
    except OSError, ValueError, plistlib.InvalidFileException:
        return {}


def credential_values():
    root = installed_root()
    if root:
        prefs = read_preferences(root)
        if any(key in prefs for key in KEYS) or (data_dir() / MARKER).exists():
            return values(prefs)
    configured = values(os.environ)
    if any(configured):
        return configured
    return values(read_json(data_dir() / SEED, {}))


def apply_imported_credentials():
    """Populate blank local prefs once; never put credentials in build artifacts."""
    root = installed_root()
    marker = data_dir() / MARKER
    imported = values(read_json(data_dir() / SEED, {}))
    if not root or marker.exists() or not imported[0]:
        return False
    prefs = read_preferences(root)
    if any(values(prefs)):
        write_json(marker, {"imported": False, "existing_settings_kept": True})
        return False
    prefs.update(zip(KEYS, imported, strict=True))
    fd, temporary = tempfile.mkstemp(prefix=".credentials-", dir=root)
    try:
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(prefs, stream)
        os.replace(temporary, root / "prefs.plist")
    finally:
        Path(temporary).unlink(missing_ok=True)
    write_json(marker, {"imported": True})
    return True
