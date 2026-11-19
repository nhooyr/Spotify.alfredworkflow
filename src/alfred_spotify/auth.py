"""One-time browser authorization using a short-lived loopback callback."""

import hmac
import secrets
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

from .api import REDIRECT_URI, SCOPES, Spotify, SpotifyError, credentials
from .storage import authorization_generation, data_dir, lock, write_json


def authorization_url(client_id, state, redirect_uri):
    return "https://accounts.spotify.com/authorize?" + urlencode(
        {
            "client_id": client_id,
            "response_type": "code",
            "redirect_uri": redirect_uri,
            "scope": SCOPES,
            "state": state,
        }
    )


def connect(wait_for_previous=False):
    status_path = data_dir() / "sign-in.json"
    generation = authorization_generation()

    def publish(value):
        with lock(data_dir() / "authorization.lock"):
            if generation == authorization_generation():
                write_json(status_path, value)

    with lock(data_dir() / "sign-in.lock", blocking=wait_for_previous) as acquired:
        if not acquired or generation != authorization_generation():
            return
        server = None
        try:
            client_id, _ = credentials()
            redirect = urlsplit(REDIRECT_URI)
            state = secrets.token_urlsafe(32)
            outcome = {"done": False}

            class Callback(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass  # Authorization codes must never enter logs.

                def do_GET(self):
                    parsed = urlsplit(self.path)
                    query = parse_qs(parsed.query)
                    if (
                        self.headers.get("Host") != redirect.netloc
                        or parsed.path != redirect.path
                        or not hmac.compare_digest(query.get("state", [""])[0], state)
                    ):
                        self.send_error(400, "Invalid sign-in callback")
                        return
                    try:
                        if query.get("error"):
                            raise SpotifyError(
                                "Spotify sign-in was cancelled. You can connect again anytime."
                            )
                        code = query.get("code", [""])[0]
                        if not code:
                            raise SpotifyError("Spotify did not return an authorization code.")
                        with lock(data_dir() / "authorization.lock"):
                            if generation != authorization_generation():
                                self.send_error(409, "This sign-in was cleared")
                                outcome["done"] = True
                                return
                            Spotify().token_request(
                                {
                                    "grant_type": "authorization_code",
                                    "code": code,
                                    "redirect_uri": redirect_uri,
                                }
                            )
                            write_json(status_path, {"status": "connected", "at": time.time()})
                        message = (
                            "Connected to Spotify. You can close this tab and return to Alfred."
                        )
                    except SpotifyError as error:
                        message = str(error)
                        publish({"status": "error", "message": message, "at": time.time()})
                    outcome["done"] = True
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.end_headers()
                    self.wfile.write(message.encode())

            server = HTTPServer((redirect.hostname, 0), Callback)
            redirect = redirect._replace(netloc=f"{redirect.hostname}:{server.server_port}")
            redirect_uri = redirect.geturl()
            server.timeout = 1
            publish({"status": "waiting", "at": time.time()})
            if not webbrowser.open(authorization_url(client_id, state, redirect_uri)):
                raise SpotifyError("Could not open your browser. Try connecting again.")
            deadline = time.monotonic() + 180
            while not outcome["done"] and time.monotonic() < deadline:
                if generation != authorization_generation():
                    return
                server.handle_request()
            if not outcome["done"]:
                raise SpotifyError("Spotify sign-in timed out. Choose Connect to try again.")
        except (OSError, SpotifyError) as error:
            message = (
                str(error)
                if isinstance(error, SpotifyError)
                else "Could not start local Spotify sign-in. Try connecting again."
            )
            publish({"status": "error", "message": message, "at": time.time()})
        finally:
            if server:
                server.server_close()
