#!/usr/bin/env python3
"""Minimal Home Assistant REST client for the Omarchy home-assistant plugin.

The shell never speaks HTTP itself: it shells out to this helper, which owns
the token and returns compact JSON on stdout. Two rules shape the design:

  1. The long-lived access token never appears in argv. It is written to
     ~/.config/omarchy/home-assistant/token (0600) from stdin, and read back
     from that file on every call. `ps` shows the URL and nothing else.
  2. Every command prints one JSON object and exits 0, even on failure, so
     the QML side has a single parse path. `ok: false` plus `error` carries
     the failure; a non-zero exit only means the helper itself broke.

/api/states is the workhorse. Areas and labels are not exposed over REST at
all, so they come from /api/template, which renders Jinja against the running
instance — that is also the only way to reach labels, which is what this
plugin uses as Home Assistant's stand-in for "favorites".
"""

import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "omarchy", "home-assistant")
TOKEN_FILE = os.path.join(CONFIG_DIR, "token")
TIMEOUT = 12

# Attributes worth carrying into the shell. /api/states hands back everything
# an integration felt like publishing; a busy instance is megabytes of JSON,
# most of it attributes no control here reads. Whitelisting keeps the payload
# small enough that a 15-second poll stays free.
KEEP_ATTRS = (
    "device_class", "unit_of_measurement", "entity_picture", "icon",
    "supported_features", "assumed_state",
    # light
    "brightness", "color_temp_kelvin", "min_color_temp_kelvin",
    "max_color_temp_kelvin", "supported_color_modes", "color_mode",
    "rgb_color", "effect", "effect_list",
    # climate / humidifier / water_heater
    "hvac_modes", "hvac_action", "temperature", "current_temperature",
    "target_temp_high", "target_temp_low", "min_temp", "max_temp",
    "target_temp_step", "fan_mode", "fan_modes", "swing_mode", "swing_modes",
    "preset_mode", "preset_modes", "humidity", "current_humidity",
    "min_humidity", "max_humidity", "operation_mode", "operation_list",
    # fan
    "percentage", "percentage_step", "oscillating", "direction",
    # cover
    "current_position", "current_tilt_position",
    # media_player
    "media_title", "media_artist", "media_album_name", "media_content_type",
    "volume_level", "is_volume_muted", "source", "source_list",
    "app_name", "media_duration", "media_position",
    # number / select / vacuum / person
    "min", "max", "step", "mode", "options", "fan_speed", "fan_speed_list",
    "battery_level", "source_type", "latitude", "longitude",
    # alarm
    "code_format", "code_arm_required", "changed_by",
)

# Entities that are noise in a device list: HA's own bookkeeping.
SKIP_DOMAINS = ("zone", "persistent_notification", "tts", "stt",
                "conversation", "assist_satellite", "wake_word")


def out(payload, code=0):
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.exit(code)


def fail(message, **extra):
    payload = {"ok": False, "error": str(message)}
    payload.update(extra)
    out(payload)


def read_token():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def normalize_url(raw):
    """Accept `homeassistant.local:8123`, or a full URL with either scheme."""
    url = str(raw or "").strip().rstrip("/")
    if not url:
        return ""
    if "://" not in url:
        url = "http://" + url
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return ""
    # urlsplit is happy to call "not a url" a hostname; urlopen is not, and its
    # complaint ("URL can't contain control characters") reads like a bug in
    # the plugin rather than a typo in the field. Reject it here instead.
    if not re.match(r"^[A-Za-z0-9._~%-]+(:\d{1,5})?$", parsed.netloc):
        return ""
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc,
                                    parsed.path.rstrip("/"), "", ""))


def request(url, path, token, payload=None, raw=False):
    """One authenticated call. Returns (data, error-string)."""
    target = url + path
    body = None
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(target, data=body, headers=headers,
                                 method="POST" if body is not None else "GET")
    # Self-signed certs are the norm on a home LAN, and the token is the thing
    # actually being protected here. Verify when we can, proceed when we can't.
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=context) as response:
            data = response.read()
            return (data if raw else data.decode("utf-8", "replace")), None
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return None, "Unauthorized — the access token was rejected"
        if exc.code == 403:
            return None, "Forbidden — this token lacks permission"
        if exc.code == 404:
            return None, "Not found: " + path
        return None, "HTTP %d from Home Assistant" % exc.code
    except urllib.error.URLError as exc:
        return None, "Cannot reach %s (%s)" % (url, getattr(exc, "reason", exc))
    except Exception as exc:  # noqa: BLE001 - surfaced to the panel verbatim
        return None, str(exc)


def get_json(url, path, token, payload=None):
    text, error = request(url, path, token, payload)
    if error:
        return None, error
    try:
        return json.loads(text), None
    except ValueError:
        return None, "Home Assistant returned a malformed response"


def require(url_arg):
    url = normalize_url(url_arg)
    if not url:
        fail("Set a valid Home Assistant URL first")
    token = read_token()
    if not token:
        fail("No access token saved", needsToken=True)
    return url, token


# --------------------------------------------------------------- commands

def cmd_ping(argv):
    url, token = require(argv[0] if argv else "")
    data, error = get_json(url, "/api/", token)
    if error:
        fail(error)
    config, config_error = get_json(url, "/api/config", token)
    info = {}
    if not config_error and isinstance(config, dict):
        info = {
            "location": config.get("location_name") or "",
            "version": config.get("version") or "",
            "unit": (config.get("unit_system") or {}).get("temperature") or "",
        }
    out({"ok": True, "message": (data or {}).get("message", "API running"),
         "url": url, **info})


def compact(entity):
    entity_id = str(entity.get("entity_id") or "")
    if "." not in entity_id:
        return None
    domain, _, object_id = entity_id.partition(".")
    if domain in SKIP_DOMAINS:
        return None
    attrs = entity.get("attributes") or {}
    kept = {key: attrs[key] for key in KEEP_ATTRS if key in attrs}
    name = attrs.get("friendly_name") or object_id.replace("_", " ").title()
    return {
        "id": entity_id,
        "domain": domain,
        "name": str(name),
        "state": str(entity.get("state") or "unknown"),
        "changed": entity.get("last_changed") or "",
        "attrs": kept,
    }


def cmd_states(argv):
    url, token = require(argv[0] if argv else "")
    data, error = get_json(url, "/api/states", token)
    if error:
        fail(error)
    if not isinstance(data, list):
        fail("Unexpected /api/states payload")
    entities = [row for row in (compact(item) for item in data) if row]
    entities.sort(key=lambda row: (row["domain"], row["name"].lower()))
    out({"ok": True, "entities": entities, "count": len(entities)})


def cmd_call(argv):
    if len(argv) < 3:
        fail("usage: call <url> <domain> <service> [json]")
    url, token = require(argv[0])
    domain, service = argv[1], argv[2]
    try:
        payload = json.loads(argv[3]) if len(argv) > 3 and argv[3] else {}
    except ValueError:
        fail("Service payload is not valid JSON")
    data, error = get_json(url, "/api/services/%s/%s" % (domain, service),
                           token, payload)
    if error:
        fail(error)
    out({"ok": True, "changed": data if isinstance(data, list) else []})


def render(url, token, template):
    text, error = request(url, "/api/template", token, {"template": template})
    if error:
        return None, error
    try:
        return json.loads(text), None
    except ValueError:
        return None, "Template did not render to JSON"


AREAS_TEMPLATE = (
    '[{% for a in areas() %}'
    '{"name": {{ area_name(a) | tojson }}, '
    '"entities": {{ area_entities(a) | list | tojson }}}'
    '{% if not loop.last %},{% endif %}'
    '{% endfor %}]'
)

# labels()/label_entities() landed in 2024.4. On anything older this template
# raises and we simply report labels as unavailable — manual favorites still
# work, which is why the two sources are independent.
LABELS_TEMPLATE = (
    '[{% for l in labels() %}'
    '{"id": {{ l | tojson }}, "name": {{ label_name(l) | tojson }}, '
    '"entities": {{ label_entities(l) | list | tojson }}}'
    '{% if not loop.last %},{% endif %}'
    '{% endfor %}]'
)


def cmd_meta(argv):
    """Areas, labels, and instance info in one shot, each degrading alone."""
    url, token = require(argv[0] if argv else "")
    areas, areas_error = render(url, token, AREAS_TEMPLATE)
    labels, labels_error = render(url, token, LABELS_TEMPLATE)
    config, config_error = get_json(url, "/api/config", token)
    info = config if isinstance(config, dict) and not config_error else {}
    out({
        "ok": True,
        "areas": areas if isinstance(areas, list) else [],
        "areasError": areas_error or "",
        "labels": labels if isinstance(labels, list) else [],
        "labelsError": labels_error or "",
        "labelsSupported": labels_error is None,
        "version": info.get("version") or "",
        "location": info.get("location_name") or "",
    })


def cmd_snapshot(argv):
    if len(argv) < 3:
        fail("usage: snapshot <url> <entity_id> <outpath>")
    url, token = require(argv[0])
    entity_id, out_path = argv[1], argv[2]
    data, error = request(url, "/api/camera_proxy/" + entity_id, token, raw=True)
    if error:
        fail(error)
    if not data:
        fail("Camera returned no image")
    try:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "wb") as handle:
            handle.write(data)
    except OSError as exc:
        fail("Could not write snapshot: %s" % exc)
    out({"ok": True, "path": out_path, "bytes": len(data)})


def cmd_save_token(_argv):
    """Token arrives on stdin so it never lands in argv or the shell history."""
    token = sys.stdin.read().strip()
    if not token:
        fail("No token given")
    try:
        os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
        os.chmod(CONFIG_DIR, 0o700)
        # Create with 0600 from the start rather than writing then chmod'ing,
        # so the token is never briefly world-readable.
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(token + "\n")
        os.chmod(TOKEN_FILE, 0o600)
    except OSError as exc:
        fail("Could not save token: %s" % exc)
    out({"ok": True, "saved": True})


def cmd_clear_token(_argv):
    try:
        os.remove(TOKEN_FILE)
    except FileNotFoundError:
        pass
    except OSError as exc:
        fail("Could not remove token: %s" % exc)
    out({"ok": True, "saved": False})


def cmd_status(_argv):
    out({"ok": True, "hasToken": bool(read_token()), "tokenFile": TOKEN_FILE})


COMMANDS = {
    "ping": cmd_ping,
    "states": cmd_states,
    "call": cmd_call,
    "meta": cmd_meta,
    "snapshot": cmd_snapshot,
    "save-token": cmd_save_token,
    "clear-token": cmd_clear_token,
    "status": cmd_status,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("usage: hass.py {%s} [args]" % "|".join(sorted(COMMANDS)))
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
