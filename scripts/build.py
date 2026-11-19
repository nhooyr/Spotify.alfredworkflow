#!/usr/bin/env python3
"""Build the Python workflow and its small, persistent AppKit window host."""

import copy
import hashlib
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from alfred_spotify import __version__  # noqa: E402
from alfred_spotify.storage import BUNDLE_ID  # noqa: E402


def native_files():
    digest = hashlib.sha256()
    for path in sorted([*ROOT.glob("native/*"), *ROOT.glob("src/alfred_spotify/*.py")]):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    identifier = digest.hexdigest()
    with tempfile.TemporaryDirectory(prefix="spotify-build-") as directory:
        temporary = Path(directory)
        (temporary / "main.swift").write_bytes((ROOT / "native/Player.swift").read_bytes())
        (temporary / "Build.swift").write_text(
            f'enum Build {{ static let identifier = "{identifier}" }}\n'
        )
        binaries = []
        launchers = []
        for arch in ("arm64", "x86_64"):
            target = temporary / arch
            subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-O",
                    "-swift-version",
                    "5",
                    "-target",
                    f"{arch}-apple-macosx13.0",
                    "-module-cache-path",
                    str(Path(tempfile.gettempdir()) / "spotify-swift-module-cache"),
                    str(temporary / "main.swift"),
                    str(temporary / "Build.swift"),
                    "-o",
                    str(target),
                    "-framework",
                    "AppKit",
                    "-framework",
                    "Carbon",
                ],
                check=True,
            )
            binaries.append(target)
            launcher = temporary / (arch + "-show")
            subprocess.run(
                [
                    "xcrun",
                    "clang",
                    "-Os",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-arch",
                    arch,
                    "-mmacosx-version-min=13.0",
                    f'-DBUILD_ID="{identifier}"',
                    str(ROOT / "native/launcher.c"),
                    "-o",
                    str(launcher),
                ],
                check=True,
            )
            launchers.append(launcher)
        show = temporary / "show"
        subprocess.run(
            ["xcrun", "lipo", "-create", *map(str, launchers), "-output", str(show)], check=True
        )
        app = temporary / "Spotify Mini Player.app"
        executable = app / "Contents/MacOS/SpotifyMiniPlayer"
        executable.parent.mkdir(parents=True)
        subprocess.run(
            ["xcrun", "lipo", "-create", *map(str, binaries), "-output", str(executable)],
            check=True,
        )
        info = {
            "CFBundleIdentifier": BUNDLE_ID + ".player",
            "CFBundleName": "Spotify Mini Player",
            "CFBundleDisplayName": "Spotify Mini Player",
            "CFBundleExecutable": "SpotifyMiniPlayer",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": __version__,
            "CFBundleVersion": __version__,
            "LSUIElement": True,
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": True,
            "NSAppleEventsUsageDescription": "Control playback in the Spotify desktop app.",
            "CFBundleIconFile": "icon.png",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        resources = app / "Contents/Resources"
        resources.mkdir()
        (resources / "icon.png").write_bytes((ROOT / "workflow/icon.png").read_bytes())
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        return {
            "show": show.read_bytes(),
            **{
                path.relative_to(temporary).as_posix(): path.read_bytes()
                for path in app.rglob("*")
                if path.is_file()
            },
        }


def workflow_plist():
    objects = [
        {
            "uid": "OPEN",
            "type": "alfred.workflow.input.keyword",
            "version": 1,
            "config": {
                "keyword": "spotify",
                "argumenttype": 2,
                "withspace": False,
                "text": "Show Spotify Mini Player",
                "subtext": "Browse and play music",
            },
        },
        {
            "uid": "HOTKEY",
            "type": "alfred.workflow.trigger.hotkey",
            "version": 2,
            "config": {
                "hotkey": 0,
                "hotmod": 0,
                "hotstring": "",
                "action": 0,
                "argument": 0,
                "focusedappvariable": False,
                "focusedappvariablename": "",
                "leftcursor": False,
                "modsmode": 2,
                "relatedAppsMode": 0,
            },
        },
        {
            "uid": "PLAYER",
            "type": "alfred.workflow.action.script",
            "version": 2,
            "config": {
                "script": "exec ./show",
                "type": 0,
                "scriptargtype": 1,
                "scriptfile": "",
                "escaping": 0,
                "concurrently": True,
            },
        },
        {
            "uid": "REAUTH",
            "type": "alfred.workflow.input.keyword",
            "version": 1,
            "config": {
                "keyword": "spotify reauth",
                "argumenttype": 2,
                "withspace": False,
                "text": "Reset Spotify Sign-In",
                "subtext": "Clear saved login and reconnect on next open; keep client settings",
            },
        },
        {
            "uid": "CLEAR_CONNECTION",
            "type": "alfred.workflow.trigger.external",
            "version": 1,
            "config": {"triggerid": "clear-connection", "availableviaurlhandler": True},
        },
        {
            "uid": "CLEAR_ACTION",
            "type": "alfred.workflow.action.script",
            "version": 2,
            "config": {
                "script": "exec ./run clear-connection",
                "type": 0,
                "scriptargtype": 1,
                "scriptfile": "",
                "escaping": 0,
                "concurrently": False,
            },
        },
        {
            "uid": "CLEAR_NOTICE",
            "type": "alfred.workflow.output.notification",
            "version": 1,
            "config": {
                "title": "Spotify connection cleared",
                "text": "{query}",
                "lastpathcomponent": False,
                "removeextension": False,
                "onlyshowifquerypopulated": True,
            },
        },
    ]
    hotkey_action = next(obj for obj in objects if obj["uid"] == "PLAYER")
    hotkey_action = copy.deepcopy(hotkey_action)
    hotkey_action["uid"] = "HOTKEY_PLAYER"
    hotkey_action["config"]["script"] = "exec ./show --hotkey"
    objects.append(hotkey_action)
    return {
        "bundleid": BUNDLE_ID,
        "name": "Spotify",
        "category": "Productivity",
        "description": "Spotify Mini Player",
        "createdby": "Adam Quinn Snow",
        "version": __version__,
        "webaddress": "https://github.com/nhooyr/Spotify.alfredworkflow",
        "disabled": False,
        "objects": objects,
        "connections": {
            "REAUTH": [
                {
                    "destinationuid": "CLEAR_ACTION",
                    "modifiers": 0,
                    "modifiersubtext": "",
                    "vitoclose": True,
                }
            ],
            "CLEAR_CONNECTION": [
                {
                    "destinationuid": "CLEAR_ACTION",
                    "modifiers": 0,
                    "modifiersubtext": "",
                    "vitoclose": False,
                }
            ],
            "CLEAR_ACTION": [
                {
                    "destinationuid": "CLEAR_NOTICE",
                    "modifiers": 0,
                    "modifiersubtext": "",
                    "vitoclose": False,
                }
            ],
            **{
                uid: [
                    {
                        "destinationuid": "HOTKEY_PLAYER" if uid == "HOTKEY" else "PLAYER",
                        "modifiers": 0,
                        "modifiersubtext": "",
                        "vitoclose": True,
                    }
                ]
                for uid in ("OPEN", "HOTKEY")
            },
        },
        "uidata": {
            "OPEN": {"xpos": 50, "ypos": 50},
            "HOTKEY": {
                "xpos": 50,
                "ypos": 180,
                "note": "Launch Spotify Mini Player\nDouble-click to set your keyboard shortcut",
            },
            "PLAYER": {"xpos": 280, "ypos": 80},
            "HOTKEY_PLAYER": {"xpos": 280, "ypos": 210},
            "REAUTH": {"xpos": 50, "ypos": 300},
            "CLEAR_CONNECTION": {
                "xpos": 50,
                "ypos": 420,
                "note": "External reset trigger",
            },
            "CLEAR_ACTION": {"xpos": 280, "ypos": 340},
            "CLEAR_NOTICE": {"xpos": 510, "ypos": 340},
        },
        "userconfigurationconfig": [
            {
                "type": "textfield",
                "label": label,
                "variable": variable,
                "description": description,
                "config": {"default": "", "required": False, "trim": True, "placeholder": label},
            }
            for label, variable, description in (
                (
                    "Client ID",
                    "SPOTIFY_CLIENT_ID",
                    "From your Spotify Developer Dashboard app. Set its redirect URI to "
                    "http://127.0.0.1/spotify_callback (no port).",
                ),
                (
                    "Client Secret",
                    "SPOTIFY_CLIENT_SECRET",
                    "Optional. Only needed for connections imported from older builds.",
                ),
            )
        ],
        "variablesdontexport": ["SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET"],
        "readme": (ROOT / "README.md").read_text(),
    }


def build():
    source = ROOT / "workflow"
    (source / "info.plist").write_bytes(plistlib.dumps(workflow_plist(), sort_keys=False))
    excluded = {
        "prefs.plist",
        "client-credentials.json",
        "authorization.json",
        "__pycache__",
        ".DS_Store",
        ".env",
        "Spotify.alfredui",
    }
    files = native_files()
    for tree, prefix in (
        (source, Path()),
        (ROOT / "src/alfred_spotify", Path("lib/alfred_spotify")),
    ):
        for file in tree.rglob("*"):
            relative = file.relative_to(tree)
            if file.is_file() and not any(
                part in excluded or part.endswith((".pyc", ".pyo")) for part in relative.parts
            ):
                files[(prefix / relative).as_posix()] = file.read_bytes()
    files["README.md"] = (ROOT / "README.md").read_bytes()
    for image in (ROOT / "images").glob("*.png"):
        files["images/" + image.name] = image.read_bytes()
    out = ROOT / "dist/Spotify.alfredworkflow"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, contents in sorted(files.items()):
            info = zipfile.ZipInfo(name)
            info.external_attr = (
                0o100755
                if name in {"run", "show"} or name.endswith("/MacOS/SpotifyMiniPlayer")
                else 0o100644
            ) << 16
            archive.writestr(info, contents, compress_type=zipfile.ZIP_DEFLATED)
    print(out.relative_to(ROOT))


if __name__ == "__main__":
    build()
