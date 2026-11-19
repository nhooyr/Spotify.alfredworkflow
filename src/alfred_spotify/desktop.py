"""Read-only reuse of Spotify's Chromium Simple Cache (format version 5).

Only image URLs and /metadata/4/{track,album,artist} responses are indexed.
Cookies, request headers, credentials, audio, and live LevelDB files are not read.
The index stores file offsets; only artwork actually displayed is extracted.
"""

import gzip
import hashlib
import json
import os
import re
import struct
import zlib
from compression import zstd
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from . import metadata
from .storage import cache_dir

INITIAL_MAGIC = 0xFCFB6D1BA7725C30
FINAL_MAGIC = 0xF4FA6F45970D41D8
IMAGE_HOSTS = {
    "i.scdn.co",
    "i.spotifycdn.com",
    "image-cdn-ak.spotifycdn.com",
    "image-cdn-fa.spotifycdn.com",
    "pickasso.spotifycdn.com",
}
META_PATH = re.compile(r"/metadata/4/(track|album|artist)/[a-f0-9]{32}\Z")
MAX_BODY = 8 * 1024 * 1024


def cache_root():
    return Path(
        os.environ.get("SPOTIFY_DESKTOP_CACHE")
        or (Path.home() / "Library/Caches/com.spotify.client/Browser/Cache/Cache_Data")
    )


def allowed_url(url):
    parsed = urlsplit(url)
    return parsed.scheme == "https" and (
        parsed.hostname in IMAGE_HOSTS
        or (parsed.hostname == "spclient.wg.spotify.com" and META_PATH.fullmatch(parsed.path))
    )


def entry(path):
    """Return URL and body bounds without reading response headers or body."""
    with path.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        header = stream.read(24)
        if len(header) != 24:
            raise ValueError("Incomplete cache header")
        magic, version, length, _, _ = struct.unpack("<QIIII", header)
        if magic != INITIAL_MAGIC or version != 5 or not 0 < length <= 16384:
            raise ValueError("Unknown cache format")
        key = stream.read(length)
        urls = re.findall(rb"https://[^\s\x00]+", key)
        if not urls:
            raise ValueError("No cached URL")
        url = urls[-1].decode("utf-8")
        if not allowed_url(url):
            raise ValueError("Not a music metadata or image response")
        stream.seek(-24, 2)
        magic, flags, _, stream0_size, _ = struct.unpack("<QIIII", stream.read(24))
        if magic != FINAL_MAGIC or flags & ~3:
            raise ValueError("Incomplete cache entry")
        body_end = size - 24 - (32 if flags & 2 else 0) - stream0_size - 24
        if body_end < 24 + length or body_end - 24 - length > MAX_BODY:
            raise ValueError("Invalid cache bounds")
        stream.seek(body_end)
        end_magic, _, _, _, _ = struct.unpack("<QIIII", stream.read(24))
        if end_magic != FINAL_MAGIC:
            raise ValueError("Invalid body footer")
        return url, 24 + length, body_end - 24 - length


def read_body(path, offset, length):
    with Path(path).open("rb") as stream:
        stream.seek(offset)
        body = stream.read(length)
        footer = stream.read(24)
    if len(body) != length or len(footer) != 24:
        raise ValueError("Cache entry changed")
    magic, flags, checksum, _, _ = struct.unpack("<QIIII", footer)
    if magic != FINAL_MAGIC or (flags & 1 and zlib.crc32(body) != checksum):
        raise ValueError("Cache body checksum mismatch")
    return body


def unpack(body):
    if body.startswith(b"\x1f\x8b"):
        # Read at most MAX_BODY+1 bytes to bound decompression as well as disk IO.
        import io

        with gzip.GzipFile(fileobj=io.BytesIO(body)) as stream:
            result = stream.read(MAX_BODY + 1)
    elif body.startswith(b"\x28\xb5\x2f\xfd"):
        result = zstd.ZstdDecompressor().decompress(body, max_length=MAX_BODY + 1)
    else:
        result = body
    if len(result) > MAX_BODY:
        raise ValueError("Metadata response too large")
    return result


def index(store):
    """Index changed cache files. Never open a Spotify database for writing."""
    known = dict(store.db.execute("SELECT path, stamp FROM desktop"))
    seen = set()
    imported = 0
    for path in cache_root().glob("*_0"):
        try:
            stamp = path.stat().st_mtime_ns
            name = str(path)
            seen.add(name)
            if known.get(name) == stamp:
                continue
            url, offset, length = entry(path)
            match = META_PATH.fullmatch(urlsplit(url).path)
            if match:
                body = unpack(read_body(path, offset, length))
                item = (
                    metadata.from_desktop(match[1], json.loads(body))
                    if body.lstrip().startswith(b"{")
                    else metadata.decode(match[1], body)
                )
                if item:
                    store.put_item(item)
                    for child in item.get("tracks", []) + item.get("artists", []):
                        store.put_item(child)
                    if item.get("album"):
                        store.put_item(item["album"])
                        for artist in item["album"].get("artists", []):
                            store.put_item(artist)
                    imported += 1
            store.db.execute(
                "INSERT OR REPLACE INTO desktop VALUES (?, ?, ?, ?, ?)",
                (name, stamp, url, offset, length),
            )
        except OSError, ValueError, struct.error, zstd.ZstdError:
            # Spotify can evict or replace an entry at any point during a scan.
            continue
    for name in known.keys() - seen:
        store.db.execute("DELETE FROM desktop WHERE path=?", (name,))
    store.commit()
    return imported


def image(store, url, download=False):
    if not url or not allowed_url(url) or urlsplit(url).hostname not in IMAGE_HOSTS:
        return None
    destination = cache_dir() / "artwork" / (hashlib.sha256(url.encode()).hexdigest() + ".img")
    if destination.exists():
        return str(destination)
    rows = store.db.execute(
        "SELECT path, offset, length FROM desktop WHERE url=? ORDER BY stamp DESC", (url,)
    ).fetchall()
    # Spotify caches several sizes of the same cover. Prefer a cached size over
    # downloading another: the first eight hex digits identify the image type,
    # the next eight the rendition, and the remaining 24 the artwork itself.
    match = re.fullmatch(r"https://i\.scdn\.co/image/([0-9a-f]{40})", url)
    if match:
        ident = match[1]
        rows += store.db.execute(
            "SELECT path, offset, length FROM desktop WHERE url LIKE ? ORDER BY stamp DESC",
            ("https://i.scdn.co/image/" + ident[:8] + "%" + ident[16:],),
        ).fetchall()
    body = None
    for path, offset, length in rows:
        try:
            body = read_body(path, offset, length)
            break
        except OSError, ValueError:
            continue
    if body is None and download:
        failure_key = "missing-image:" + hashlib.sha256(url.encode()).hexdigest()
        if store.get(failure_key):
            return None
        try:
            with urlopen(
                Request(url, headers={"User-Agent": "Alfred Spotify/0.1"}), timeout=5
            ) as r:
                if urlsplit(r.url).hostname not in IMAGE_HOSTS:
                    return None
                body = r.read(MAX_BODY + 1)
        except OSError:
            store.put(failure_key, True, 60)
            return None
    if not body or len(body) > MAX_BODY:
        return None
    if not (
        body.startswith(b"\xff\xd8\xff")
        or body.startswith(b"\x89PNG\r\n\x1a\n")
        or (body.startswith(b"RIFF") and body[8:12] == b"WEBP")
    ):
        return None
    destination.parent.mkdir(exist_ok=True, mode=0o700)
    temp = destination.with_suffix(f".{os.getpid()}.tmp")
    try:
        temp.write_bytes(body)
        os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)
    return str(destination)
