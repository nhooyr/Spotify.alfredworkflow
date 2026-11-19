#!/usr/bin/env python3
"""Exercise the real native IPC with a hidden panel and a disposable parent.

Does not launch, hide, type into, or terminate Alfred or Spotify.
"""

import json
import os
import signal
import socket
import statistics
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def wait_for(function, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = function()
        if result:
            return result
        time.sleep(0.025)
    raise AssertionError("Timed out waiting for the native player")


def main():
    with tempfile.TemporaryDirectory(prefix="spotify-native-", dir="/private/tmp") as directory:
        root = Path(directory)
        with zipfile.ZipFile(ROOT / "dist/Spotify.alfredworkflow") as archive:
            archive.extractall(root)
        host = root / "Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer"
        show = root / "show"
        for executable in (host, show):
            executable.chmod(0o755)
        environment = os.environ | {"SPOTIFY_NATIVE_SOCKET_DIR": str(root / "ipc")}
        subprocess.run([host, "--validate-script"], env=environment, check=True)
        parent = subprocess.Popen(["/bin/sleep", "60"])
        server = subprocess.Popen(
            [host, "--test-server", "--lifetime-pid", str(parent.pid)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        current_pid = server.pid
        try:

            def state():
                result = subprocess.run(
                    [host, "--state"], env=environment, capture_output=True, text=True
                )
                return json.loads(result.stdout) if result.returncode == 0 else None

            initial = wait_for(state)
            timings = []
            for _ in range(50):
                start = time.perf_counter()
                subprocess.run([show], env=environment, check=True)
                timings.append((time.perf_counter() - start) * 1000)
            final = state()
            assert final["pid"] == initial["pid"] == server.pid
            assert final["panel"] == initial["panel"]
            assert final["shows"] == initial["shows"] + 50
            assert final["backend_pid"] == 0
            subprocess.run([host, "--hide"], env=environment, check=True)
            assert state()["pid"] == server.pid
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(root / "ipc/player.sock"))
                client.sendall(
                    json.dumps({"command": "benchmark", "build": initial["build"]}).encode() + b"\n"
                )
                benchmark = json.loads(client.recv(4096))
            assert benchmark["matches"] == 111
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(root / "ipc/player.sock"))
                client.sendall(
                    json.dumps({"command": "test-ui", "build": initial["build"]}).encode() + b"\n"
                )
                visuals = json.loads(client.recv(4096))
            assert visuals["text_center_error_pt"] < 0.3, visuals
            for check in (
                "same_selection_cover_stable",
                "typing_keeps_previous_cover",
                "learned_cover_reused",
                "stale_cover_ignored",
                "no_reset_button",
                "connection_errors_inline",
                "rows_align_with_cover",
                "input_above_rows",
                "compact_row_insets",
                "return_aligns_with_command",
                "search_priority",
                "signin_returns_once",
                "shortcut_digits_fit",
                "return_image_centered",
                "transport_centered_on_cover",
                "gear_aligned_with_cover",
            ):
                assert visuals[check], (check, visuals)
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(root / "ipc/player.sock"))
                client.sendall(
                    json.dumps({"command": "test-editing", "build": initial["build"]}).encode()
                    + b"\n"
                )
                editing = json.loads(client.recv(4096))
            for check in ("select_all", "undo", "redo", "word_movement", "clipboard_bindings"):
                assert editing.get(check), (check, editing)
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(root / "ipc/player.sock"))
                client.sendall(
                    json.dumps({"command": "test-controls", "build": initial["build"]}).encode()
                    + b"\n"
                )
                controls = json.loads(client.recv(4096))
            for check, passed in controls.items():
                assert passed, (check, controls)
            # The actual hotkey launcher sends a distinct command and reuses the host.
            subprocess.run([show, "--hotkey"], env=environment, check=True)
            assert state()["pid"] == initial["pid"]
            # Updating the installed executable restarts the host and retains IPC.
            os.utime(host, None)
            server.wait(timeout=6)
            restarted = wait_for(state)
            current_pid = restarted["pid"]
            assert current_pid != initial["pid"]
            subprocess.run([show], env=environment, check=True)
            # Closing the disposable parent exercises the same lifetime check as Alfred exiting.
            parent.terminate()
            parent.wait(timeout=2)
            wait_for(lambda: not (root / "ipc/player.sock").exists())
            report = {
                "show_calls": len(timings),
                "same_process_and_window": True,
                "show_client_median_ms": round(statistics.median(timings), 3),
                "show_client_p95_ms": round(sorted(timings)[47], 3),
                "filter_10000_rows_ms": round(benchmark["filter_ms"], 3),
                "row_text_centered": True,
                "preview_checks": visuals,
                "editing_checks": editing,
                "playback_controls": controls,
                "reimport_restart": True,
                "parent_exit_shutdown": True,
            }
            print(json.dumps(report, indent=2))
            Path("/private/tmp/spotify-native-performance.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=2)
            if server.poll() is None:
                server.terminate()
                server.wait(timeout=2)
            if current_pid != server.pid:
                try:
                    os.kill(current_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        # Verify the packaged host and real Python worker communicate and stay alive.
        # Missing credentials and an empty desktop fixture prevent sign-in or API calls.
        for name in ("data", "cache", "desktop"):
            (root / name).mkdir()
        isolated = environment | {
            "alfred_workflow_data": str(root / "data"),
            "alfred_workflow_cache": str(root / "cache"),
            "SPOTIFY_DESKTOP_CACHE": str(root / "desktop"),
            "SPOTIFY_CLIENT_ID": "",
            "SPOTIFY_CLIENT_SECRET": "",
        }
        parent = subprocess.Popen(["/bin/sleep", "30"])
        live = subprocess.Popen(
            [host, "--serve", "--lifetime-pid", str(parent.pid)],
            env=isolated,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            ready = wait_for(lambda: (state() or {}).get("connection") == "credentials")
            status = state()
            assert ready and status["rows"] == 1 and status["backend_pid"] > 0
            worker_pid = status["backend_pid"]
            time.sleep(0.7)
            assert state()["backend_pid"] == worker_pid
            parent.terminate()
            parent.wait(timeout=2)
            live.wait(timeout=3)

            def worker_exited():
                try:
                    os.kill(worker_pid, 0)
                except ProcessLookupError:
                    return True
                return False

            wait_for(worker_exited)
            report["resident_worker_reused"] = True
            report["worker_exit_with_panel"] = True
            print(
                json.dumps(
                    {
                        key: report[key]
                        for key in ("resident_worker_reused", "worker_exit_with_panel")
                    },
                    indent=2,
                )
            )
            Path("/private/tmp/spotify-native-performance.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=2)
            if live.poll() is None:
                live.terminate()
                live.wait(timeout=3)
        subprocess.run(
            [host, "--snapshot", "/private/tmp/spotify-native-panel.png"],
            env=environment,
            check=True,
        )


if __name__ == "__main__":
    main()
