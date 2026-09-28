#!/usr/bin/env python3
"""Helper for the robbie.cliamp bar widget.

Talks to the cliamp player (https://cliamp.stream) through its CLI/IPC and
covers three jobs that are awkward from QML:

  * `poll` — one call returning a normalized runtime snapshot plus the two
    station lists (the built-in "default" stations from radio.cliamp.stream
    and the favourites from ~/.config/cliamp/favorites.toml). The default
    station list is fetched from the upstream streams.m3u and cached so the
    widget does not wait on the network on every poll.
  * `play <url>` — play a stream in the running instance right now (v2
    `url.load` with play=true).
  * `search <query>` — query the Radio Browser (radio-browser.info) directory
    for stations matching the query; prints a compact JSON list.
  * `favorite <url> <title>` — toggle a station in favourites.toml (add if
    absent, remove if already there); prints the updated favourites list.
  * `raw <args...>` — a pass-through to `cliamp <args>` for playback control
    commands (toggle/next/prev/stop/...). The exit code is the only output
    the widget cares about.

Every command prints one line of JSON (except `raw`, which stays silent so a
wall of error text never reaches the widget).
"""

import datetime
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.parse
import urllib.request

CONFIG_DIR = os.path.expanduser("~/.config/cliamp")
STATE_DIR = os.path.expanduser("~/.local/state/omarchy/settings")
FAVORITES_PATH = os.path.join(CONFIG_DIR, "favorites.toml")
STREAMS_URL = "https://radio.cliamp.stream/streams.m3u"
STREAMS_CACHE = os.path.join(STATE_DIR, "cliamp-default-stations.json")
STREAMS_TTL_SECONDS = 12 * 60 * 60
RADIO_BROWSER = "https://de1.api.radio-browser.info/json/stations/search"

# Fallback copy of the upstream streams.m3u in case the network is down. The
# cached copy (refreshed on a TTL) takes precedence as soon as it exists.
FALLBACK_STATIONS = [
    {"title": "Lofi", "url": "https://radio.cliamp.stream/lofi/stream"},
    {"title": "Meditative", "url": "https://radio.cliamp.stream/meditative/stream"},
    {"title": "Synthwave", "url": "https://radio.cliamp.stream/synthwave/stream"},
    {"title": "EDM", "url": "https://radio.cliamp.stream/edm/stream"},
    {"title": "Omarchy", "url": "https://radio.cliamp.stream/omarchy/stream"},
    {"title": "Chiptunes", "url": "https://radio.cliamp.stream/chiptune/stream"},
    {"title": "Amiga", "url": "https://radio.cliamp.stream/amiga/stream"},
    {"title": "NCS", "url": "https://radio.cliamp.stream/ncs/stream"},
    {"title": "NCS House", "url": "https://radio.cliamp.stream/ncs-house/stream"},
    {"title": "NCS Dubstep", "url": "https://radio.cliamp.stream/ncs-dubstep/stream"},
    {"title": "NCS Drum & Bass", "url": "https://radio.cliamp.stream/ncs-dnb/stream"},
    {"title": "NCS Trap", "url": "https://radio.cliamp.stream/ncs-trap/stream"},
    {"title": "NCS Phonk", "url": "https://radio.cliamp.stream/ncs-phonk/stream"},
    {"title": "NCS Pop", "url": "https://radio.cliamp.stream/ncs-pop/stream"},
    {"title": "NCS Chill", "url": "https://radio.cliamp.stream/ncs-chill/stream"},
]


def run_cliamp(args, timeout=8):
    try:
        proc = subprocess.run(["cliamp", *args], capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout
    except Exception:
        return 1, ""


def parse_m3u(text):
    stations = []
    title = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#EXTINF"):
            title = line.split(",", 1)[1] if "," in line else line
        elif line.startswith("#"):
            continue
        else:
            stations.append({"title": title or line, "url": line})
            title = None
    return stations


def fetch_streams():
    try:
        with urllib.request.urlopen(STREAMS_URL, timeout=8) as response:
            body = response.read().decode("utf-8", "replace")
        stations = parse_m3u(body)
        return stations if stations else None
    except Exception:
        return None


def default_stations():
    try:
        cached = None
        if os.path.exists(STREAMS_CACHE):
            with open(STREAMS_CACHE, "r", encoding="utf-8") as handle:
                cached = json.load(handle)
        fresh = cached and (cached.get("stations") or []) and \
            (cached.get("fetched_at") or 0) + STREAMS_TTL_SECONDS > _now()
        if fresh:
            return cached["stations"]
        stations = fetch_streams()
        if stations:
            try:
                os.makedirs(STATE_DIR, exist_ok=True)
                with open(STREAMS_CACHE, "w", encoding="utf-8") as handle:
                    json.dump({"fetched_at": _now(), "stations": stations}, handle)
            except Exception:
                pass
            return stations
        if cached and cached.get("stations"):
            return cached["stations"]
    except Exception:
        pass
    return FALLBACK_STATIONS


def favorite_stations():
    if not os.path.exists(FAVORITES_PATH):
        return []
    try:
        with open(FAVORITES_PATH, "rb") as handle:
            data = tomllib.load(handle)
    except Exception:
        return []
    entries = data.get("entry") or []
    out = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("path"):
            continue
        out.append({"title": entry.get("title") or entry["path"], "url": entry["path"]})
    return out


def _toml_quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_favorites(entries):
    """Rewrite favorites.toml in cliamp's own `[[entry]]` format, atomically."""
    lines = []
    for entry in entries:
        lines.append("[[entry]]")
        lines.append("favorited_at = %s" % _toml_quote(entry.get("favorited_at", "")))
        lines.append("path = %s" % _toml_quote(entry.get("path", "")))
        lines.append("title = %s" % _toml_quote(entry.get("title", "")))
        if entry.get("realtime"):
            lines.append("realtime = true")
        lines.append("")
    body = "\n".join(lines).rstrip() + "\n"
    tmp = FAVORITES_PATH + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.replace(tmp, FAVORITES_PATH)
        return True
    except Exception:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except Exception:
            pass
        return False


def read_favorites_entries():
    if not os.path.exists(FAVORITES_PATH):
        return []
    try:
        with open(FAVORITES_PATH, "rb") as handle:
            data = tomllib.load(handle)
    except Exception:
        return []
    entries = data.get("entry") or []
    return [e for e in entries if isinstance(e, dict)]


def cmd_favorite(url, title):
    """Toggle a station in favourites.toml (add if absent, remove if present)."""
    entries = read_favorites_entries()
    existed = any(e.get("path") == url for e in entries)
    if existed:
        entries = [e for e in entries if e.get("path") != url]
        added = False
    else:
        favorited_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        entries.append({
            "path": url,
            "title": title or url,
            "favorited_at": favorited_at,
            "realtime": True,
        })
        added = True
    ok = write_favorites(entries)
    result = {
        "ok": ok,
        "added": added,
        "favorites": [
            {"title": e.get("title") or e["path"], "url": e["path"]}
            for e in entries if e.get("path")
        ],
    }
    print(json.dumps(result))


def _now():
    import time
    return int(time.time())


def poll_status():
    rc, out = run_cliamp(["remote", "state"])
    running = rc == 0 and out.lstrip().startswith("{")
    if not running:
        return {
            "running": False,
            "state": "stopped",
            "title": "",
            "path": "",
            "position": None,
            "duration": None,
            "seekable": False,
            "total": 0,
            "index": -1,
        }
    try:
        snapshot = json.loads(out)
        if isinstance(snapshot, dict):
            snapshot = snapshot.get("snapshot") or {}
        else:
            snapshot = {}
    except Exception:
        snapshot = {}
    if not isinstance(snapshot, dict):
        snapshot = {}
    track = snapshot.get("logical_track") or {}
    return {
        "running": True,
        "state": snapshot.get("state") or "stopped",
        "title": (track.get("title") or "") if isinstance(track, dict) else "",
        "path": (track.get("path") or "") if isinstance(track, dict) else "",
        "position": snapshot.get("position"),
        "duration": snapshot.get("duration"),
        "seekable": bool(snapshot.get("seekable")),
        "total": snapshot.get("total") or 0,
        "index": snapshot.get("index"),
        "shuffle": snapshot.get("shuffle"),
        "repeat": snapshot.get("repeat"),
    }


def cmd_poll():
    status = poll_status()
    status["stations"] = {
        "default": default_stations(),
        "favorites": favorite_stations(),
    }
    print(json.dumps(status))


def search_radio_browser(name="", tag="", limit=60):
    params = {
        "order": "clickcount",
        "reverse": "true",
        "hidebroken": "true",
        "limit": str(limit),
    }
    if tag:
        params["tag"] = tag
    if name:
        params["name"] = name
    url = RADIO_BROWSER + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
    except Exception:
        return []
    if not isinstance(payload, list):
        return []
    return payload


def search_stations(query, limit=60):
    words = query.split()
    attempts = [" ".join(words[:i + 1]) for i in range(len(words) - 1, -1, -1)]
    attempts.append("")
    payload = []
    attempted = None
    for name_attempt in attempts:
        attempted = name_attempt
        payload = search_radio_browser(name=name_attempt, limit=limit)
        if payload:
            break
    if not payload:
        last = words[-1] if words else None
        if last:
            payload = search_radio_browser(name=last, limit=limit)
    out = []
    seen = set()
    for station in payload:
        if not isinstance(station, dict):
            continue
        title = (station.get("name") or "").strip()
        url = (station.get("url_resolved") or station.get("url") or "").strip()
        if not title or not url or url in seen:
            continue
        seen.add(url)
        out.append({
            "title": title,
            "url": url,
            "country": station.get("countrycode") or "",
            "tags": station.get("tags") or "",
            "votes": station.get("votes") or 0,
            "bitrate": station.get("bitrate") or 0,
        })
    return out


def cmd_search(query):
    print(json.dumps({"query": query, "results": search_stations(query)}))


def cmd_play(url):
    params = json.dumps({"path": url, "play": True})
    rc, out = run_cliamp(["remote", "call", "url.load", "--params", params])
    print(json.dumps({"ok": rc == 0, "output": out.strip()}))


def cmd_raw(args):
    rc, out = run_cliamp(args)
    if rc != 0 and out.strip():
        print(out.strip(), file=sys.stderr)
    sys.exit(rc)


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "missing command"}), file=sys.stderr)
        sys.exit(2)
    command = sys.argv[1]
    if command == "poll":
        cmd_poll()
    elif command == "play":
        if len(sys.argv) < 3:
            print(json.dumps({"ok": False, "error": "missing url"}), file=sys.stderr)
            sys.exit(2)
        cmd_play(sys.argv[2])
    elif command == "search":
        if len(sys.argv) < 3:
            print(json.dumps({"ok": False, "error": "missing query"}), file=sys.stderr)
            sys.exit(2)
        cmd_search(sys.argv[2])
    elif command == "favorite":
        if len(sys.argv) < 3:
            print(json.dumps({"ok": False, "error": "missing url"}), file=sys.stderr)
            sys.exit(2)
        cmd_favorite(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    elif command == "raw":
        cmd_raw(sys.argv[2:])
    else:
        print(json.dumps({"ok": False, "error": "unknown command: " + command}), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()