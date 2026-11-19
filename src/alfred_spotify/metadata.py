"""Read the small subset of Spotify metadata protobufs needed for browsing.

Field numbers: librespot-org/librespot protocol/proto/metadata.proto.
This reads cached responses only; it never calls Spotify's private endpoints.
"""

import re

BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
URI = re.compile(r"spotify:(track|album|artist|playlist):[0-9A-Za-z]{22}\Z")


def varint(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError("Truncated protobuf")
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, pos
    raise ValueError("Invalid protobuf varint")


def fields(data):
    result = {}
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError("Invalid protobuf field")
        if wire == 0:
            value, pos = varint(data, pos)
        elif wire in (1, 2, 5):
            length = {1: 8, 5: 4}.get(wire)
            if wire == 2:
                length, pos = varint(data, pos)
            if pos + length > len(data):
                raise ValueError("Truncated protobuf value")
            value, pos = data[pos : pos + length], pos + length
        else:
            raise ValueError("Unsupported protobuf wire type")
        result.setdefault(number, []).append(value)
    return result


def first(message, number, default=None):
    return message.get(number, [default])[0]


def text(message, number):
    value = first(message, number, b"")
    return value.decode("utf-8") if isinstance(value, bytes) else ""


def spotify_id(gid):
    if not isinstance(gid, bytes) or len(gid) != 16:
        return ""
    value = int.from_bytes(gid, "big")
    result = ""
    while value:
        value, digit = divmod(value, 62)
        result = BASE62[digit] + result
    return result.rjust(22, "0")


def artwork(message, direct, group):
    images = list(message.get(direct, []))
    for blob in message.get(group, []):
        images.extend(fields(blob).get(1, []))
    candidates = []
    for blob in images:
        image = fields(blob)
        ident = first(image, 1, b"")
        if isinstance(ident, bytes) and len(ident) == 20:
            candidates.append((first(image, 2, 0), "https://i.scdn.co/image/" + ident.hex()))
    return max(candidates, default=(0, ""))[1]


def decode(kind, data, fallback=None, depth=0):
    if depth > 5:
        raise ValueError("Metadata nesting too deep")
    msg = fields(data)
    ident = spotify_id(first(msg, 1))
    name = text(msg, 2)
    if not ident or not name:
        return None
    item = {"uri": f"spotify:{kind}:{ident}", "kind": kind, "id": ident, "name": name}
    if kind == "artist":
        item["image"] = artwork(msg, 11, 17)
        item["albums"] = []
        for number in (5, 6, 7):
            for group in msg.get(number, []):
                for blob in fields(group).get(1, []):
                    album = decode("album", blob, depth=depth + 1)
                    if album:
                        item["albums"].append(album)
    else:
        item["artists"] = [
            a
            for blob in msg.get(4 if kind == "track" else 3, [])
            if (a := decode("artist", blob, depth=depth + 1))
        ]
        if kind == "track":
            album_blob = first(msg, 3)
            album = decode("album", album_blob, depth=depth + 1) if album_blob else fallback
            item["album"] = album or {}
            item["image"] = (album or {}).get("image", "")
            # Spotify metadata uses signed (zigzag) integers for these fields.
            for number, key in ((5, "track_number"), (6, "disc_number"), (7, "duration_ms")):
                val = first(msg, number, 0)
                item[key] = (val >> 1) ^ -(val & 1)
        else:
            item["image"] = artwork(msg, 9, 17)
            item["tracks"] = []
            for disc_blob in msg.get(11, []):
                for blob in fields(disc_blob).get(3, []):
                    track = decode("track", blob, fallback=item, depth=depth + 1)
                    if track:
                        # Avoid recursive album -> tracks -> album structures.
                        track["album"] = {k: v for k, v in item.items() if k != "tracks"}
                        track["image"] = item["image"]
                        item["tracks"].append(track)
            year = first(fields(first(msg, 6, b"")), 1, 0)
            item["year"] = str((year >> 1) ^ -(year & 1)) if year else ""
    return item


def from_api(value, kind=None):
    if not value:
        return None
    kind = kind or value.get("type", "track")
    uri = value.get("uri", "")
    if not URI.fullmatch(uri):
        return None
    item = {"uri": uri, "kind": kind, "id": value["id"], "name": value.get("name", "")}
    images = value.get("images") or (value.get("album") or {}).get("images") or []
    item["image"] = images[0].get("url", "") if images else ""
    item["artists"] = [
        a for artist in value.get("artists", []) if (a := from_api(artist, "artist"))
    ]
    if kind == "track":
        item["album"] = from_api(value.get("album"), "album") or {}
        for key in ("duration_ms", "disc_number", "track_number", "is_playable", "is_local"):
            if key in value:
                item[key] = value[key]
    if kind == "album":
        item["year"] = value.get("release_date", "")[:4]
        item["total"] = value.get("total_tracks", 0)
    if kind == "artist":
        item["genres"] = value.get("genres", [])
    if kind == "playlist":
        item["total"] = (value.get("items") or value.get("tracks") or {}).get("total")
    return item


def from_desktop(kind, value):
    """The desktop HTTP cache normally stores metadata as JSON, not protobuf."""
    gid = value.get("gid", "")
    try:
        ident = spotify_id(bytes.fromhex(gid))
    except ValueError, TypeError:
        return None
    if not ident or not isinstance(value.get("name"), str):
        return None
    item = {"uri": f"spotify:{kind}:{ident}", "kind": kind, "id": ident, "name": value["name"]}
    group = "portrait_group" if kind == "artist" else "cover_group"
    images = (value.get(group) or {}).get("image", [])
    for image in reversed(images):
        file_id = image.get("file_id", "")
        if re.fullmatch(r"[a-fA-F0-9]{40}", file_id):
            item["image"] = "https://i.scdn.co/image/" + file_id.lower()
            break
    item.setdefault("image", "")
    item["artists"] = [a for v in value.get("artist", []) if (a := from_desktop("artist", v))]
    if kind == "track":
        item["album"] = from_desktop("album", value.get("album", {})) or {}
        item["image"] = item["album"].get("image", "")
        for src, dest in (
            ("number", "track_number"),
            ("disc_number", "disc_number"),
            ("duration", "duration_ms"),
        ):
            item[dest] = value.get(src, 0)
    elif kind == "album":
        item["year"] = str((value.get("date") or {}).get("year", ""))
        item["tracks"] = [
            t
            for d in value.get("disc", [])
            for v in d.get("track", [])
            if (t := from_desktop("track", v))
        ]
        album = {k: v for k, v in item.items() if k != "tracks"}
        for track in item["tracks"]:
            track["album"], track["image"] = album, item["image"]
    elif kind == "artist":
        item["albums"] = [
            a
            for key in ("album_group", "single_group", "compilation_group")
            for group in value.get(key, [])
            for v in group.get("album", [])
            if (a := from_desktop("album", v))
        ]
    return item
