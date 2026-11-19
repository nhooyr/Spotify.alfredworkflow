"""One-time browser authorization using a short-lived loopback callback."""

import base64
import hashlib
import hmac
import re
import secrets
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

from .api import REDIRECT_URI, SCOPES, Spotify, SpotifyError, credentials
from .storage import authorization_generation, data_dir, lock, write_json

SUCCESS_PAGE = b"""<!doctype html><meta charset="utf-8"><title>Spotify connected</title>
<p>Opening Spotify Mini Player...</p>
<script>history.replaceState(null, "", location.pathname); window.close();</script>
"""


def pkce_challenge(verifier):
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def authorization_url(client_id, state, redirect_uri, challenge):
    return "https://accounts.spotify.com/authorize?" + urlencode(
        {
            "client_id": client_id,
            "response_type": "code",
            "redirect_uri": redirect_uri,
            "scope": SCOPES,
            "state": state,
            "code_challenge_method": "S256",
            "code_challenge": challenge,
        }
    )


def authorization_error(reason):
    if not re.fullmatch(r"[a-zA-Z0-9_.-]{1,80}", reason):
        reason = "unknown_error"
    messages = {
        "server_error": "Spotify’s sign-in server encountered an error. Try Again or try later.",
        "temporarily_unavailable": "Spotify sign-in is temporarily unavailable. Try again shortly.",
        "access_denied": "Spotify did not grant access. Choose Try Again to request permission.",
        "invalid_scope": "Spotify rejected the requested permissions. Check the app configuration.",
        "invalid_client": "Spotify rejected the Client ID. Check Workflow Settings.",
    }
    message = messages.get(reason, "Spotify could not complete sign-in. Choose Try Again.")
    return SpotifyError(f"{message} ({reason})")


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
            client_id, _ = credentials(require_secret=False)
            redirect = urlsplit(REDIRECT_URI)
            state = secrets.token_urlsafe(32)
            verifier = secrets.token_urlsafe(64)
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
                            raise authorization_error(query["error"][0])
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
                                    "code_verifier": verifier,
                                    "redirect_uri": redirect_uri,
                                }
                            )
                            write_json(status_path, {"status": "connected", "at": time.time()})
                        message = None
                    except SpotifyError as error:
                        message = str(error)
                        publish({"status": "error", "message": message, "at": time.time()})
                    outcome["done"] = True
                    self.send_response(200)
                    self.send_header(
                        "Content-Type",
                        "text/html; charset=utf-8"
                        if message is None
                        else "text/plain; charset=utf-8",
                    )
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.end_headers()
                    self.wfile.write(SUCCESS_PAGE if message is None else message.encode())

            server = HTTPServer((redirect.hostname, 0), Callback)
            redirect = redirect._replace(netloc=f"{redirect.hostname}:{server.server_port}")
            redirect_uri = redirect.geturl()
            server.timeout = 1
            if not webbrowser.open(
                authorization_url(client_id, state, redirect_uri, pkce_challenge(verifier))
            ):
                raise SpotifyError("Could not open your browser. Try connecting again.")
            publish({"status": "waiting", "at": time.time()})
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
