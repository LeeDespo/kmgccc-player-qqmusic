#!/usr/bin/env python3
"""QQMusicAPI stdio JSON helper.

Protocol:
  stdin:  one JSON request per line: {"id": "...", "method": "...", "params": {...}}
  stdout: one JSON response per line: {"id": "...", "ok": true, "candidates": [...]}

stdout is reserved for protocol JSON. Diagnostics must go to stderr.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.metadata
import json
import re
import sys
import time
import traceback
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse, urlunparse


try:
    from qqmusic_api import Client
    from qqmusic_api.models.request import Credential
    from qqmusic_api.modules.login import QRLoginType
    from qqmusic_api.modules.search import SearchType
    from qqmusic_api.modules.singer import TabType
    from qqmusic_api.modules.song import SongFileInfo, SongFileType

    IMPORT_ERROR: str | None = None
except Exception as exc:  # pragma: no cover - exercised in unbundled dev setups.
    Client = None  # type: ignore[assignment]
    Credential = None  # type: ignore[assignment]
    QRLoginType = None  # type: ignore[assignment]
    SearchType = None  # type: ignore[assignment]
    TabType = None  # type: ignore[assignment]
    SongFileInfo = None  # type: ignore[assignment]
    SongFileType = None  # type: ignore[assignment]
    IMPORT_ERROR = f"{type(exc).__name__}: {exc}"


SOURCE = "qqmusic"
MAX_IMAGE_SIZE = 800

# Bumped when the request/response shapes below change incompatibly. The host
# refuses to talk to a helper whose protocol major it does not understand, so a
# newer helper build cannot silently mis-parse.
HELPER_VERSION = "2.0.1"
PROTOCOL_VERSION = 2

# Advertised by `get_helper_info` and checked by the dispatcher, so a host can
# discover what an independently-updated helper supports.
KNOWN_METHODS: tuple[str, ...] = (
    "get_helper_info",
    "get_login_status",
    "start_login",
    "poll_login",
    "logout",
    "import_cookies",
    "search_songs",
    "fetch_recommend_feed",
    "fetch_radar",
    "fetch_recommend_playlists",
    "fetch_toplist_categories",
    "fetch_playlist_tracks",
    "fetch_new_songs",
    "search_playlists",
    "fetch_album_tracks",
    "set_liked",
    "is_liked",
    "fetch_radio_stations",
    "fetch_radio_tracks",
    "search_artists",
    "fetch_artist_detail",
    "fetch_artist_songs",
    "fetch_artist_albums",
    "fetch_liked_songs",
    "fetch_liked_albums",
    "fetch_user_playlists",
    "fetch_lyric",
    "resolve_song_url",
    "search_artist_artwork",
    "search_track_artwork",
    "search_album_artwork",
    "fetch_artist_biography",
    "fetch_album_detail",
    "fetch_song_detail",
)

# Playback URL host. `get_song_urls` returns a host-relative `purl`; the CDN
# host has to be prefixed before the URL is fetchable.
QQMUSIC_STREAM_CDN = "https://isure.stream.qqmusic.qq.com/"

# Quality tiers probed for a track, best first. Anonymous sessions are granted
# only the standard tier, so the ladder exists to discover what a logged-in
# session can actually fetch rather than to assume the best tier is authorized.
# Prefixes mirror the upstream `SongFileType` values.
QUALITY_LADDER: tuple[tuple[str, str, str], ...] = (
    ("flac", "F000", ".flac"),
    ("320", "M800", ".mp3"),
    ("128", "M500", ".mp3"),
    ("aac", "C400", ".m4a"),
)

# Upstream per-file result codes, see `UrlinfoItem.result`.
RESULT_OK = 0
RESULT_NO_PERMISSION = 104003
RESULT_VKEY_FAILED = 104004
RESULT_DEVICE_RESTRICTED = 104013

QQMUSIC_HTTPS_IMAGE_HOSTS = {
    "y.gtimg.cn",
    "qpic.y.qq.com",
    "y.qq.com",
    "thirdqq.qlogo.cn",
    "thirdwx.qlogo.cn",
}


def _log(message: str) -> None:
    print(f"[QQMusicHelper] {message}", file=sys.stderr, flush=True)


# MARK: - Credential store
#
# Anonymous sessions get rate limited ("触发风控") after a handful of requests,
# so every catalogue call runs with whatever credential is on disk. The
# credential file is plain JSON in a directory the host passes in via
# KMGCCC_QQMUSIC_CREDENTIAL_DIR; the helper never writes outside it.

CREDENTIAL_ENV = "KMGCCC_QQMUSIC_CREDENTIAL_DIR"
CREDENTIAL_FILE_NAME = "qqmusic-credential.json"

_credential_cache: Any = None
_credential_loaded = False


def _credential_path() -> Any:
    import os

    directory = os.environ.get(CREDENTIAL_ENV, "").strip()
    if not directory:
        return None
    from pathlib import Path

    path = Path(directory)
    try:
        path.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        _log(f"credential dir unusable dir={directory} reason={type(exc).__name__}: {exc}")
        return None
    return path / CREDENTIAL_FILE_NAME


def load_credential() -> Any:
    """Return the persisted credential, or None when not logged in."""
    global _credential_cache, _credential_loaded
    if _credential_loaded:
        return _credential_cache
    _credential_loaded = True
    _credential_cache = None

    if Credential is None:
        return None
    path = _credential_path()
    if path is None or not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        _credential_cache = Credential(**payload)
        _log(f"credential loaded musicid={_credential_cache.musicid}")
    except Exception as exc:
        _log(f"credential load failed reason={type(exc).__name__}: {exc}")
        _credential_cache = None
    return _credential_cache


def save_credential(credential: Any) -> None:
    global _credential_cache, _credential_loaded
    _credential_cache = credential
    _credential_loaded = True
    path = _credential_path()
    if path is None:
        _log("credential not persisted: no credential directory configured")
        return
    try:
        path.write_text(
            json.dumps(credential.model_dump(), ensure_ascii=False),
            encoding="utf-8",
        )
        try:
            path.chmod(0o600)
        except Exception:
            pass
        _log(f"credential saved musicid={credential.musicid}")
    except Exception as exc:
        _log(f"credential save failed reason={type(exc).__name__}: {exc}")


def clear_credential() -> None:
    global _credential_cache, _credential_loaded
    _credential_cache = None
    _credential_loaded = True
    path = _credential_path()
    if path is not None and path.exists():
        try:
            path.unlink()
        except Exception as exc:
            _log(f"credential delete failed reason={type(exc).__name__}: {exc}")
    _log("credential cleared")


# Cookie names the web login page sets, in the order they are preferred. The
# library injects exactly these two (`uin` + `qm_keyst`) when it builds a
# request, so a cookie captured from the login window is interchangeable with a
# credential produced by the QR flow — including `qm_keyst`, which is also the
# playback ticket that VIP url resolution requires.
_UIN_COOKIE_NAMES = ("uin", "qqmusic_uin", "wxuin", "p_uin")
_MUSIC_KEY_COOKIE_NAMES = (
    "qm_keyst",
    "qqmusic_key",
    "music_key",
    "p_skey",
    "skey",
    "wxskey",
)


def _pick_cookie(cookies: dict[str, str], names: tuple[str, ...]) -> str:
    for name in names:
        value = str(cookies.get(name) or "").strip()
        if value:
            return value
    return ""


def _normalize_uin(raw: str) -> str:
    """Strip the `o` prefix QQ uses on some uin cookies."""
    text = raw.strip()
    if text.startswith("o") and text[1:].isdigit():
        return text[1:]
    return text


def import_cookies(params: dict[str, Any]) -> dict[str, Any]:
    """Build a credential from cookies captured by a web login window.

    The upstream library authenticates from `uin` + `qm_keyst` (it derives
    `g_tk = hash33(musickey)`), which is exactly the pair the QQ Music login
    page sets. Accepts either a raw `Cookie:` header string or a name/value map
    so the caller can hand over whatever the web view produced.
    """
    _require_dependency()
    raw_cookies = params.get("cookies")
    if isinstance(raw_cookies, str):
        parsed: dict[str, str] = {}
        for part in raw_cookies.split(";"):
            if "=" not in part:
                continue
            name, _, value = part.partition("=")
            parsed[name.strip()] = value.strip()
        cookies = parsed
    elif isinstance(raw_cookies, dict):
        cookies = {str(k): str(v) for k, v in raw_cookies.items()}
    else:
        raise ValueError("cookies must be a Cookie header string or an object")

    uin = _normalize_uin(_pick_cookie(cookies, _UIN_COOKIE_NAMES))
    music_key = _pick_cookie(cookies, _MUSIC_KEY_COOKIE_NAMES)
    if not uin or not music_key:
        missing = []
        if not uin:
            missing.append("uin")
        if not music_key:
            missing.append("qm_keyst")
        raise ValueError(f"cookie 缺少必要字段: {', '.join(missing)}")

    credential = build_credential_from_cookies(uin=uin, music_key=music_key)
    save_credential(credential)
    summary = _credential_summary(credential)
    summary["event"] = "COOKIE"
    summary["hasPlaybackKey"] = bool(music_key)
    return summary


def build_credential_from_cookies(uin: str, music_key: str) -> Any:
    """Assemble a Credential that authenticates the same way a login would."""
    musicid = int(uin) if uin.isdigit() else 0
    return Credential(
        musicid=musicid,
        str_musicid=uin,
        musickey=music_key,
        login_type=1,
    )


def _new_client() -> Any:
    """Build a client bound to the persisted credential, if any."""
    if Client is None:
        return None
    credential = load_credential()
    if credential is None:
        return Client()
    return Client(credential=credential)


def _credential_client(credential: Any) -> Any:
    """Build a client for an explicit credential, falling back to the stored one."""
    if Client is None:
        return None
    return Client(credential=credential or load_credential())


def _dependency_diagnostics() -> str:
    parts = [f"python={sys.version.split()[0]}", f"executable={sys.executable}"]
    try:
        qqmusic_api = importlib.import_module("qqmusic_api")
        parts.append(f"qqmusic_api={getattr(qqmusic_api, '__file__', '<unknown>')}")
        parts.append(f"qqmusic_api.__version__={getattr(qqmusic_api, '__version__', '<unknown>')}")
    except Exception as exc:
        parts.append(f"qqmusic_api import failed={type(exc).__name__}: {exc}")
    try:
        parts.append(f"dist={importlib.metadata.version('qqmusic-api-python')}")
    except Exception as exc:
        parts.append(f"dist=<unknown:{type(exc).__name__}>")
    for module_name in (
        "qqmusic_api.core.client",
        "qqmusic_api.modules.search",
        "qqmusic_api.modules.singer",
        "qqmusic_api.modules.album",
        "qqmusic_api.modules.song",
        "qqmusic_api.models.search",
        "qqmusic_api.models.singer",
        "qqmusic_api.models.album",
        "qqmusic_api.models.song",
    ):
        try:
            module = importlib.import_module(module_name)
            parts.append(f"{module_name}=ok:{getattr(module, '__file__', '<unknown>')}")
        except Exception as exc:
            parts.append(f"{module_name}=failed:{type(exc).__name__}: {exc}")
    api_path = "Client.execute(search.search_by_type/detail modules)"
    parts.append(f"search_api={api_path}")
    return " ".join(parts)


def _json_response(request_id: str | None, ok: bool, **payload: Any) -> str:
    response = {"id": request_id, "ok": ok}
    response.update(payload)
    return json.dumps(response, ensure_ascii=False, separators=(",", ":"))


def _require_dependency() -> None:
    if IMPORT_ERROR is not None:
        raise RuntimeError(f"qqmusic-api-python unavailable: {IMPORT_ERROR}")


def _first_text(value: Any, keys: tuple[str, ...]) -> str:
    if isinstance(value, dict):
        for key in keys:
            item = value.get(key)
            if isinstance(item, str) and item.strip():
                return item.strip()
            if isinstance(item, (int, float)):
                return str(item)
    return ""


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _compact_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    return ""


def _optional_text(value: Any) -> str | None:
    text = _compact_text(value)
    return text or None


def _split_tags(value: Any) -> list[str]:
    if isinstance(value, list):
        raw_items = value
    else:
        raw_items = re.split(r"[,，、/;；|｜\n]+", _compact_text(value))
    tags: list[str] = []
    seen: set[str] = set()
    for item in raw_items:
        tag = _compact_text(item)
        if not tag or tag in seen:
            continue
        seen.add(tag)
        tags.append(tag)
    return tags


def _release_year(value: Any) -> int | None:
    match = re.search(r"\b(19|20)\d{2}\b", _compact_text(value))
    return int(match.group(0)) if match else None


def _content_values(items: Any) -> list[str]:
    if not isinstance(items, list):
        return []
    values: list[str] = []
    for item in items:
        if isinstance(item, dict):
            text = _first_text(item, ("value", "title", "name"))
        else:
            text = _compact_text(item)
        if text:
            values.append(text)
    return values


def _first_content_value(items: Any) -> str:
    values = _content_values(items)
    return values[0] if values else ""


def _join_description(values: list[str]) -> str:
    cleaned = [value.strip() for value in values if value.strip()]
    return "\n".join(cleaned)


def _collect_content_text(value: Any) -> list[str]:
    keys = {
        "value",
        "content",
        "text",
        "desc",
        "description",
        "intro",
        "introduction",
        "detail",
        "body",
        "summary",
    }
    values: list[str] = []
    seen: set[str] = set()

    def add(text: Any) -> None:
        item = _compact_text(text)
        if (
            not item
            or item in seen
            or item.startswith(("http://", "https://"))
            or item.lower() in {"wiki", "introduction", "简介"}
        ):
            return
        seen.add(item)
        values.append(item)

    def walk(node: Any, include_string: bool = False) -> None:
        if isinstance(node, str):
            if include_string:
                add(node)
            return
        if isinstance(node, list):
            for child in node:
                walk(child, include_string=include_string)
            return
        if not isinstance(node, dict):
            if include_string:
                add(node)
            return
        for key, child in node.items():
            key_text = str(key).lower()
            if key_text in keys:
                if isinstance(child, (dict, list)):
                    walk(child, include_string=True)
                else:
                    add(child)
            elif isinstance(child, (dict, list)):
                walk(child, include_string=False)

    walk(value, include_string=False)
    return values


def _sanitize_image_url(value: str) -> str:
    raw = value.strip()
    if not raw:
        return ""
    parsed = urlparse(raw)
    if parsed.scheme.lower() == "http" and parsed.netloc.lower() in QQMUSIC_HTTPS_IMAGE_HOSTS:
        sanitized = urlunparse(parsed._replace(scheme="https"))
        _log(f"sanitized imageURL from={raw} to={sanitized}")
        return sanitized
    return raw


def _to_plain(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, list):
        return [_to_plain(item) for item in value]
    if isinstance(value, tuple):
        return [_to_plain(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _to_plain(item) for key, item in value.items()}
    if hasattr(value, "model_dump"):
        return _to_plain(value.model_dump())
    if hasattr(value, "__dict__"):
        return {
            key: _to_plain(item)
            for key, item in vars(value).items()
            if not key.startswith("_")
        }
    return value


def _items_from_search_result(value: Any, keys: tuple[str, ...]) -> list[dict[str, Any]]:
    plain = _to_plain(value)
    if isinstance(plain, list):
        return [item for item in plain if isinstance(item, dict)]
    if isinstance(plain, dict):
        for key in keys:
            item = plain.get(key)
            if isinstance(item, list):
                return [entry for entry in item if isinstance(entry, dict)]
            if isinstance(item, dict):
                nested = _items_from_search_result(item, keys)
                if nested:
                    return nested
    return []


def _first_int(value: Any, keys: tuple[str, ...]) -> int | None:
    if not isinstance(value, dict):
        return None
    for key in keys:
        item = value.get(key)
        if isinstance(item, bool):
            continue
        if isinstance(item, int):
            return item
        if isinstance(item, float):
            return int(item)
        if isinstance(item, str) and item.strip().isdigit():
            return int(item.strip())
    return None


def _first_dict(value: Any, keys: tuple[str, ...]) -> dict[str, Any]:
    if isinstance(value, dict):
        for key in keys:
            item = value.get(key)
            if isinstance(item, dict):
                return item
    return {}


def _singers_text(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    singers = value.get("singer") or value.get("singers") or value.get("singer_list")
    if isinstance(singers, list):
        names: list[str] = []
        for singer in singers:
            if isinstance(singer, dict):
                name = _first_text(singer, ("name", "singerName", "title"))
                if name:
                    names.append(name)
            elif isinstance(singer, str) and singer.strip():
                names.append(singer.strip())
        if names:
            return ", ".join(names)
    return _first_text(value, ("singer", "singerName", "singer_name", "artist", "artistName"))


def _singers_text_from_list(value: Any) -> str:
    if not isinstance(value, list):
        return ""
    names: list[str] = []
    for singer in value:
        if isinstance(singer, dict):
            name = _first_text(singer, ("name", "title", "singerName"))
            if name:
                names.append(name)
    return ", ".join(names)


def _singer_mid(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    singers = value.get("singer") or value.get("singers") or value.get("singer_list")
    if isinstance(singers, list):
        for singer in singers:
            if isinstance(singer, dict):
                mid = _first_text(singer, ("mid", "singerMID", "singerMid"))
                if mid:
                    return mid
    return _first_text(value, ("singerMID", "singerMid", "mid"))


def _album_mid(value: Any) -> str:
    album = _first_dict(value, ("album", "albumInfo"))
    mid = _first_text(album, ("mid", "albumMID", "albumMid"))
    if mid:
        return mid
    return _first_text(value, ("albumMID", "albumMid", "albummid", "album_mid", "mid"))


def _album_name(value: Any) -> str:
    album = _first_dict(value, ("album", "albumInfo"))
    name = _first_text(album, ("name", "title", "albumName", "albumname"))
    if name:
        return name
    return _first_text(value, ("albumName", "albumname", "album", "title", "name"))


def _song_title(value: Any) -> str:
    return _first_text(value, ("title", "name", "songName", "songname"))


def _song_mid(value: Any) -> str:
    return _first_text(value, ("mid", "songMID", "songMid", "songmid"))


def _album_cover_url(album_mid: str) -> str:
    if not album_mid:
        return ""
    return f"https://y.gtimg.cn/music/photo_new/T002R{MAX_IMAGE_SIZE}x{MAX_IMAGE_SIZE}M000{album_mid}.jpg"


def _singer_cover_url(singer_mid: str) -> str:
    if not singer_mid:
        return ""
    return f"https://y.gtimg.cn/music/photo_new/T001R{MAX_IMAGE_SIZE}x{MAX_IMAGE_SIZE}M000{singer_mid}.jpg"


def _rank_confidence(index: int) -> float:
    return max(0.50, 0.86 - index * 0.04)


async def _search_by_type(
    keyword: str,
    search_type: Any,
    result_keys: tuple[str, ...],
    limit: int,
) -> list[dict[str, Any]]:
    if Client is None:
        return []
    async with _new_client() as client:
        result = await client.execute(
            client.search.search_by_type(
                keyword=keyword,
                search_type=search_type,
                num=limit,
                page=1,
                highlight=False,
            )
        )
    return _items_from_search_result(result, result_keys)


async def _execute_client_request(request_builder: Any) -> Any:
    if Client is None:
        return {}
    async with _new_client() as client:
        result = await client.execute(request_builder(client))
    return _to_plain(result)


async def _fetch_singer_desc(singer_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.singer.get_desc([singer_mid]))
    items = _items_from_search_result(plain, ("singer_list", "singerList", "list"))
    return items[0] if items else {}


async def _fetch_singer_info(singer_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.singer.get_info(singer_mid))
    return plain if isinstance(plain, dict) else {}


async def _fetch_singer_wiki_tab(singer_mid: str) -> dict[str, Any]:
    if TabType is None:
        return {}
    try:
        plain = await _execute_client_request(
            lambda client: client.singer.get_tab_detail(singer_mid, TabType.WIKI, page=1, num=10)
        )
        return plain if isinstance(plain, dict) else {}
    except Exception as exc:
        _log(f"artist wiki tab fetch failed singerMid={singer_mid} reason={type(exc).__name__}: {exc}")
        return {}


async def _fetch_album_detail_raw(album_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.album.get_detail(album_mid))
    return plain if isinstance(plain, dict) else {}


async def _fetch_song_detail_raw(song_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.song.get_detail(song_mid))
    return plain if isinstance(plain, dict) else {}


async def search_artist_artwork(params: dict[str, Any]) -> list[dict[str, Any]]:
    _require_dependency()
    name = str(params.get("name") or "").strip()
    if not name:
        return []
    limit = max(1, min(int(params.get("limit") or 5), 10))
    results = await _search_by_type(name, SearchType.SINGER, ("singer", "singers", "list"), limit)
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(results or []):
        singer_name = _first_text(item, ("singerName", "name", "title"))
        singer_mid = _first_text(item, ("singerMID", "singerMid", "mid"))
        image_url = (
            _first_text(item, ("singerPic", "pic", "image", "picURL", "picUrl"))
            or _singer_cover_url(singer_mid)
        )
        image_url = _sanitize_image_url(image_url)
        if not image_url:
            continue
        candidates.append(
            {
                "source": SOURCE,
                "artistName": singer_name,
                "singerMid": singer_mid,
                "imageURL": image_url,
                "genreTags": _split_tags(_first_text(item, ("genre", "tag"))),
                "region": _first_text(item, ("country", "area", "areaName")),
                "foreignName": _first_text(item, ("other_name", "otherName", "foreignName")),
                "confidence": _rank_confidence(index),
            }
        )
    return candidates


async def search_track_artwork(params: dict[str, Any]) -> list[dict[str, Any]]:
    _require_dependency()
    title = str(params.get("title") or "").strip()
    artist = str(params.get("artist") or "").strip()
    album = str(params.get("album") or "").strip()
    query = " ".join(part for part in (title, artist, album) if part).strip()
    if not query:
        return []
    limit = max(1, min(int(params.get("limit") or 5), 10))
    results = await _search_by_type(query, SearchType.SONG, ("song", "songs", "list"), limit)
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(results or []):
        album_mid = _album_mid(item)
        image_url = _sanitize_image_url(_album_cover_url(album_mid))
        if not image_url:
            continue
        candidates.append(
            {
                "source": SOURCE,
                "title": _song_title(item),
                "artist": _singers_text(item),
                "album": _album_name(item),
                "songMid": _song_mid(item),
                "albumMid": album_mid,
                "imageURL": image_url,
                "duration": _first_int(item, ("interval", "duration", "durationSec")),
                "confidence": _rank_confidence(index),
            }
        )
    return candidates


async def search_album_artwork(params: dict[str, Any]) -> list[dict[str, Any]]:
    _require_dependency()
    album = str(params.get("album") or "").strip()
    artist = str(params.get("artist") or "").strip()
    query = " ".join(part for part in (album, artist) if part).strip()
    if not query:
        return []
    limit = max(1, min(int(params.get("limit") or 5), 10))
    results = await _search_by_type(query, SearchType.ALBUM, ("album", "albums", "list"), limit)
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(results or []):
        album_mid = _album_mid(item)
        image_url = (
            _first_text(item, ("picURL", "picUrl", "albumPic", "image"))
            or _album_cover_url(album_mid)
        )
        image_url = _sanitize_image_url(image_url)
        if not image_url:
            continue
        candidates.append(
            {
                "source": SOURCE,
                "album": _album_name(item),
                "artist": _singers_text(item),
                "albumMid": album_mid,
                "imageURL": image_url,
                "confidence": _rank_confidence(index),
            }
        )
    return candidates


async def fetch_artist_detail(params: dict[str, Any]) -> dict[str, Any]:
    _require_dependency()
    name = str(params.get("name") or params.get("artist") or "").strip()
    singer_mid = str(params.get("singerMid") or params.get("mid") or "").strip()
    confidence = float(params.get("confidence") or 0.90)
    image_url = ""
    matched_name = name
    matched_region = ""
    matched_foreign_name = ""
    matched_genre_tags: list[str] = []

    if not singer_mid and name:
        candidates = await search_artist_artwork({"name": name, "limit": 1})
        if candidates:
            top = candidates[0]
            singer_mid = str(top.get("singerMid") or "").strip()
            matched_name = str(top.get("artistName") or name).strip()
            image_url = str(top.get("imageURL") or "").strip()
            matched_region = str(top.get("region") or "").strip()
            matched_foreign_name = str(top.get("foreignName") or "").strip()
            matched_genre_tags = _split_tags(top.get("genreTags"))
            confidence = float(top.get("confidence") or confidence)

    if not singer_mid:
        raise ValueError("singerMid or name is required")

    desc = await _fetch_singer_desc(singer_mid)
    info = await _fetch_singer_info(singer_mid)
    wiki_tab = await _fetch_singer_wiki_tab(singer_mid)
    basic = _first_dict(desc, ("basic_info", "basicInfo"))
    ex_info = _first_dict(desc, ("ex_info", "exInfo"))
    info_singer = _first_dict(info, ("singer", "Singer"))
    base_info = _first_dict(info, ("base_info", "baseInfo", "BaseInfo"))
    info_tab_detail = _first_dict(info, ("tab_detail", "TabDetail"))

    artist_name = (
        _first_text(basic, ("name", "title", "singerName"))
        or _first_text(info_singer, ("name", "Name", "singerName"))
        or matched_name
    )
    image_url = (
        image_url
        or _first_text(info_singer, ("singer_pic", "singerPic", "SingerPic"))
        or _first_text(base_info, ("avatar", "Avatar"))
        or _singer_cover_url(singer_mid)
    )
    image_url = _sanitize_image_url(image_url)
    genre_tags = _split_tags(_first_text(ex_info, ("genre", "tag"))) or matched_genre_tags
    description = (
        _first_text(ex_info, ("desc", "description"))
        or _first_text(desc, ("wiki",))
        or _join_description(_collect_content_text(info_tab_detail))
        or _join_description(_collect_content_text(wiki_tab))
    )
    region = _first_text(ex_info, ("area", "region", "country")) or matched_region
    foreign_name = _first_text(ex_info, ("foreign_name", "foreignName")) or matched_foreign_name
    _log(
        "artist detail fields "
        f"singerMid={singer_mid} desc={bool(description)} tags={len(genre_tags)} "
        f"region={bool(region)} foreignName={bool(foreign_name)}"
    )

    return {
        "source": SOURCE,
        "artistName": artist_name,
        "singerMid": singer_mid,
        "imageURL": image_url,
        "description": description,
        "genreTags": genre_tags,
        "region": region,
        "foreignName": foreign_name,
        "metadataSource": SOURCE,
        "metadataFetchedAt": _utc_now_iso(),
        "metadataConfidence": confidence,
        "confidence": confidence,
    }


async def fetch_album_detail(params: dict[str, Any]) -> dict[str, Any]:
    _require_dependency()
    album = str(params.get("album") or "").strip()
    artist = str(params.get("artist") or "").strip()
    album_mid = str(params.get("albumMid") or params.get("mid") or "").strip()
    confidence = float(params.get("confidence") or 0.90)
    image_url = ""
    matched_album = album
    matched_artist = artist

    if not album_mid and (album or artist):
        candidates = await search_album_artwork({"album": album, "artist": artist, "limit": 1})
        if candidates:
            top = candidates[0]
            album_mid = str(top.get("albumMid") or "").strip()
            matched_album = str(top.get("album") or album).strip()
            matched_artist = str(top.get("artist") or artist).strip()
            image_url = str(top.get("imageURL") or "").strip()
            confidence = float(top.get("confidence") or confidence)

    if not album_mid:
        raise ValueError("albumMid or album/artist is required")

    detail = await _fetch_album_detail_raw(album_mid)
    album_info = _first_dict(detail, ("album", "basicInfo"))
    company = _first_dict(detail, ("company",))
    singers = detail.get("singers") if isinstance(detail, dict) else None
    release_date = _first_text(album_info, ("time_public", "publishDate", "releaseDate"))
    genre_text = _first_text(album_info, ("genre", "tag"))

    return {
        "source": SOURCE,
        "album": _first_text(album_info, ("name", "title", "albumName")) or matched_album,
        "artist": _singers_text_from_list(singers) or matched_artist,
        "albumMid": _first_text(album_info, ("mid", "albumMid", "albumMID")) or album_mid,
        "imageURL": _sanitize_image_url(image_url or _album_cover_url(album_mid)),
        "description": _first_text(album_info, ("desc", "description")),
        "releaseYear": _release_year(release_date),
        "releaseDate": release_date,
        "albumType": _first_text(album_info, ("album_type", "albumType")),
        "genreTags": _split_tags(genre_text),
        "language": _first_text(album_info, ("language", "lan")),
        "labelOrCompany": _first_text(company, ("name", "company", "label")),
        "metadataSource": SOURCE,
        "metadataFetchedAt": _utc_now_iso(),
        "metadataConfidence": confidence,
        "confidence": confidence,
    }


async def fetch_song_detail(params: dict[str, Any]) -> dict[str, Any]:
    _require_dependency()
    title = str(params.get("title") or "").strip()
    artist = str(params.get("artist") or "").strip()
    album = str(params.get("album") or "").strip()
    song_mid = str(params.get("songMid") or params.get("mid") or "").strip()
    confidence = float(params.get("confidence") or 0.90)
    image_url = ""
    matched_title = title
    matched_artist = artist
    matched_album = album
    album_mid = ""

    if not song_mid and (title or artist or album):
        candidates = await search_track_artwork(
            {"title": title, "artist": artist, "album": album, "duration": params.get("duration"), "limit": 1}
        )
        if candidates:
            top = candidates[0]
            song_mid = str(top.get("songMid") or "").strip()
            album_mid = str(top.get("albumMid") or "").strip()
            matched_title = str(top.get("title") or title).strip()
            matched_artist = str(top.get("artist") or artist).strip()
            matched_album = str(top.get("album") or album).strip()
            image_url = str(top.get("imageURL") or "").strip()
            confidence = float(top.get("confidence") or confidence)

    if not song_mid:
        raise ValueError("songMid or title/artist/album is required")

    detail = await _fetch_song_detail_raw(song_mid)
    track = _first_dict(detail, ("track", "track_info", "trackInfo"))
    album_info = _first_dict(track, ("album",))
    album_mid = album_mid or _album_mid(track)
    release_date = _first_content_value(detail.get("pub_time")) or _first_text(track, ("time_public", "timePublic"))
    genre_values = _content_values(detail.get("genre"))
    intro_values = _content_values(detail.get("intro"))
    language = _first_content_value(detail.get("lan"))
    company = _first_content_value(detail.get("company"))

    return {
        "source": SOURCE,
        "title": _song_title(track) or matched_title,
        "artist": _singers_text(track) or matched_artist,
        "album": _album_name(track) or matched_album,
        "songMid": _song_mid(track) or song_mid,
        "albumMid": album_mid,
        "imageURL": _sanitize_image_url(image_url or _album_cover_url(album_mid)),
        "description": _join_description(intro_values),
        "genreTags": _split_tags(genre_values),
        "language": language,
        "labelOrCompany": company,
        "releaseDate": release_date,
        "duration": _first_int(track, ("interval", "duration", "durationSec")),
        "metadataSource": SOURCE,
        "metadataFetchedAt": _utc_now_iso(),
        "metadataConfidence": confidence,
        "confidence": confidence,
    }


def _track_payload(item: Any) -> dict[str, Any]:
    """Normalize one upstream song object into a browsable track payload.

    Search results, radio, radar, playlists and toplists all describe a song
    with the same core fields, but wrapper depth differs (playlist entries nest
    the song under `track`, search results do not). Callers use this instead of
    each re-deriving the shape.
    """
    if not isinstance(item, dict):
        return {}
    track = _first_dict(item, ("track", "song", "songInfo")) or item
    file_info = _first_dict(track, ("file", "fileInfo"))
    pay = _first_dict(track, ("pay", "payInfo"))
    album = _first_dict(track, ("album", "albumInfo"))
    album_mid = _album_mid(track)
    song_mid = _song_mid(track)
    media_mid = _first_text(file_info, ("media_mid", "mediaMid")) or _first_text(
        track, ("media_mid", "mediaMid")
    )
    # `pay_play == 1` means the track is gated; it is the same signal that
    # predicts whether the CDN grants a playback url, so surface it directly.
    pay_play = _first_int(pay, ("pay_play", "payPlay"))
    # The album's *numeric* id, which is the only handle `fetch_album_tracks`
    # accepts. The mid travels alongside it because the cover needs it, but the
    # mid alone cannot open an album's track list.
    album_id = _first_int(album, ("id", "albumId", "albumID")) or _first_int(
        track, ("albumId", "albumID")
    )
    return {
        "source": SOURCE,
        "songId": _first_int(track, ("id", "songId", "songid")),
        "songMid": song_mid,
        "mediaMid": media_mid,
        "title": _song_title(track),
        "artist": _singers_text(track),
        "album": _album_name(track),
        "albumMid": album_mid,
        "albumId": album_id,
        "imageURL": _sanitize_image_url(_album_cover_url(album_mid)),
        "duration": _first_int(track, ("interval", "duration", "durationSec")),
        "payPlay": pay_play,
        "songType": _first_int(track, ("type", "songType")),
        "size320": _first_int(file_info, ("size_320mp3", "size320mp3")),
        "sizeFlac": _first_int(file_info, ("size_flac", "sizeFlac")),
        "size128": _first_int(file_info, ("size_128mp3", "size128mp3")),
        "singerMid": _singer_mid(track),
        "albumName": _album_name(album) or _album_name(track),
    }


def _tracks_payload(items: Any) -> list[dict[str, Any]]:
    if not isinstance(items, list):
        return []
    payloads = [_track_payload(item) for item in items]
    return [item for item in payloads if item.get("songMid")]


def _songlist_payload(item: Any) -> dict[str, Any]:
    """Normalize a playlist summary (recommend feed / user playlist)."""
    if not isinstance(item, dict):
        return {}
    plain = _to_plain(item)
    # Recommend feed nests `{Playlist: {basic: {...}}}`; other endpoints are flat.
    playlist = _first_dict(plain, ("Playlist", "playlist"))
    basic = _first_dict(playlist, ("basic",)) or playlist or plain
    cover = _first_dict(basic, ("cover",))
    creator = _first_dict(basic, ("creator", "user"))
    diss_id = _first_int(basic, ("dissid", "tid", "id", "songlistId"))
    return {
        "source": SOURCE,
        "id": diss_id,
        "title": _first_text(basic, ("title", "name", "dissname")),
        "coverURL": _sanitize_image_url(
            _first_text(cover, ("medium_url", "mediumUrl", "big_url", "default_url"))
            or _first_text(basic, ("picurl", "picUrl", "imgurl"))
        ),
        "creator": _first_text(creator, ("nick", "name", "nickname")),
        "songCount": _first_int(basic, ("song_cnt", "songCnt", "songnum", "song_num")),
        "playCount": _first_int(basic, ("play_cnt", "playCnt", "listennum")),
    }


def _quality_for_file_type(file_type: Any) -> str:
    """Map an upstream `SongFileType` back to our ladder label."""
    raw = str(getattr(file_type, "s", "") or "")
    for label, prefix, _ext in QUALITY_LADDER:
        if prefix == raw:
            return label
    return ""


async def _get_song_urls(
    song_mid: str,
    file_type: Any,
    media_mid: str = "",
    credential: Any = None,
) -> dict[str, Any]:
    """Fetch the playback url for one (mid, tier) pair.

    Returns the raw upstream envelope so the caller can read both `data` and
    `expiration`.
    """
    if Client is None or SongFileInfo is None:
        return {}
    info = SongFileInfo(mid=song_mid, media_mid=media_mid or None, file_type=file_type)
    async with _credential_client(credential) as client:
        result = await client.execute(client.song.get_song_urls([info], file_type=file_type))
    plain = _to_plain(result)
    return plain if isinstance(plain, dict) else {}


def _url_entry(envelope: dict[str, Any]) -> dict[str, Any]:
    items = envelope.get("data")
    if isinstance(items, list) and items and isinstance(items[0], dict):
        return items[0]
    return {}


async def resolve_song_url(params: dict[str, Any]) -> dict[str, Any]:
    """Resolve the best playable url for one track.

    Probes the quality ladder from `params["quality"]` downward and returns the
    first tier the upstream grants. Anonymous sessions are only granted the
    standard tier, so a blocked top tier is an expected outcome rather than an
    error: the response reports what was available so the caller can decide
    whether to prompt for login.
    """
    _require_dependency()
    song_mid = str(params.get("songMid") or "").strip()
    if not song_mid:
        raise ValueError("songMid is required")
    media_mid = str(params.get("mediaMid") or "").strip()
    requested = str(params.get("quality") or "").strip().lower()

    ladder = list(QUALITY_LADDER)
    if requested:
        preferred = [entry for entry in ladder if entry[0] == requested]
        if not preferred:
            raise ValueError(f"unknown quality: {requested}")
        # Try the requested tier first, then everything below it.
        ladder = ladder[: ladder.index(preferred[0]) + 1]

    tried: list[str] = []
    for label, prefix, extension in ladder:
        envelope = await _get_song_urls(song_mid, SongFileType((prefix, extension)), media_mid)
        if not envelope:
            tried.append(f"{label}:no-result")
            continue
        entry = _url_entry(envelope)
        purl = str(entry.get("purl") or "").strip()
        result_code = _first_int(entry, ("result",))
        if purl:
            return {
                "source": SOURCE,
                "songMid": song_mid,
                "mediaMid": media_mid,
                "url": QQMUSIC_STREAM_CDN + purl.lstrip("/"),
                "quality": label,
                "extension": extension.lstrip("."),
                "filename": _first_text(entry, ("filename",)),
                "expiration": _first_int(envelope, ("expiration",)) or 7200,
                "playable": True,
                "tried": tried,
            }
        tried.append(f"{label}:{result_code}")

    return {
        "source": SOURCE,
        "songMid": song_mid,
        "mediaMid": media_mid,
        "url": "",
        "quality": "",
        "playable": False,
        "restriction": _classify_restriction(tried),
        "tried": tried,
    }


def _tracks_response(
    request_id: str | None,
    method: str,
    tracks: list[dict[str, Any]],
    started_at: float,
) -> dict[str, Any]:
    duration_ms = int((time.monotonic() - started_at) * 1000)
    playable = sum(1 for item in tracks if item.get("payPlay") == 0)
    _log(
        f"response id={request_id} method={method} "
        f"tracks={len(tracks)} free={playable} durationMs={duration_ms}"
    )
    return {"id": request_id, "ok": True, "tracks": tracks}


def _classify_restriction(tried: list[str]) -> str:
    """Turn accumulated per-tier result codes into one user-facing reason."""
    codes = {
        int(entry.rsplit(":", 1)[1])
        for entry in tried
        if entry.rsplit(":", 1)[-1].isdigit()
    }
    if RESULT_NO_PERMISSION in codes:
        return "paid_required"
    if RESULT_DEVICE_RESTRICTED in codes:
        return "device_restricted"
    if RESULT_VKEY_FAILED in codes:
        return "url_unavailable"
    return "url_unavailable"


async def search_songs(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Keyword search returning full track payloads."""
    _require_dependency()
    keyword = str(params.get("keyword") or "").strip()
    if not keyword:
        return []
    limit = max(1, min(_first_int(params, ("limit",)) or 20, 50))
    page = max(1, _first_int(params, ("page",)) or 1)
    results = await _search_by_type(keyword, SearchType.SONG, ("song", "songs", "list"), limit)
    return _tracks_payload(results[:limit])


async def fetch_recommend_feed(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Guess-you-like radio ("猜你喜欢").

    The upstream hands out only ~5 tracks per call, so several calls are needed
    for a usable queue.

    **These calls must stay serial.** Fetching the rounds concurrently was
    measured to be ~2x faster but returned the *same* 5 tracks every time —
    the upstream radio advances its state per call, so parallel calls all read
    the same position. Serial rounds are what produce distinct tracks, which is
    why the cost is paid here rather than parallelised away. Callers that want
    a faster first paint should request a small `rounds` and page for more.
    """
    _require_dependency()
    rounds = max(1, min(_first_int(params, ("rounds",)) or 2, 6))
    songs: list[dict[str, Any]] = []
    seen: set[str] = set()
    for _ in range(rounds):
        plain = _to_plain(
            await _execute_client_request(lambda client: client.recommend.get_guess_recommend())
        )
        batch = _items_from_search_result(plain, ("songs", "Tracks", "tracks"))
        if not batch:
            break
        for item in _tracks_payload(batch):
            if item["songMid"] in seen:
                continue
            seen.add(item["songMid"])
            songs.append(item)
        if len(songs) >= 20:
            break
    return songs


async def fetch_radar(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Personal radar ("雷达推荐"). Requires login upstream; empty otherwise."""
    _require_dependency()
    page = max(1, _first_int(params, ("page",)) or 1)
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.recommend.get_radar_recommend(page=page)
        )
    )
    return _tracks_payload(_items_from_search_result(plain, ("songs", "vecSong", "VecSongs")))


async def fetch_recommend_playlists(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Recommended playlists ("歌单推荐"), cursor-paginated by page."""
    _require_dependency()
    page = max(1, _first_int(params, ("page",)) or 1)
    num = max(1, min(_first_int(params, ("limit",)) or 20, 50))
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.recommend.get_recommend_songlist(page=page, num=num)
        )
    )
    items = _items_from_search_result(plain, ("songlists", "List", "list"))
    if not items:
        # Some upstream shapes bury the feed one level deeper.
        items = _items_from_search_result(
            _first_dict(plain, ("data", "feed")), ("songlists", "List", "list")
        )
    payloads = [_songlist_payload(item) for item in items]
    return [item for item in payloads if item.get("id")]


async def fetch_toplist_categories(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Ranking groups ("排行榜") with their member toplists."""
    _require_dependency()
    plain = _to_plain(await _execute_client_request(lambda client: client.top.get_category()))
    groups = _items_from_search_result(plain, ("group", "groups"))
    payloads: list[dict[str, Any]] = []
    for group in groups:
        toplists = _items_from_search_result(group, ("toplist", "toplists"))
        payloads.append(
            {
                "source": SOURCE,
                "id": _first_int(group, ("id",)),
                "name": _first_text(group, ("name", "title")),
                "toplists": [
                    {
                        "source": SOURCE,
                        "id": _first_int(entry, ("id", "topId")),
                        "name": _first_text(entry, ("name", "title")),
                    }
                    for entry in toplists
                    if _first_int(entry, ("id", "topId"))
                ],
            }
        )
    return [group for group in payloads if group.get("toplists")]


async def fetch_playlist_tracks(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Tracks of a playlist (`songlistId`) or a toplist (`topId`)."""
    _require_dependency()
    songlist_id = _first_int(params, ("songlistId", "id"))
    top_id = _first_int(params, ("topId",))
    limit = max(1, min(_first_int(params, ("limit",)) or 50, 100))
    if top_id:
        plain = _to_plain(
            await _execute_client_request(lambda client: client.top.get_detail(top_id=top_id, num=limit))
        )
        return _tracks_payload(_items_from_search_result(plain, ("song", "songs", "songlist")))
    if not songlist_id:
        raise ValueError("songlistId or topId is required")
    # The upstream caps a page at 100; the caller pages explicitly.
    page = max(1, _first_int(params, ("page",)) or 1)
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.songlist.get_detail(
                songlist_id=songlist_id, num=limit, page=page, onlysong=False
            )
        )
    )
    return _tracks_payload(_items_from_search_result(plain, ("songs", "songlist", "list")))


async def fetch_lyric(params: dict[str, Any]) -> dict[str, Any]:
    """Lyrics for a track. Returns LRC text plus the translated track if any."""
    _require_dependency()
    value: Any = _first_int(params, ("songId",)) or str(params.get("songMid") or "").strip()
    if not value:
        raise ValueError("songId or songMid is required")
    want_translation = bool(params.get("translation", True))
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.lyric.get_lyric(value, trans=want_translation)
        )
    )
    return {
        "source": SOURCE,
        "lyric": _first_text(plain, ("lyric", "lrc")),
        "translation": _first_text(plain, ("trans", "tlyric")),
        "romanization": _first_text(plain, ("roma", "romalrc")),
    }


def _credential_summary(credential: Any) -> dict[str, Any]:
    return {
        "loggedIn": credential is not None,
        "musicId": _first_int(credential, ("musicid",)) if credential is not None else None,
        "nickname": _first_text(credential, ("nickname", "nick")) if credential is not None else "",
        "vipType": _first_int(credential, ("vip_type", "vipType")) if credential is not None else None,
    }


async def get_login_status(params: dict[str, Any]) -> dict[str, Any]:
    """Report whether a usable credential is on disk, refreshing it if stale."""
    _require_dependency()
    credential = load_credential()
    if credential is None:
        return {"loggedIn": False}

    expired = False
    try:
        expired = bool(await _execute_with_credential(lambda c: c.login.check_expired()))
    except Exception as exc:
        _log(f"login status check failed reason={type(exc).__name__}: {exc}")

    if expired:
        try:
            refreshed = await _execute_with_credential(lambda c: c.login.refresh_credential())
            if refreshed is not None:
                save_credential(refreshed)
                credential = refreshed
                expired = False
        except Exception as exc:
            _log(f"credential refresh failed reason={type(exc).__name__}: {exc}")

    summary = _credential_summary(credential)
    summary["expired"] = expired
    return summary


async def _execute_with_credential(builder: Any) -> Any:
    """Run a client call against the stored credential."""
    if Client is None:
        return None
    credential = load_credential()
    async with Client(credential=credential) as client:
        return _to_plain(await client.execute(builder(client)))


async def start_login(params: dict[str, Any]) -> dict[str, Any]:
    """Create a login QR code.

    Returns the QR image as base64 PNG plus the identifier the caller must echo
    back when polling, so no login state has to survive between requests.
    """
    _require_dependency()
    import base64

    login_type = str(params.get("loginType") or "qq").strip().lower()
    mapping = {"qq": "QQ", "wx": "WX", "mobile": "MOBILE"}
    member = mapping.get(login_type)
    if member is None:
        raise ValueError(f"unknown loginType: {login_type}")

    async with _new_client() as client:
        qr = await client.login.get_qrcode(getattr(QRLoginType, member))

    raw = qr.data
    image_bytes = base64.b64decode(raw) if isinstance(raw, str) else bytes(raw)
    return {
        "identifier": str(qr.identifier),
        "loginType": login_type,
        "mimetype": str(getattr(qr, "mimetype", "image/png")),
        "imageBase64": base64.b64encode(image_bytes).decode("ascii"),
    }


async def poll_login(params: dict[str, Any]) -> dict[str, Any]:
    """Check one login QR code scan.

    The QR object is reconstructed from the identifier and image the caller
    holds, so this stays stateless across helper restarts.
    """
    _require_dependency()
    import base64

    identifier = str(params.get("identifier") or "").strip()
    image_base64 = str(params.get("imageBase64") or "").strip()
    login_type = str(params.get("loginType") or "qq").strip().lower()
    if not identifier:
        raise ValueError("identifier is required")

    mapping = {"qq": "QQ", "wx": "WX", "mobile": "MOBILE"}
    member = mapping.get(login_type)
    if member is None:
        raise ValueError(f"unknown loginType: {login_type}")

    from qqmusic_api.models.login import QR

    qr = QR(
        data=base64.b64decode(image_base64) if image_base64 else b"",
        qr_type=getattr(QRLoginType, member),
        mimetype=str(params.get("mimetype") or "image/png"),
        identifier=identifier,
    )

    async with _new_client() as client:
        result = await client.login.check_qrcode(qr)

    event = getattr(result, "event", None)
    event_name = getattr(event, "name", str(event))
    credential = getattr(result, "credential", None)
    if event_name == "DONE" and credential is not None:
        save_credential(credential)
        summary = _credential_summary(credential)
        summary["event"] = event_name
        return summary
    return {"event": event_name, "loggedIn": False}


async def logout(params: dict[str, Any]) -> dict[str, Any]:
    """Forget the stored credential."""
    _require_dependency()
    try:
        async with _new_client() as client:
            await client.login.logout()
    except Exception as exc:
        # The local file is the source of truth; a failed upstream logout must
        # not leave the user still logged in locally.
        _log(f"upstream logout failed reason={type(exc).__name__}: {exc}")
    clear_credential()
    return {"loggedIn": False}


async def get_helper_info(params: dict[str, Any]) -> dict[str, Any]:
    """Report the helper's own version and capability list.

    The host uses this to stay compatible with helper builds it did not ship,
    so a newer helper can advertise methods the app does not know about yet.
    """
    return {
        "helperVersion": HELPER_VERSION,
        "protocolVersion": PROTOCOL_VERSION,
        "libraryVersion": _qqmusic_library_version(),
        "methods": sorted(KNOWN_METHODS),
        "credentialDir": bool(_credential_path()),
    }


def _qqmusic_library_version() -> str:
    try:
        module = importlib.import_module("qqmusic_api")
        return str(getattr(module, "__version__", "") or "")
    except Exception:
        return ""


# New-song radio regions. Mirrors the upstream `type` parameter.
NEW_SONG_REGIONS: dict[str, int] = {
    "latest": 5,
    "mainland": 1,
    "europe_us": 2,
    "japan": 3,
    "korea": 4,
    "hongkong_taiwan": 6,
}


async def fetch_new_songs(params: dict[str, Any]) -> list[dict[str, Any]]:
    """New-song radio ("推荐新歌"), filterable by region.

    A far richer source than the guess-you-like radio: one call returns 65-99
    tracks instead of 5, so it is the better choice when the user wants a long
    queue rather than a handful of picks.
    """
    _require_dependency()
    region = str(params.get("region") or "latest").strip().lower()
    song_type = NEW_SONG_REGIONS.get(region)
    if song_type is None:
        raise ValueError(f"unknown region: {region}")
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "newsong.NewSongServer", "get_new_song_info", {"type": song_type}
            )
        )
    )
    return _tracks_payload(_items_from_search_result(plain, ("songlist", "songs", "list")))


async def search_playlists(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Search playlists by keyword.

    This is how category browsing works here: the upstream's playlist-square
    category ids are not usable through the public channel (a `tag_id`-filtered
    request is silently ignored and returns the unfiltered feed), but searching
    playlists by a mood or genre word returns real playlists for it.
    """
    _require_dependency()
    keyword = str(params.get("keyword") or "").strip()
    if not keyword:
        return []
    limit = max(1, min(_first_int(params, ("limit",)) or 20, 50))
    results = await _search_by_type(
        keyword, SearchType.SONGLIST, ("songlist", "songlists", "list"), limit
    )
    payloads: list[dict[str, Any]] = []
    for item in results:
        diss_id = _first_int(item, ("dissid", "tid", "id"))
        if not diss_id:
            continue
        payloads.append(
            {
                "source": SOURCE,
                "id": diss_id,
                "title": _strip_search_highlight(
                    _first_text(item, ("dissname", "title", "name"))
                ),
                "coverURL": _sanitize_image_url(
                    _first_text(item, ("picurl", "imgurl", "cover"))
                ),
                "creator": _first_text(item, ("nickname", "creator", "nick")),
                "songCount": _first_int(item, ("songnum", "song_cnt", "songCount")),
                "playCount": _first_int(item, ("listennum", "play_cnt", "playCount")),
            }
        )
    return payloads


def _strip_search_highlight(value: str) -> str:
    """Search results wrap matched terms in <em>; drop the markup."""
    return re.sub(r"</?em>", "", value or "").strip()


# MARK: - User library (liked songs / albums / playlists)
#
# Reads plus like/unlike. Writing to "我喜欢" **does** work over the web
# channel: `AddSonglist` / `DelSonglist` with `dirId:201` take effect within a
# few seconds. The parameter that matters is `songType`, which must be **0** —
# sending 1 returns a success-shaped payload that changes nothing, which is an
# easy way to conclude the endpoint is dead when it is not. Verified 2026-09-18
# in both directions (472 -> 473 -> 472).
#
# Unlike a track's own `type` field, which is 1 for ordinary songs, the write
# payload wants 0. Do not "fix" this to match the track.

# `dirid` of the "我喜欢" folder. It is a fixed virtual id, not a playlist id.
LIKED_SONGS_DIRID = 201


async def fetch_liked_songs(params: dict[str, Any]) -> dict[str, Any]:
    """Tracks in "我喜欢", paginated.

    The folder reports its own total, so callers can page without guessing.
    """
    _require_dependency()
    page = max(1, _first_int(params, ("page",)) or 1)
    limit = max(1, min(_first_int(params, ("limit",)) or 50, 100))
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.srfDissInfo.DissInfo",
                "CgiGetDiss",
                {
                    "disstid": 0,
                    "dirid": LIKED_SONGS_DIRID,
                    "tag": True,
                    "song_begin": limit * (page - 1),
                    "song_num": limit,
                    "userinfo": True,
                    "orderlist": True,
                },
            )
        )
    )
    info = _first_dict(plain, ("dirinfo",))
    tracks = _tracks_payload(_items_from_search_result(plain, ("songlist", "songs")))
    return {
        "title": _first_text(info, ("title",)) or "我喜欢",
        "total": _first_int(info, ("songnum", "song_num", "total")) or len(tracks),
        "tracks": tracks,
    }


async def fetch_liked_albums(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Favorited albums, resolved to displayable metadata.

    Upstream returns only numeric album ids, so each is resolved through the
    album info endpoint to get a name, `albumMid` (which yields the cover) and
    artist. Ids are resolved concurrently because the cost is round-trip, but
    the batch is capped to stay well under upstream rate limits.
    """
    _require_dependency()
    limit = max(1, min(_first_int(params, ("limit",)) or 30, 50))
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.musicasset.AlbumFavRead", "GetAlbumFavList", {"From": 0, "Size": limit}
            )
        )
    )
    ids = [int(x) for x in (plain.get("v_albumId") or []) if str(x).isdigit()][:limit]
    if not ids:
        return []

    details = await asyncio.gather(
        *[_fetch_album_basic(album_id) for album_id in ids],
        return_exceptions=True,
    )
    albums: list[dict[str, Any]] = []
    for album_id, detail in zip(ids, details):
        if isinstance(detail, BaseException) or not detail:
            # Keep the row so the count stays truthful, even without metadata.
            albums.append({"source": SOURCE, "id": album_id, "title": f"专辑 {album_id}", "coverURL": "", "artist": ""})
            continue
        albums.append(detail)
    return albums


async def _fetch_album_basic(album_id: int) -> dict[str, Any]:
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.musichallAlbum.AlbumInfoServer",
                "GetAlbumDetail",
                {"albumId": album_id},
            )
        )
    )
    basic = _first_dict(plain, ("basicInfo",))
    album_mid = _first_text(basic, ("albumMid",))
    singers = _singers_text_from_list(((plain.get("singer") or {}).get("singerList")) or [])
    return {
        "source": SOURCE,
        "id": album_id,
        "title": _first_text(basic, ("albumName", "name")) or f"专辑 {album_id}",
        "albumMid": album_mid,
        "coverURL": _sanitize_image_url(_album_cover_url(album_mid)),
        "artist": singers,
        "releaseDate": _first_text(basic, ("publishDate",)),
    }


async def fetch_album_tracks(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Tracks of an album, addressed by its numeric id.

    Favorited albums are only identified by numeric id, and `album.get_detail`
    returns an empty payload for those, so the song list is requested directly
    by id with a large page size.
    """
    _require_dependency()
    album_id = _first_int(params, ("albumId", "id"))
    if not album_id:
        raise ValueError("albumId is required")
    limit = max(1, min(_first_int(params, ("limit",)) or 100, 300))
    # Built as a raw CGI request on purpose: `client.album.get_song` returns a
    # parsed model whose fields are snake_cased (`song_list`), which the payload
    # normaliser does not recognise — it would silently yield an empty list.
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.musichallAlbum.AlbumSongList",
                "GetAlbumSongList",
                {"albumId": album_id, "begin": 0, "num": limit},
            )
        )
    )
    return _tracks_payload(_items_from_search_result(plain, ("songList", "songs", "list")))


async def fetch_user_playlists(params: dict[str, Any]) -> list[dict[str, Any]]:
    """The account's own playlists (created and favorited).

    Must go through the legacy `c.y.qq.com` fcgi: every candidate method on
    `music.musicasset.PlaylistBaseRead` answers 40000, verified 2026-09-18.
    """
    _require_dependency()
    credential = load_credential()
    uin = ""
    if credential is not None:
        uin = str(getattr(credential, "str_musicid", "") or getattr(credential, "musicid", "") or "")
    if not uin:
        raise ValueError("需要登录后才能读取歌单")

    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_http(
                "GET",
                "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg",
                params={
                    "ct": "20",
                    "cid": "205360956",
                    "userid": uin,
                    "reqtype": "3",
                    "sin": "0",
                    "ein": "100",
                },
            )
        )
    )
    items = _items_from_search_result(_first_dict(plain, ("data",)), ("cdlist", "disslist", "list"))
    playlists: list[dict[str, Any]] = []
    for item in items or []:
        diss_id = _first_int(item, ("dissid", "tid", "id"))
        if not diss_id:
            continue
        playlists.append(
            {
                "source": SOURCE,
                "id": diss_id,
                "title": _first_text(item, ("dissname", "name", "title")),
                "coverURL": _sanitize_image_url(_first_text(item, ("logo", "picurl", "cover"))),
                "creator": _first_text(item, ("nickname", "creator", "nick")),
                "songCount": _first_int(item, ("songnum", "song_cnt", "songCount")),
                "playCount": _first_int(item, ("listennum", "play_cnt", "playCount")),
            }
        )
    return playlists


#: `songType` accepted by the playlist write endpoints. Must be 0 — see the
#: note above; the track's own `type` field is unrelated.
PLAYLIST_WRITE_SONG_TYPE = 0


async def _song_id_for_mid(song_mid: str) -> int:
    """Resolve a song mid to the numeric id the write endpoints require.

    `set_liked` cannot take a mid — the upstream answers 1101 for one, verified
    2026-09-18 — so the id is looked up first. Callers that already hold the
    numeric id should pass it and skip this.
    """
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.trackInfo.UniformRuleCtrl",
                "CgiGetTrackInfo",
                {"ctx": 0, "client": 1, "mids": [song_mid], "types": [0], "modify_stamp": [0]},
            )
        )
    )
    track = _first_dict(plain, ("track_info", "trackInfo"))
    if not track:
        items = _items_from_search_result(plain, ("tracks", "track_list", "list"))
        track = items[0] if items else {}
    return _first_int(track, ("id", "songId", "songid")) or 0


async def _playlist_write(method: str, song_id: int, dirid: int) -> bool:
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.musicasset.PlaylistDetailWrite",
                method,
                {
                    "dirId": dirid,
                    "tid": 0,
                    "bFmtUtf8": True,
                    "v_songInfo": [
                        {"songId": song_id, "songType": PLAYLIST_WRITE_SONG_TYPE}
                    ],
                },
            )
        )
    )
    # Response shape: {"msg": "", "result": {...}, "retCode": 0}. `retCode` is
    # the success signal and sits at the top level, not inside `result`.
    ret_code = _first_int(plain, ("retCode", "ret_code"))
    if ret_code is not None:
        return ret_code == 0
    return _first_int(plain, ("code",)) == 0


async def set_liked(params: dict[str, Any]) -> dict[str, Any]:
    """Add or remove a track from "我喜欢".

    Takes effect asynchronously upstream, so callers should treat the returned
    `liked` as intent and re-read the list to confirm rather than assuming the
    change is already visible.
    """
    _require_dependency()
    song_id = _first_int(params, ("songId",))
    if not song_id:
        # Accept a mid too, so callers holding only the library's stored
        # identifier do not have to resolve it themselves.
        song_mid = str(params.get("songMid") or "").strip()
        if not song_mid:
            raise ValueError("songId or songMid is required")
        song_id = await _song_id_for_mid(song_mid)
        if not song_id:
            raise ValueError(f"无法解析 {song_mid} 的数字 id")
    liked = bool(params.get("liked", True))
    method = "AddSonglist" if liked else "DelSonglist"
    ok = await _playlist_write(method, song_id, LIKED_SONGS_DIRID)
    return {"songId": song_id, "liked": liked, "ok": ok}


async def is_liked(params: dict[str, Any]) -> dict[str, Any]:
    """Whether a track is in "我喜欢", by scanning the folder.

    There is no per-track membership endpoint on the web channel, so this reads
    the folder and looks for the id. Callers should prefer checking against a
    list they already hold.
    """
    _require_dependency()
    song_id = _first_int(params, ("songId",))
    song_mid = str(params.get("songMid") or "").strip()
    if not song_id:
        if not song_mid:
            raise ValueError("songId or songMid is required")
        song_id = await _song_id_for_mid(song_mid)
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "music.srfDissInfo.DissInfo",
                "CgiGetDiss",
                {
                    "disstid": 0,
                    "dirid": LIKED_SONGS_DIRID,
                    "tag": True,
                    "song_begin": 0,
                    "song_num": 100,
                    "userinfo": True,
                    "orderlist": True,
                },
            )
        )
    )
    tracks = _tracks_payload(_items_from_search_result(plain, ("songlist", "songs")))
    return {"songId": song_id, "liked": any(t.get("songId") == song_id for t in tracks)}


# MARK: - Radio stations ("电台")
#
# Discovered by reading the radio page's own bundle rather than guessing method
# names (`pf.radiosvr`, not `music.radioProxy`). The upstream site special-cases
# id 99 to a different method, but `GetRadiosonglist` was measured to work for
# every station tried (99/101/567/686/673/270/127/167), so no id is hardcoded
# here — ids only ever come from `GetRadiolist`.


async def fetch_radio_stations(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Grouped radio station list ("电台")."""
    _require_dependency()
    credential = load_credential()
    uin = ""
    if credential is not None:
        uin = str(getattr(credential, "str_musicid", "") or getattr(credential, "musicid", "") or "0")
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "pf.radiosvr", "GetRadiolist", {"uin": uin or "0"}
            )
        )
    )
    groups = _items_from_search_result(plain, ("radio_list", "list"))
    payload: list[dict[str, Any]] = []
    for group in groups:
        items = _items_from_search_result(group, ("list", "radios"))
        stations = []
        for item in items:
            station_id = _first_int(item, ("id",))
            if not station_id:
                continue
            stations.append(
                {
                    "source": SOURCE,
                    "id": station_id,
                    "title": _first_text(item, ("title", "name")),
                    "coverURL": _sanitize_image_url(_first_text(item, ("pic_url", "picUrl"))),
                    "listenerCount": _first_int(item, ("listenNum", "listen_num")),
                }
            )
        if stations:
            payload.append(
                {
                    "id": _first_int(group, ("id",)),
                    "name": _first_text(group, ("title", "name")),
                    "stations": stations,
                }
            )
    return payload


async def fetch_radio_tracks(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Tracks of a radio station.

    `firstplay` restarts the station's rotation; subsequent calls continue it.
    """
    _require_dependency()
    station_id = _first_int(params, ("stationId", "id"))
    if not station_id:
        raise ValueError("stationId is required")
    num = max(1, min(_first_int(params, ("limit",)) or 20, 50))
    first_play = 1 if params.get("firstPlay", True) else 0
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.song._build_cgi(
                "pf.radiosvr",
                "GetRadiosonglist",
                {"id": station_id, "firstplay": first_play, "num": num},
            )
        )
    )
    data = _first_dict(plain, ("data",)) or plain
    return _tracks_payload(_items_from_search_result(data, ("track_list", "songlist", "tracks")))


async def search_artists(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Artist search with song/album counts, for the search page."""
    _require_dependency()
    keyword = str(params.get("keyword") or "").strip()
    if not keyword:
        return []
    limit = max(1, min(_first_int(params, ("limit",)) or 20, 50))
    results = await _search_by_type(
        keyword, SearchType.SINGER, ("singer", "singers", "list"), limit
    )
    payload: list[dict[str, Any]] = []
    for item in results:
        mid = _first_text(item, ("mid", "singerMID", "singerMid"))
        if not mid:
            continue
        payload.append(
            {
                "source": SOURCE,
                "singerMid": mid,
                "name": _strip_search_highlight(_first_text(item, ("name", "title", "singerName"))),
                "coverURL": _sanitize_image_url(
                    _first_text(item, ("pic", "singerPic", "image")) or _singer_cover_url(mid)
                ),
                "songCount": _first_int(item, ("song_num", "songNum", "musicSize")),
                "albumCount": _first_int(item, ("album_num", "albumNum", "albumSize")),
            }
        )
    return payload


async def fetch_artist_biography(params: dict[str, Any]) -> dict[str, Any]:
    """Artist biography and basic facts, by singer mid.

    Distinct from `fetch_artist_detail`, which serves library metadata
    enrichment; naming it the same silently shadowed that method.
    """
    _require_dependency()
    singer_mid = str(params.get("singerMid") or "").strip()
    if not singer_mid:
        raise ValueError("singerMid is required")

    description = ""
    foreign_name = ""
    genre_tags: list[str] = []
    region = ""
    try:
        plain = _to_plain(
            await _execute_client_request(lambda client: client.singer.get_desc([singer_mid]))
        )
        item = (_items_from_search_result(plain, ("singer_list", "singerList", "list")) or [{}])[0]
        ex = _first_dict(item, ("ex_info", "exInfo"))
        description = _first_text(ex, ("desc", "description"))
        foreign_name = _first_text(ex, ("foreign_name", "foreignName", "other_name"))
        region = _first_text(ex, ("area", "country", "region"))
        genre_tags = _split_tags(_first_text(ex, ("genre", "tag")))
    except Exception as exc:
        # A missing biography is not a failure of the page.
        _log(f"artist desc failed singerMid={singer_mid} reason={type(exc).__name__}: {exc}")

    return {
        "source": SOURCE,
        "singerMid": singer_mid,
        "description": description,
        "foreignName": foreign_name,
        "region": region,
        "genreTags": genre_tags,
    }


async def fetch_artist_songs(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Songs of an artist, by singer mid.

    Supports `sort`: `hot` (upstream default ordering) or `latest` (by album
    release date, newest first). The upstream ignores every ordering parameter
    tried (`order` 0/1/2 all return the same list), so `latest` is computed
    here from each track's album `time_public`, which the response does carry.
    """
    _require_dependency()
    singer_mid = str(params.get("singerMid") or "").strip()
    if not singer_mid:
        raise ValueError("singerMid is required")
    num = max(1, min(_first_int(params, ("limit",)) or 50, 100))
    page = max(1, _first_int(params, ("page",)) or 1)
    sort = str(params.get("sort") or "hot").strip().lower()
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.singer.get_songs_list(singer_mid, num=num, page=page)
        )
    )
    items = _items_from_search_result(plain, ("song_list", "songList", "list"))
    tracks = _tracks_payload(items)
    if sort == "latest":
        # Attach the release date so the ordering is explainable, then sort.
        # Tracks without a date sink to the end rather than being dropped.
        for track, item in zip(tracks, items):
            album = _first_dict(item, ("album", "albumInfo"))
            track["releaseDate"] = _first_text(album, ("time_public", "publishDate"))
        tracks.sort(key=lambda t: t.get("releaseDate") or "", reverse=True)
    return tracks


async def fetch_artist_albums(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Albums of an artist, by singer mid."""
    _require_dependency()
    singer_mid = str(params.get("singerMid") or "").strip()
    if not singer_mid:
        raise ValueError("singerMid is required")
    num = max(1, min(_first_int(params, ("limit",)) or 50, 100))
    page = max(1, _first_int(params, ("page",)) or 1)
    plain = _to_plain(
        await _execute_client_request(
            lambda client: client.singer.get_album_list(singer_mid, num=num, page=page)
        )
    )
    items = _items_from_search_result(plain, ("album_list", "albumList", "list"))
    albums: list[dict[str, Any]] = []
    for item in items:
        album_mid = _album_mid(item)
        album_id = _first_int(item, ("id", "albumId"))
        if not album_mid and not album_id:
            continue
        albums.append(
            {
                "source": SOURCE,
                "id": album_id or 0,
                "title": _first_text(item, ("name", "title", "albumName")),
                "albumMid": album_mid,
                "coverURL": _sanitize_image_url(_album_cover_url(album_mid)),
                "artist": _first_text(item, ("singer_name", "singerName")),
                "releaseDate": _first_text(item, ("time_public", "publishDate")),
            }
        )
    return albums



async def handle_request(request: dict[str, Any]) -> dict[str, Any]:
    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") or {}
    if not isinstance(params, dict):
        raise ValueError("params must be an object")

    started_at = time.monotonic()
    _log(f"request id={request_id} method={method}")
    if method == "search_artist_artwork":
        candidates = await search_artist_artwork(params)
    elif method == "search_track_artwork":
        candidates = await search_track_artwork(params)
    elif method == "search_album_artwork":
        candidates = await search_album_artwork(params)
    elif method == "fetch_artist_detail":
        detail = await fetch_artist_detail(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"detail=1 confidence={float(detail.get('confidence') or 0):.2f} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "detail": detail}
    elif method == "fetch_album_detail":
        detail = await fetch_album_detail(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"detail=1 confidence={float(detail.get('confidence') or 0):.2f} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "detail": detail}
    elif method == "fetch_song_detail":
        detail = await fetch_song_detail(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"detail=1 confidence={float(detail.get('confidence') or 0):.2f} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "detail": detail}
    elif method == "search_songs":
        tracks = await search_songs(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "fetch_recommend_feed":
        tracks = await fetch_recommend_feed(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "fetch_radar":
        tracks = await fetch_radar(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "fetch_playlist_tracks":
        tracks = await fetch_playlist_tracks(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "fetch_new_songs":
        tracks = await fetch_new_songs(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "set_liked":
        result = await set_liked(params)
        _log(f"response id={request_id} method={method} liked={result.get('liked')} ok={result.get('ok')}")
        return {"id": request_id, "ok": True, "like": result}
    elif method == "is_liked":
        result = await is_liked(params)
        return {"id": request_id, "ok": True, "like": result}
    elif method == "fetch_radio_stations":
        groups = await fetch_radio_stations(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        total = sum(len(g.get("stations") or []) for g in groups)
        _log(f"response id={request_id} method={method} groups={len(groups)} stations={total} durationMs={duration_ms}")
        return {"id": request_id, "ok": True, "radioGroups": groups}
    elif method == "fetch_radio_tracks":
        tracks = await fetch_radio_tracks(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "search_artists":
        artists = await search_artists(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(f"response id={request_id} method={method} artists={len(artists)} durationMs={duration_ms}")
        return {"id": request_id, "ok": True, "artists": artists}
    elif method == "fetch_artist_biography":
        detail = await fetch_artist_biography(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"descLen={len(detail.get('description') or '')} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "artistDetail": detail}
    elif method == "fetch_artist_songs":
        tracks = await fetch_artist_songs(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "fetch_artist_albums":
        albums = await fetch_artist_albums(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(f"response id={request_id} method={method} albums={len(albums)} durationMs={duration_ms}")
        return {"id": request_id, "ok": True, "albums": albums}
    elif method == "fetch_liked_songs":
        payload = await fetch_liked_songs(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"tracks={len(payload.get('tracks') or [])} total={payload.get('total')} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "likedSongs": payload}
    elif method == "fetch_liked_albums":
        albums = await fetch_liked_albums(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(f"response id={request_id} method={method} albums={len(albums)} durationMs={duration_ms}")
        return {"id": request_id, "ok": True, "albums": albums}
    elif method == "fetch_album_tracks":
        tracks = await fetch_album_tracks(params)
        return _tracks_response(request_id, method, tracks, started_at)
    elif method == "fetch_user_playlists":
        playlists = await fetch_user_playlists(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(f"response id={request_id} method={method} playlists={len(playlists)} durationMs={duration_ms}")
        return {"id": request_id, "ok": True, "playlists": playlists}
    elif method == "search_playlists":
        playlists = await search_playlists(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"playlists={len(playlists)} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "playlists": playlists}
    elif method == "fetch_recommend_playlists":
        playlists = await fetch_recommend_playlists(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"playlists={len(playlists)} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "playlists": playlists}
    elif method == "fetch_toplist_categories":
        groups = await fetch_toplist_categories(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(f"response id={request_id} method={method} groups={len(groups)} durationMs={duration_ms}")
        return {"id": request_id, "ok": True, "toplistGroups": groups}
    elif method == "fetch_lyric":
        lyric = await fetch_lyric(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"lyricLen={len(lyric.get('lyric') or '')} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "lyric": lyric}
    elif method == "resolve_song_url":
        stream = await resolve_song_url(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"playable={bool(stream.get('playable'))} quality={stream.get('quality') or '-'} "
            f"durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "stream": stream}
    elif method == "get_helper_info":
        info = await get_helper_info(params)
        return {"id": request_id, "ok": True, "helper": info}
    elif method == "get_login_status":
        status = await get_login_status(params)
        return {"id": request_id, "ok": True, "login": status}
    elif method == "start_login":
        qr = await start_login(params)
        _log(f"response id={request_id} method={method} loginType={qr.get('loginType')}")
        return {"id": request_id, "ok": True, "qrcode": qr}
    elif method == "poll_login":
        status = await poll_login(params)
        _log(f"response id={request_id} method={method} event={status.get('event')}")
        return {"id": request_id, "ok": True, "login": status}
    elif method == "logout":
        status = await logout(params)
        return {"id": request_id, "ok": True, "login": status}
    elif method == "import_cookies":
        status = import_cookies(params)
        _log(f"response id={request_id} method={method} loggedIn={status.get('loggedIn')}")
        return {"id": request_id, "ok": True, "login": status}
    else:
        raise ValueError(f"unsupported method: {method}")

    duration_ms = int((time.monotonic() - started_at) * 1000)
    top_confidence = max((float(item.get("confidence") or 0) for item in candidates), default=0.0)
    _log(
        f"response id={request_id} method={method} "
        f"candidates={len(candidates)} topConfidence={top_confidence:.2f} durationMs={duration_ms}"
    )
    return {"id": request_id, "ok": True, "candidates": candidates}


# Serializes writing to stdout. Requests are handled concurrently, so two
# responses must never interleave within one line.
_stdout_lock = asyncio.Lock()


async def _write_response(payload: dict[str, Any]) -> None:
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    async with _stdout_lock:
        print(line, flush=True)


async def _serve_one(request: dict[str, Any]) -> None:
    """Handle a single request and write its response."""
    try:
        if not isinstance(request, dict):
            raise ValueError("request must be an object")
        response = await handle_request(request)
    except Exception as exc:
        request_id = None
        try:
            request_id = request.get("id") if isinstance(request, dict) else None
        except Exception:
            request_id = None
        _log(traceback.format_exc())
        response = {"id": request_id, "ok": False, "error": f"{type(exc).__name__}: {exc}"}
    await _write_response(response)


async def main() -> int:
    _log(f"startup {_dependency_diagnostics()}")
    # Each request runs as its own task. Handling them inline made the helper a
    # bottleneck: the app fires several independent calls at once (feed,
    # playlists, rankings), and the upstream round-trip is the whole cost, so
    # serializing them multiplied the wait. Measured with 3 concurrent searches:
    # 4.42s inline vs ~1.9s when dispatched.
    pending: set[asyncio.Task[None]] = set()
    while True:
        line = await asyncio.to_thread(sys.stdin.buffer.readline)
        if not line:
            break
        try:
            request = json.loads(line.decode("utf-8"))
        except Exception:
            _log(traceback.format_exc())
            await _write_response({"id": None, "ok": False, "error": "invalid JSON request"})
            continue

        task = asyncio.create_task(_serve_one(request))
        pending.add(task)
        task.add_done_callback(pending.discard)

    # stdin closed: let in-flight work finish rather than truncating responses.
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
