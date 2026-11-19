"""Spotify Web API with PKCE and support for older confidential-client tokens."""

import base64
import json
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

from .configuration import credential_values
from .storage import data_dir, lock, read_json, write_json

REDIRECT_URI = "http://127.0.0.1/spotify_callback"
SCOPES = (
    "user-library-read user-library-modify "
    "playlist-read-private playlist-read-collaborative user-follow-read"
)


class SpotifyError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def credentials(require_secret=True):
    client_id, secret = credential_values()
    if not re.fullmatch(r"[a-fA-F0-9]{32}", client_id) or (require_secret and not secret):
        fields = "Client ID and Client Secret" if require_secret else "Client ID"
        raise SpotifyError(f"Add your {fields} in the workflow configuration.")
    return client_id, secret


class Spotify:
    def __init__(self, opener=urlopen):
        self.opener = opener
        self.path = data_dir() / "authorization.json"

    def connected(self):
        token = read_json(self.path, {})
        return bool(
            isinstance(token.get("refresh_token"), str)
            and token["refresh_token"]
            and isinstance(token.get("access_token"), str)
            and token["access_token"]
            and token.get("client_id") == credential_values()[0]
        )

    def has_scope(self, scope):
        return scope in read_json(self.path, {}).get("scope", "").split()

    def token_request(self, fields):
        client_id, _ = credentials(require_secret=False)
        previous = read_json(self.path, {})
        if previous.get("client_id") != client_id:
            previous = {}
        refreshing = fields.get("grant_type") == "refresh_token"
        pkce = "code_verifier" in fields or (refreshing and previous.get("pkce") is True)
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if pkce:
            fields = fields | {"client_id": client_id}
        else:
            _, secret = credentials()
            basic = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
            headers["Authorization"] = "Basic " + basic
        request = Request(
            "https://accounts.spotify.com/api/token", urlencode(fields).encode(), headers
        )
        try:
            with self.opener(request, timeout=15) as response:
                result = json.load(response)
        except HTTPError as error:
            error.close()
            if error.code in (400, 401):
                raise SpotifyError(
                    "Spotify sign-in expired or the client credentials changed. Connect again.",
                    error.code,
                ) from None
            raise SpotifyError(
                "Spotify could not complete sign-in. Try again shortly.", error.code
            ) from None
        except OSError, ValueError, URLError:
            raise SpotifyError(
                "Could not reach Spotify. Check your connection and try again."
            ) from None
        refresh_token = result.get("refresh_token") or (
            previous.get("refresh_token") if refreshing else None
        )
        if not result.get("access_token") or not refresh_token:
            raise SpotifyError("Spotify returned an incomplete sign-in response.")
        token = {
            "client_id": client_id,
            "access_token": result["access_token"],
            "refresh_token": refresh_token,
            "expires_at": time.time() + result.get("expires_in", 3600),
            "pkce": pkce,
            "scope": result.get("scope", previous.get("scope", "") if refreshing else SCOPES),
        }
        write_json(self.path, token)
        return token["access_token"]

    def access_token(self, force=False):
        with lock(data_dir() / "authorization.lock"):
            token = read_json(self.path, {})
            client_id, _ = credentials(require_secret=False)
            if token.get("client_id") != client_id or not token.get("refresh_token"):
                raise SpotifyError("Connect to Spotify to browse your saved library.", 401)
            try:
                expires_at = float(token.get("expires_at", 0))
            except TypeError, ValueError:
                expires_at = 0
            if not force and expires_at > time.time() + 60:
                return token["access_token"]
            return self.token_request(
                {"grant_type": "refresh_token", "refresh_token": token["refresh_token"]}
            )

    def request(self, path, params=None, method="GET", body=None):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("Expected a Spotify API path")
        cooldown = read_json(data_dir() / "api-cooldown.json", {})
        if cooldown.get("until", 0) > time.time():
            raise SpotifyError(cooldown.get("message", "Spotify is rate limiting requests."), 429)
        url = "https://api.spotify.com/v1" + path
        if params:
            url += "?" + urlencode(params)
        for attempt in range(2):
            token = self.access_token(force=attempt == 1)
            headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
            data = None
            if body is not None:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
            try:
                with self.opener(
                    Request(url, data, headers, method=method), timeout=12
                ) as response:
                    payload = response.read()
                    return json.loads(payload) if payload else {}
            except HTTPError as error:
                if error.code == 401 and attempt == 0:
                    error.close()
                    continue
                if error.code == 429:
                    try:
                        seconds = max(1, min(86400, int(error.headers.get("Retry-After", "60"))))
                    except ValueError:
                        seconds = 60
                    try:
                        reason = json.loads(error.read()).get("error", {})
                        reason = reason.get("reason", "") if isinstance(reason, dict) else ""
                    except ValueError:
                        reason = ""
                    finally:
                        error.close()
                    message = (
                        "Spotify's developer quota is exhausted. Cached browsing still works."
                        if reason == "QUOTA_EXCEEDED"
                        else f"Spotify is rate limiting requests. Try again in {seconds} seconds."
                    )
                    write_json(
                        data_dir() / "api-cooldown.json",
                        {"until": time.time() + seconds, "message": message},
                    )
                    raise SpotifyError(message, 429) from None
                error.close()
                if error.code == 403:
                    raise SpotifyError(
                        "Spotify does not allow this request for this app or playlist.", 403
                    ) from None
                if error.code == 401:
                    raise SpotifyError("Reconnect to Spotify to renew access.", 401) from None
                raise SpotifyError(
                    f"Spotify could not complete this request ({error.code}).", error.code
                ) from None
            except OSError, ValueError, URLError:
                raise SpotifyError(
                    "Spotify is unavailable. Your cached music is still available."
                ) from None

    def pages(self, path, params=None, nested=None):
        params = {"limit": 50, **(params or {})}
        seen = set()
        while path:
            key = path + "?" + urlencode(params)
            if key in seen:
                raise SpotifyError("Spotify returned a repeated library page.")
            seen.add(key)
            page = self.request(path, params)
            if nested:
                page = page.get(nested, {})
            yield from (item for item in page.get("items", []) if item)
            next_url = page.get("next")
            if not next_url:
                break
            parsed = urlsplit(next_url)
            if (
                parsed.scheme != "https"
                or parsed.netloc != "api.spotify.com"
                or not parsed.path.startswith("/v1/")
            ):
                raise SpotifyError("Spotify returned an invalid library page.")
            # Keep pagination on the API origin; never send credentials to a supplied host.
            path, params = parsed.path[3:] + ("?" + parsed.query if parsed.query else ""), {}
