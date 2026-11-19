#!/usr/bin/env python3
"""Build an importable workflow. No credentials or user caches enter the ZIP."""

import json
import plistlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from alfred_spotify import __version__  # noqa: E402
from alfred_spotify.storage import BUNDLE_ID  # noqa: E402


def script(command, *args):
    return {"type": "script", "src": "run", "args": [command, *args]}


def function(name):
    return {"type": "function", "src": "results", "args": name}


def event(action, trigger="actioned"):
    return {"triggers": trigger, "action": action}


def icon(name):
    return {"type": "symbol", "src": name}


def button(ident, symbol, command, *args, tooltip=""):
    return {
        "id": ident,
        "type": "button",
        "text": "",
        "image": icon(symbol),
        "bordered": False,
        "tooltip": tooltip,
        "constraints": {"size": {"width": 28, "height": 28}},
        "accessibility": {"label": tooltip},
        "events": [event(script(command, *args))],
    }


def ui():
    selected_text = "alfredSelectedResultTextColor"
    shortcuts = [
        {"shortcut": "↑", "action": function("selectprevious")},
        {"shortcut": "↓", "action": function("selectnext")},
        {"shortcut": "↩", "action": script("activate", "{value:results.selected}")},
        {"shortcut": "⌘[", "action": script("back")},
        {"shortcut": "⌘,", "action": script("configure")},
        {"shortcut": "⌘R", "action": script("refresh")},
        {"shortcut": "⌃⌘↓", "action": script("playback", "toggle")},
        {"shortcut": "⌃⌘→", "action": script("playback", "next")},
        {"shortcut": "⌃⌘←", "action": script("playback", "previous")},
    ]
    shortcuts += [
        {"shortcut": f"⌘{i + 1}", "action": script("activate-index", str(i))} for i in range(9)
    ]
    return {
        "bundleid": BUNDLE_ID + ".player",
        "variablesconfig": {
            name: {"src": "variable", "scriptenv": True}
            for name in (
                "SPOTIFY_CLIENT_ID",
                "SPOTIFY_CLIENT_SECRET",
                "alfred_workflow_cache",
                "alfred_workflow_data",
                "SPOTIFY_SESSION",
                "SPOTIFY_SEEN_ROWS",
                "SPOTIFY_SEEN_PREVIEW",
            )
        },
        "pulse": {"src": "run", "args": ["poll"], "interval": 1, "intervalmode": "delay"},
        "window": {
            "padding": 12,
            "size": {"height": 448},
            "root": {
                "id": "root",
                "type": "view",
                "layout": "border",
                "spacing": 10,
                "events": [event(script("init"), "preload")],
                "shortcuts": shortcuts,
                "components": [
                    {
                        "type": "view",
                        "layout": "inline",
                        "direction": "vertical",
                        "spacing": 12,
                        "constraints": {"region": "top"},
                        "components": [
                            {
                                "type": "view",
                                "layout": "border",
                                "spacing": 12,
                                "constraints": {"size": {"height": 82}},
                                "components": [
                                    {
                                        "type": "view",
                                        "layout": "stack",
                                        "constraints": {
                                            "region": "left",
                                            "size": {"width": 96, "height": 82},
                                        },
                                        "components": [
                                            {
                                                "id": "now_art",
                                                "type": "imageview",
                                                "image": icon("music.note"),
                                                "contenttintcolour": "tertiaryLabelColor",
                                                "constraints": {"size": 72, "position": "centre"},
                                            }
                                        ],
                                    },
                                    {
                                        "type": "view",
                                        "layout": "inline",
                                        "direction": "vertical",
                                        "spacing": 4,
                                        "constraints": {
                                            "region": "centre",
                                            "position": "centre",
                                            "stretch": "horizontal",
                                        },
                                        "components": [
                                            {
                                                "id": "now_title",
                                                "type": "label",
                                                "text": "No track currently selected",
                                                "font": {"size": 13},
                                            },
                                            {
                                                "id": "now_detail",
                                                "type": "label",
                                                "text": "",
                                                "colour": "secondaryLabelColor",
                                                "font": {"size": 11},
                                            },
                                        ],
                                    },
                                    {
                                        "type": "view",
                                        "layout": "inline",
                                        "direction": "horizontal",
                                        "spacing": 0,
                                        "constraints": {"region": "right", "position": "bottom"},
                                        "components": [
                                            button(
                                                "previous",
                                                "backward.fill",
                                                "playback",
                                                "previous",
                                                tooltip="Previous track",
                                            ),
                                            button(
                                                "toggle",
                                                "play.fill",
                                                "playback",
                                                "toggle",
                                                tooltip="Play or pause",
                                            ),
                                            button(
                                                "next",
                                                "forward.fill",
                                                "playback",
                                                "next",
                                                tooltip="Next track",
                                            ),
                                        ],
                                    },
                                ],
                            },
                            {
                                "id": "search",
                                "type": "textfield",
                                "text": "",
                                "placeholder": "",
                                "font": {"size": 28},
                                "bordered": False,
                                "background": None,
                                "focusring": False,
                                "focus": True,
                                "accessibility": {"label": "Search music"},
                                "events": [event(script("query", "{value:self.text}"), "changed")],
                            },
                        ],
                    },
                    {
                        "type": "view",
                        "layout": "border",
                        "spacing": 8,
                        "constraints": {"region": "centre"},
                        "components": [
                            {
                                "id": "results",
                                "type": "dataview",
                                "placeholder": "No matches",
                                "constraints": {"region": "centre"},
                                "select": "",
                                "events": [
                                    event(script("preview", "{value:self.selected}"), "changed")
                                ],
                                "cell": {
                                    "height": 25,
                                    "init": {
                                        "row.background": None,
                                        "row_title.colour": "labelColor",
                                        "row_key.colour": "secondaryLabelColor",
                                        "row_icon.contenttintcolour": "secondaryLabelColor",
                                    },
                                    "selected": {
                                        "row.background": "alfredSelectedResultBackgroundColor",
                                        "row_title.colour": "alfredSelectedResultTextColor",
                                        "row_key.colour": "alfredSelectedResultTextColor",
                                        "row_icon.contenttintcolour": selected_text,
                                        "row_key.text": "↩",
                                    },
                                    "root": {
                                        "id": "row",
                                        "type": "view",
                                        "layout": "border",
                                        "spacing": 6,
                                        "events": [
                                            event(
                                                script("activate", "{data:item}"), "doubleclicked"
                                            )
                                        ],
                                        "components": [
                                            {
                                                "id": "row_icon",
                                                "type": "imageview",
                                                "image": icon("music.note"),
                                                "constraints": {
                                                    "region": "left",
                                                    "size": 21,
                                                    "insets": {"left": 6},
                                                },
                                            },
                                            {
                                                "id": "row_title",
                                                "type": "label",
                                                "font": {"size": 16},
                                                "constraints": {
                                                    "region": "centre",
                                                    "position": "centre",
                                                    "stretch": "horizontal",
                                                },
                                            },
                                            {
                                                "id": "row_key",
                                                "type": "label",
                                                "font": {"size": 14},
                                                "constraints": {
                                                    "region": "right",
                                                    "position": "centre",
                                                    "insets": {"right": 5},
                                                },
                                            },
                                        ],
                                    },
                                },
                                "data": {"type": "basic", "src": []},
                            },
                            {
                                "type": "view",
                                "layout": "inline",
                                "direction": "vertical",
                                "spacing": 7,
                                "constraints": {
                                    "region": "right",
                                    "size": {"width": 230},
                                    "position": "top",
                                },
                                "components": [
                                    {
                                        "id": "artwork",
                                        "type": "imageview",
                                        "image": None,
                                        "contenttintcolour": "tertiaryLabelColor",
                                        "resize": "fit",
                                        "constraints": {"size": 230},
                                    },
                                    {
                                        "id": "preview_title",
                                        "type": "label",
                                        "text": "",
                                        "textalign": "centre",
                                        "font": {"size": 13},
                                    },
                                    {
                                        "id": "preview_detail",
                                        "type": "label",
                                        "text": "",
                                        "textalign": "centre",
                                        "linebreak": "wordwrap",
                                        "colour": "secondaryLabelColor",
                                        "font": {"size": 11},
                                    },
                                ],
                            },
                        ],
                    },
                    {
                        "type": "view",
                        "layout": "border",
                        "spacing": 4,
                        "constraints": {"region": "bottom"},
                        "components": [
                            {
                                "id": "status",
                                "type": "label",
                                "text": "Connect Spotify to browse your playlists",
                                "colour": "secondaryLabelColor",
                                "font": {"size": 10},
                                "constraints": {"region": "centre"},
                            },
                            {
                                "id": "reconnect",
                                "type": "button",
                                "text": "Connect",
                                "hidden": True,
                                "font": {"size": 11},
                                "constraints": {"region": "right"},
                                "events": [event(script("connect"))],
                            },
                        ],
                    },
                ],
            },
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
                "modsmode": 0,
                "relatedAppsMode": 0,
            },
        },
        {
            "uid": "PLAYER",
            "type": "alfred.workflow.userinterface.alfredui",
            "version": 1,
            "config": {"path": "Spotify.alfredui", "launchmode": 0, "stackview": False},
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
                "script": "exec ./Spotify.alfredui/run clear-connection",
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
                        "destinationuid": "PLAYER",
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
            "CLEAR_CONNECTION": {
                "xpos": 50,
                "ypos": 340,
                "note": "Clear Connection link in Configure Workflow",
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
                ("Client ID", "SPOTIFY_CLIENT_ID", "From your Spotify Developer Dashboard app."),
                (
                    "Client Secret",
                    "SPOTIFY_CLIENT_SECRET",
                    "From the same app. Set its redirect URI to "
                    "http://127.0.0.1/spotify_callback (no port).",
                ),
            )
        ],
        "variablesdontexport": ["SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET"],
        "readme": (ROOT / "README.md").read_text(),
    }


def build():
    source = ROOT / "workflow"
    (source / "Spotify.alfredui/ui.json").write_text(
        json.dumps(ui(), ensure_ascii=False, indent=2) + "\n"
    )
    (source / "info.plist").write_bytes(plistlib.dumps(workflow_plist(), sort_keys=False))
    excluded = {
        "prefs.plist",
        "client-credentials.json",
        "authorization.json",
        "__pycache__",
        ".DS_Store",
        ".env",
    }
    files = {}
    for tree, prefix in (
        (source, Path()),
        (ROOT / "src/alfred_spotify", Path("Spotify.alfredui/alfred_spotify")),
    ):
        if not tree.is_dir():
            raise FileNotFoundError(tree)
        for file in tree.rglob("*"):
            relative = file.relative_to(tree)
            if file.is_file() and not any(
                part in excluded or part.endswith((".pyc", ".pyo")) for part in relative.parts
            ):
                files[(prefix / relative).as_posix()] = file
    files["README.md"] = ROOT / "README.md"
    out = ROOT / "dist/Spotify.alfredworkflow"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, file in sorted(files.items()):
            info = zipfile.ZipInfo.from_file(file, name)
            if name == "Spotify.alfredui/run":
                info.external_attr = 0o100755 << 16
            archive.writestr(info, file.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
    (ROOT / "dist/Spotify Mini Player.alfredworkflow").unlink(missing_ok=True)
    print(out.relative_to(ROOT))


if __name__ == "__main__":
    build()
