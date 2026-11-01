#!/usr/bin/env python3
"""Catalog of saved commands for the Omarchy bar plugin.

One JSON object on stdin, one JSON object on stdout. The catalog lives in
$XDG_DATA_HOME/bszwakop.commands and is the document a future sync API
exchanges. Settings (API address, token, layout) stay on this machine.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1
MAX_COMMANDS = 500
MAX_BYTES = 1024 * 1024
TITLE_MAX = 160
GROUP_MAX = 80
MAX_GROUPS = 40
TAG_MAX = 32
TAGS_MAX = 12
TEXT_MAX = 8000
TOKEN_MAX = 512
PREVIEW_TTL_SECONDS = 15 * 60
PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
COMMAND_KEYS = {"id", "title", "group", "tags", "command", "body", "danger", "pinned", "updatedAt"}
SNAPSHOT_KEYS = {"schema", "commands", "groups", "revision", "libraryId", "libraryName"}


class HelperError(Exception):
    pass


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def data_root() -> Path:
    override = os.environ.get("COMMANDS_DATA_DIR")
    if override:
        path = Path(override)
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
        path = base / "bszwakop.commands"
    if path.is_symlink():
        raise HelperError("Katalog danych jest dowiązaniem")
    return path


def catalog_path() -> Path:
    return data_root() / "catalog.json"


def settings_path() -> Path:
    return data_root() / "settings.json"


def preview_path() -> Path:
    return data_root() / "sync-preview.json"


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise HelperError("Katalog danych jest dowiązaniem")
    os.chmod(path, 0o700)


def write_private(path: Path, data: dict) -> None:
    ensure_dir(path.parent)
    if path.is_symlink():
        raise HelperError("Plik danych jest dowiązaniem")
    blob = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
    if len(blob) > MAX_BYTES:
        raise HelperError("Katalog przekracza 1 MiB")
    tmp = path.with_name(path.name + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    descriptor = os.open(tmp, flags, 0o600)
    try:
        os.write(descriptor, blob)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path: Path, fallback: dict) -> dict:
    if not path.exists():
        return fallback
    if path.is_symlink() or not path.is_file():
        raise HelperError("Plik danych jest niedostępny")
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        raise HelperError("Plik danych przekracza 1 MiB")
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise HelperError("Plik danych jest uszkodzony") from exc
    if not isinstance(parsed, dict):
        raise HelperError("Plik danych jest uszkodzony")
    return parsed


def canonical(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def revision_of(catalog: dict) -> str:
    return hashlib.sha256(canonical(catalog).encode("utf-8")).hexdigest()


def empty_catalog() -> dict:
    return {"schema": SCHEMA, "groups": [], "commands": []}


def clean_group(value: str) -> str:
    if not isinstance(value, str):
        raise HelperError("Nazwa folderu jest nieprawidłowa")
    name = " ".join(value.split())
    if not name:
        raise HelperError("Podaj nazwę folderu")
    if len(name) > GROUP_MAX:
        raise HelperError("Nazwa folderu jest za długa")
    if name.casefold() == "wszystkie":
        raise HelperError("Ta nazwa jest zajęta")
    return name


def same_group(left: str, right: str) -> bool:
    return left.casefold() == right.casefold()


def find_group(names: list[str], name: str) -> str | None:
    for existing in names:
        if same_group(existing, name):
            return existing
    return None


def normalize_groups(raw, commands: list[dict]) -> list[str]:
    if raw is None:
        raw = []
    if not isinstance(raw, list):
        raise HelperError("Lista folderów jest uszkodzona")
    names = []
    for item in raw:
        if isinstance(item, str):
            name = clean_group(item)
        elif isinstance(item, dict) and set(item) <= {"name"} and isinstance(item.get("name"), str):
            name = clean_group(item["name"])
        else:
            raise HelperError("Folder jest uszkodzony")
        if find_group(names, name):
            raise HelperError("Foldery się powtarzają")
        names.append(name)
    for command in commands:
        if not find_group(names, command["group"]):
            names.append(command["group"])
    if len(names) > MAX_GROUPS:
        raise HelperError("Za dużo folderów")
    return names


def ensure_group(catalog: dict, name: str) -> None:
    if find_group(catalog["groups"], name):
        return
    if len(catalog["groups"]) >= MAX_GROUPS:
        raise HelperError("Za dużo folderów")
    catalog["groups"].append(name)


def default_settings() -> dict:
    return {"version": 1, "apiBase": "", "token": "", "layout": "auto", "recent": []}


def load_catalog() -> dict:
    raw = read_json(catalog_path(), empty_catalog())
    return snapshot(raw)


def load_settings() -> dict:
    raw = read_json(settings_path(), default_settings())
    settings = default_settings()
    base = raw.get("apiBase", "")
    token = raw.get("token", "")
    layout = raw.get("layout", "auto")
    if not isinstance(base, str) or not isinstance(token, str) or layout not in ("auto", "compact", "wide"):
        raise HelperError("Ustawienia są uszkodzone")
    settings["apiBase"] = validate_base(base) if base else ""
    settings["token"] = token
    settings["layout"] = layout
    settings["recent"] = clean_recent(raw.get("recent", []))
    return settings


def clean_recent(raw) -> list[str]:
    if not isinstance(raw, list):
        return []
    seen = set()
    recent = []
    for item in raw:
        if not isinstance(item, str) or not item or len(item) > 80 or item in seen:
            continue
        seen.add(item)
        recent.append(item)
        if len(recent) >= MAX_COMMANDS:
            break
    return recent


def validate_base(base: str) -> str:
    from urllib.parse import urlparse

    base = base.strip().rstrip("/")
    if base.endswith("/v1/snapshot"):
        base = base[: -len("/v1/snapshot")].rstrip("/")
    if len(base) > 300:
        raise HelperError("Adres API jest za długi")
    parsed = urlparse(base)
    if parsed.scheme not in ("https", "http") or not parsed.netloc:
        raise HelperError("Adres API musi zaczynać się od https:// lub http://")
    if parsed.username or parsed.password:
        raise HelperError("Adres API nie może zawierać loginu ani hasła")
    if parsed.query or parsed.fragment:
        raise HelperError("Adres API nie może zawierać parametrów")
    return base


def placeholders(text: str) -> list[str]:
    found = []
    for name in PLACEHOLDER.findall(text):
        if name not in found:
            found.append(name)
    return found


def fingerprint(command: dict) -> str:
    body = {
        "title": command["title"],
        "group": command["group"],
        "tags": command["tags"],
        "command": command["command"],
        "body": command["body"],
        "danger": command["danger"],
        "pinned": command["pinned"],
    }
    return canonical(body)


def normalize(raw: dict, *, trust_time: bool) -> dict:
    if not isinstance(raw, dict):
        raise HelperError("Komenda musi być obiektem")
    extra = set(raw) - COMMAND_KEYS
    if extra:
        raise HelperError("Nieznane pole komendy")
    title = raw.get("title", "")
    command = raw.get("command", "")
    if not isinstance(title, str) or not isinstance(command, str):
        raise HelperError("Tytuł i komenda muszą być tekstem")
    title = title.strip()
    command = command.strip()
    if not title or not command:
        raise HelperError("Tytuł i komenda są wymagane")
    if len(title) > TITLE_MAX or len(command) > TEXT_MAX:
        raise HelperError("Tytuł lub komenda są za długie")
    group = raw.get("group", "")
    body = raw.get("body", "")
    if not isinstance(group, str) or not isinstance(body, str):
        raise HelperError("Folder i opis muszą być tekstem")
    group = " ".join(group.split()) or "Ogólne"
    body = body.strip()
    if group.casefold() == "wszystkie":
        raise HelperError("Ta nazwa jest zajęta")
    if len(group) > GROUP_MAX or len(body) > TEXT_MAX:
        raise HelperError("Folder lub opis są za długie")
    tags = raw.get("tags", [])
    if not isinstance(tags, list) or len(tags) > TAGS_MAX:
        raise HelperError("Tagi muszą być listą")
    clean_tags = []
    for tag in tags:
        if not isinstance(tag, str):
            raise HelperError("Tag musi być tekstem")
        tag = tag.strip().lower()
        if not tag:
            continue
        if len(tag) > TAG_MAX:
            raise HelperError("Tag jest za długi")
        if tag not in clean_tags:
            clean_tags.append(tag)
    danger = raw.get("danger", False)
    pinned = raw.get("pinned", False)
    if not isinstance(danger, bool) or not isinstance(pinned, bool):
        raise HelperError("Znaczniki komendy są nieprawidłowe")
    ident = raw.get("id", "")
    if ident and (not isinstance(ident, str) or len(ident) > 80):
        raise HelperError("Identyfikator komendy jest nieprawidłowy")
    if trust_time:
        updated = raw.get("updatedAt")
        if not isinstance(updated, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", updated):
            raise HelperError("Czas zmiany komendy jest nieprawidłowy")
    else:
        updated = now()
    return {
        "id": ident,
        "title": title,
        "group": group,
        "tags": clean_tags,
        "command": command,
        "body": body,
        "danger": danger,
        "pinned": pinned,
        "updatedAt": updated,
    }


def snapshot(raw: dict) -> dict:
    if not isinstance(raw, dict):
        raise HelperError("Katalog nie jest obiektem")
    extra = set(raw) - SNAPSHOT_KEYS
    if extra:
        raise HelperError("Nieznane pole katalogu")
    if raw.get("schema", SCHEMA) != SCHEMA:
        raise HelperError("Nieobsługiwana wersja katalogu")
    commands = raw.get("commands", [])
    if not isinstance(commands, list):
        raise HelperError("Lista komend jest uszkodzona")
    if len(commands) > MAX_COMMANDS:
        raise HelperError("Za dużo komend")
    normalized = []
    seen = set()
    for item in commands:
        command = normalize(item, trust_time=True)
        if not command["id"] or command["id"] in seen:
            raise HelperError("Identyfikatory komend są zdublowane albo puste")
        seen.add(command["id"])
        normalized.append(command)
    return {"schema": SCHEMA, "groups": normalize_groups(raw.get("groups"), normalized), "commands": normalized}


def public_command(command: dict) -> dict:
    shown = dict(command)
    shown["placeholders"] = placeholders(command["command"])
    return shown


def sorted_commands(commands: list[dict], recent: list[str] | None = None) -> list[dict]:
    order = {ident: index for index, ident in enumerate(recent or [])}

    def key(item: dict):
        group = item["group"].casefold()
        title = item["title"].casefold()
        if item["pinned"]:
            return (0, 0, group, title)
        used = order.get(item["id"])
        if used is not None:
            return (1, used, "", "")
        return (2, 0, group, title)

    return sorted(commands, key=key)


def public_settings(settings: dict) -> dict:
    return {
        "apiBase": settings["apiBase"],
        "tokenSet": bool(settings["token"]),
        "layout": settings["layout"],
        "syncConfigured": bool(settings["apiBase"]),
    }


def list_state() -> dict:
    catalog = load_catalog()
    settings = load_settings()
    commands = [public_command(item) for item in sorted_commands(catalog["commands"], settings["recent"])]
    return {
        "commands": commands,
        "groups": list(catalog["groups"]),
        "revision": revision_of(catalog),
        "settings": public_settings(settings),
    }


def save_command(raw: dict) -> dict:
    catalog = load_catalog()
    incoming = normalize(raw, trust_time=False)
    ident = incoming["id"]
    if not ident:
        ident = secrets.token_hex(8)
        incoming["id"] = ident
        if any(item["id"] == ident for item in catalog["commands"]):
            raise HelperError("Nie udało się nadać identyfikatora")
        catalog["commands"].append(incoming)
    else:
        existing = next((item for item in catalog["commands"] if item["id"] == ident), None)
        if existing is None:
            raise HelperError("Nie ma takiej komendy")
        if fingerprint(existing) == fingerprint(incoming):
            incoming["updatedAt"] = existing["updatedAt"]
        catalog["commands"] = [incoming if item["id"] == ident else item for item in catalog["commands"]]
    if len(catalog["commands"]) > MAX_COMMANDS:
        raise HelperError("Za dużo komend")
    ensure_group(catalog, incoming["group"])
    write_private(catalog_path(), catalog)
    return list_state()


def save_group(name: str, previous: str = "") -> dict:
    catalog = load_catalog()
    name = clean_group(name)
    if not isinstance(previous, str):
        raise HelperError("Nazwa folderu jest nieprawidłowa")
    previous = previous.strip()
    if previous:
        current = find_group(catalog["groups"], previous)
        if current is None:
            raise HelperError("Nie ma takiego folderu")
        taken = find_group(catalog["groups"], name)
        if taken and not same_group(taken, current):
            raise HelperError("Taki folder już jest")
        catalog["groups"] = [name if same_group(item, current) else item for item in catalog["groups"]]
        if not same_group(name, current):
            for command in catalog["commands"]:
                if same_group(command["group"], current):
                    command["group"] = name
                    command["updatedAt"] = now()
    else:
        if find_group(catalog["groups"], name):
            raise HelperError("Taki folder już jest")
        ensure_group(catalog, name)
    write_private(catalog_path(), catalog)
    return list_state()


def delete_group(name: str) -> dict:
    catalog = load_catalog()
    current = find_group(catalog["groups"], clean_group(name))
    if current is None:
        raise HelperError("Nie ma takiego folderu")
    if any(same_group(item["group"], current) for item in catalog["commands"]):
        raise HelperError("Folder ma komendy. Najpierw je przenieś albo zmień nazwę folderu.")
    catalog["groups"] = [item for item in catalog["groups"] if not same_group(item, current)]
    write_private(catalog_path(), catalog)
    return list_state()


def delete_command(ident: str) -> dict:
    catalog = load_catalog()
    if not any(item["id"] == ident for item in catalog["commands"]):
        raise HelperError("Nie ma takiej komendy")
    catalog["commands"] = [item for item in catalog["commands"] if item["id"] != ident]
    write_private(catalog_path(), catalog)
    forget_use(ident)
    return list_state()


def set_pinned(ident: str, pinned: bool) -> dict:
    if not isinstance(pinned, bool):
        raise HelperError("Przypięcie jest nieprawidłowe")
    catalog = load_catalog()
    found = False
    for item in catalog["commands"]:
        if item["id"] != ident:
            continue
        found = True
        if item["pinned"] != pinned:
            item["pinned"] = pinned
            item["updatedAt"] = now()
    if not found:
        raise HelperError("Nie ma takiej komendy")
    write_private(catalog_path(), catalog)
    return list_state()


def save_settings(payload: dict) -> dict:
    current = load_settings()
    if "apiBase" in payload:
        base = payload["apiBase"]
        if not isinstance(base, str):
            raise HelperError("Adres API jest nieprawidłowy")
        current["apiBase"] = validate_base(base) if base.strip() else ""
    if "layout" in payload:
        layout = payload["layout"]
        if layout not in ("auto", "compact", "wide"):
            raise HelperError("Układ panelu jest nieprawidłowy")
        current["layout"] = layout
    if payload.get("clearToken") is True:
        current["token"] = ""
    elif "token" in payload and payload["token"] != "":
        token = payload["token"]
        if not isinstance(token, str) or len(token) > TOKEN_MAX:
            raise HelperError("Token jest nieprawidłowy")
        current["token"] = token
    write_private(settings_path(), current)
    return list_state()


def find_command(ident: str) -> dict:
    for item in load_catalog()["commands"]:
        if item["id"] == ident:
            return item
    raise HelperError("Nie ma takiej komendy")


def fill(text: str, values: dict) -> str:
    if not isinstance(values, dict):
        raise HelperError("Wartości pól są nieprawidłowe")
    names = placeholders(text)
    missing = []
    clean = {}
    for name in names:
        value = values.get(name, "")
        if not isinstance(value, str) or not value.strip():
            missing.append(name)
        else:
            clean[name] = value.strip()
    if missing:
        raise HelperError("Uzupełnij: " + ", ".join(missing))

    def replace(match: re.Match) -> str:
        return clean[match.group(1)]

    return PLACEHOLDER.sub(replace, text)


def deliver(payload: dict) -> dict:
    command = find_command(str(payload.get("id", "")))
    mode = payload.get("mode")
    if mode not in ("copy", "paste"):
        raise HelperError("Zły tryb skopiowania")
    if command["danger"] and payload.get("confirmDanger") is not True:
        raise HelperError("Komenda wymaga potwierdzenia")
    rendered = fill(command["command"], payload.get("values") or {})
    if os.environ.get("COMMANDS_DRY_RUN") != "1":
        args = ["omarchy-clipboard-paste-text", "--copy-only" if mode == "copy" else "--shift-insert", rendered]
        completed = subprocess.run(args, check=False)
        if completed.returncode != 0:
            raise HelperError("Nie udało się wpisać komendy do schowka")
        label = "Skopiowano" if mode == "copy" else "Wklejono"
        subprocess.run(["omarchy-notification-send", "-g", "󰅍", label, command["title"]], check=False)
    remember_use(command["id"])
    state = list_state()
    state["message"] = command["title"]
    state["delivered"] = mode
    state["text"] = rendered
    return state


def remember_use(ident: str) -> None:
    settings = load_settings()
    settings["recent"] = [ident] + [item for item in settings["recent"] if item != ident]
    settings["recent"] = settings["recent"][:MAX_COMMANDS]
    write_private(settings_path(), settings)


def forget_use(ident: str) -> None:
    settings = load_settings()
    recent = [item for item in settings["recent"] if item != ident]
    if recent == settings["recent"]:
        return
    settings["recent"] = recent
    write_private(settings_path(), settings)


def diff_rows(local: dict, remote: dict) -> list[dict]:
    local_map = {item["id"]: item for item in local["commands"]}
    rows = []
    for src in remote["commands"]:
        current = local_map.get(src["id"])
        if current is None:
            action = "added"
        elif fingerprint(current) == fingerprint(src):
            continue
        elif src["updatedAt"] > current["updatedAt"]:
            action = "updated"
        else:
            action = "conflict"
        rows.append({"action": action, "id": src["id"], "title": src["title"], "group": src["group"]})
    for name in remote.get("groups", []):
        if not find_group(local.get("groups", []), name):
            rows.append({"action": "added", "id": "group:" + name, "title": name, "group": "Folder"})
    return rows


def summarize(rows: list[dict]) -> dict:
    summary = {"added": 0, "updated": 0, "conflict": 0}
    for row in rows:
        summary[row["action"]] += 1
    return summary


def sync_catalog(fetch=None, opener=urllib.request.urlopen) -> dict:
    if fetch is None:
        fetch = fetch_snapshot
    settings = load_settings()
    if not settings["apiBase"]:
        raise HelperError("Synchronizacja nieskonfigurowana")
    if not settings["token"]:
        raise HelperError("Brak klucza biblioteki")
    remote = snapshot(fetch(settings))
    local = load_catalog()
    rows = diff_rows(local, remote)
    merged = merge(local, remote, "keep")
    local_rev = revision_of(local)
    merged_rev = revision_of(merged)
    if merged_rev != local_rev:
        write_private(catalog_path(), merged)
    if merged_rev != revision_of(remote):
        push_snapshot(settings, opener)
    state = list_state()
    state["summary"] = summarize(rows)
    state["changed"] = merged_rev != local_rev or merged_rev != revision_of(remote)
    return state


def push_snapshot(settings: dict, opener=urllib.request.urlopen) -> dict:
    if not settings["apiBase"]:
        raise HelperError("Synchronizacja nieskonfigurowana")
    catalog = load_catalog()
    body = json.dumps(catalog, ensure_ascii=False).encode("utf-8")
    headers = {"Content-Type": "application/json", "If-Match": revision_of(catalog)}
    if settings["token"]:
        headers["Authorization"] = "Bearer " + settings["token"]
    request = urllib.request.Request(
        settings["apiBase"] + "/v1/snapshot",
        data=body,
        headers=headers,
        method="PUT",
    )
    try:
        with opener(request, timeout=8) as response:
            response.read(64)
    except urllib.error.HTTPError as exc:
        code = exc.code
        exc.close()
        if code == 409:
            raise HelperError("Katalog na serwerze jest nowszy. Najpierw pobierz.") from exc
        raise HelperError(f"Serwer synchronizacji odpowiedział {code}") from exc
    except urllib.error.URLError as exc:
        raise HelperError("Nie udało się połączyć z API") from exc
    return {"revision": revision_of(catalog)}


def fetch_snapshot(settings: dict) -> dict:
    url = settings["apiBase"] + "/v1/snapshot"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    if settings["token"]:
        request.add_header("Authorization", "Bearer " + settings["token"])
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            raw = response.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise HelperError(f"Serwer synchronizacji odpowiedział {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise HelperError("Nie udało się połączyć z API") from exc
    if len(raw) > MAX_BYTES:
        raise HelperError("Zdjęcie z serwera przekracza 1 MiB")
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise HelperError("Odpowiedź API nie jest JSON-em") from exc
    return snapshot(parsed)


def preview_sync(fetch=fetch_snapshot) -> dict:
    settings = load_settings()
    if not settings["apiBase"]:
        raise HelperError("Synchronizacja nieskonfigurowana")
    remote = snapshot(fetch(settings))
    rows = diff_rows(load_catalog(), remote)
    token = secrets.token_hex(16)
    write_private(preview_path(), {
        "token": token,
        "apiBase": settings["apiBase"],
        "created": now(),
        "remote": remote,
    })
    return {"token": token, "rows": rows, "summary": summarize(rows)}


def preview_age(created: str) -> float:
    stamp = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - stamp).total_seconds()


def merge(local: dict, remote: dict, policy: str) -> dict:
    if policy not in ("keep", "replace"):
        raise HelperError("Tryb scalania jest nieprawidłowy")
    local_map = {item["id"]: item for item in local["commands"]}
    order = [item["id"] for item in local["commands"]]
    for src in remote["commands"]:
        current = local_map.get(src["id"])
        if current is None:
            local_map[src["id"]] = src
            order.append(src["id"])
            continue
        if fingerprint(current) == fingerprint(src):
            continue
        if src["updatedAt"] > current["updatedAt"] or policy == "replace":
            local_map[src["id"]] = src
    commands = [local_map[ident] for ident in order]
    groups = list(local.get("groups", []))
    for name in remote.get("groups", []):
        if not find_group(groups, name):
            groups.append(name)
    for command in commands:
        if not find_group(groups, command["group"]):
            groups.append(command["group"])
    return {"schema": SCHEMA, "groups": groups, "commands": commands}


def apply_sync(token: str, policy: str) -> dict:
    if not isinstance(token, str) or not token:
        raise HelperError("Brak podglądu synchronizacji")
    settings = load_settings()
    raw = read_json(preview_path(), {})
    if raw.get("token") != token or raw.get("apiBase") != settings["apiBase"]:
        raise HelperError("Podgląd synchronizacji wygasł")
    created = raw.get("created")
    if not isinstance(created, str) or preview_age(created) > PREVIEW_TTL_SECONDS:
        raise HelperError("Podgląd synchronizacji wygasł")
    remote = snapshot(raw.get("remote"))
    local = load_catalog()
    rows = diff_rows(local, remote)
    write_private(catalog_path(), merge(local, remote, policy))
    preview = preview_path()
    if preview.exists() and not preview.is_symlink():
        preview.unlink()
    state = list_state()
    state["summary"] = summarize(rows)
    return state


_FOLDS = str.maketrans("ąćęłńóśźż", "acelnoszz")
_ALIASES = {
    "fortigate": "fortinet",
    "fortios": "fortinet",
    "firewall": "fortinet",
    "linuxa": "linux",
    "address": "adres",
    "addr": "adres",
    "odpowiada": "ping",
    "odpowiedz": "ping",
    "odpowiedziec": "ping",
}
_STOP = frozenset({
    "na", "do", "w", "we", "i", "z", "ze", "sie", "jak", "co", "czy", "po", "od",
    "dla", "ten", "tej", "tym", "nie", "ma", "jest", "to", "ta", "tu", "albo", "oraz",
    "sprawdzic", "sprawdz", "zobacz", "zobaczyc", "prosze", "chce",
})
_SUFFIXES = ("ach", "ami", "ow", "em", "ie", "y", "u", "a", "e", "i")
_ASK_FIELDS = (("title", 1.0), ("group", 0.85), ("command", 0.6), ("body", 0.35), ("tags", 0.4))
_INTENT = frozenset({"ping"})


def _fold(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.casefold().translate(_FOLDS)).strip()


def _stem(word: str) -> str:
    mapped = _alias(word)
    if mapped:
        return mapped
    word = re.sub(r"(.)\1+", r"\1", word)
    for suffix in _SUFFIXES:
        if word.endswith(suffix) and len(word) - len(suffix) >= 4:
            word = word[: -len(suffix)]
            break
    return _ALIASES.get(word, word)


def _forms(word: str) -> list[str]:
    found = []
    chars = list(word)
    variants = [word]
    for index in range(len(chars) - 1):
        chars[index], chars[index + 1] = chars[index + 1], chars[index]
        variants.append("".join(chars))
        chars[index], chars[index + 1] = chars[index + 1], chars[index]
    for variant in variants:
        stemmed = _stem(variant)
        if len(stemmed) >= 3 and stemmed not in _STOP and stemmed not in found:
            found.append(stemmed)
    return found


def _doc_words(text: str) -> list[str]:
    words = []
    for word in _fold(text).split():
        word = _ALIASES.get(word, word)
        if len(word) < 3 or word in _STOP:
            continue
        stemmed = _stem(word)
        if len(stemmed) >= 3 and stemmed not in _STOP and stemmed not in words:
            words.append(stemmed)
    return words


def _damerau(left: str, right: str) -> int:
    if left == right:
        return 0
    width = len(right)
    height = len(left)
    if width == 0 or height == 0:
        return max(width, height)
    rows = [[0] * (width + 1) for _ in range(height + 1)]
    for index in range(height + 1):
        rows[index][0] = index
    for index in range(width + 1):
        rows[0][index] = index
    for i in range(1, height + 1):
        for j in range(1, width + 1):
            cost = 0 if left[i - 1] == right[j - 1] else 1
            rows[i][j] = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and left[i - 1] == right[j - 2] and left[i - 2] == right[j - 1]:
                rows[i][j] = min(rows[i][j], rows[i - 2][j - 2] + 1)
    return rows[height][width]


def _alias(word: str) -> str | None:
    mapped = _ALIASES.get(word)
    if mapped:
        return mapped
    if len(word) < 6:
        return None
    found = []
    for key, value in _ALIASES.items():
        if abs(len(key) - len(word)) > 1:
            continue
        if _damerau(word, key) == 1 and value not in found:
            found.append(value)
    if len(found) == 1:
        return found[0]
    return None


def _similar(left: str, right: str) -> float:
    if left == right:
        return 1.0
    if min(len(left), len(right)) <= 3:
        return 0.0
    if max(len(left), len(right)) > min(len(left), len(right)) * 2:
        return 0.0
    return 1 - _damerau(left, right) / max(len(left), len(right))


def _close(word: str, doc: str) -> float:
    best = 0.0
    primary = _stem(word)
    for form in _forms(word):
        score = _similar(form, doc)
        if form != primary:
            score = min(score, 0.92)
        if score > best:
            best = score
    return best


def rank_question(catalog: dict, question: str) -> list[tuple[float, dict]]:
    query = []
    for word in _fold(question).split():
        word = _ALIASES.get(word, word)
        if len(word) >= 3 and word not in _STOP:
            query.append(word)
    if not query:
        return []
    scored = []
    for command in catalog["commands"]:
        fields = {
            "title": _doc_words(command["title"]),
            "group": _doc_words(command["group"]),
            "command": _doc_words(command["command"]),
            "body": _doc_words(command["body"]),
            "tags": _doc_words(" ".join(command["tags"])),
        }
        total = 0.0
        hits = 0
        peak = 0.0
        for word in query:
            best = 0.0
            for name, weight in _ASK_FIELDS:
                for doc in fields[name]:
                    sim = _close(word, doc)
                    if sim < 0.72:
                        continue
                    best = max(best, sim * weight)
            peak = max(peak, best)
            if best >= 0.4:
                total += best
                hits += 1
        if hits:
            scored.append((total / len(query), peak, command))
    intents = set()
    for word in query:
        stemmed = _stem(word)
        if stemmed in _INTENT:
            intents.add(stemmed)
    if intents:
        focused = [row for row in scored if intents & set(_doc_words(row[2]["title"]))]
        if focused:
            scored = focused
    scored.sort(key=lambda item: item[0], reverse=True)
    return scored


def match_question(catalog: dict, question: str) -> str | None:
    scored = rank_question(catalog, question)
    if not scored or scored[0][0] < 0.45:
        return None
    if len(scored) > 1 and scored[0][0] < scored[1][0] + 0.08:
        return None
    return scored[0][2]["id"]


def tied_questions(catalog: dict, question: str) -> list[dict]:
    scored = rank_question(catalog, question)
    if not scored:
        return []
    best, best_peak = scored[0][0], scored[0][1]
    if best >= 0.45 and (len(scored) == 1 or best >= scored[1][0] + 0.08):
        return []
    chosen = []
    for score, peak, command in scored:
        if best >= 0.45 and best - score <= 0.08:
            chosen.append(command)
        elif best < 0.45 and peak >= 0.85 and best_peak - peak <= 0.04:
            chosen.append(command)
    return chosen[:6]


def parse_match(text: str, valid: set[str]) -> str | None:
    for chunk in reversed(re.findall(r"\{[^{}]*\}", text)):
        try:
            obj = json.loads(chunk)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict) or "id" not in obj:
            continue
        ident = obj["id"]
        if ident is None or ident == "":
            return None
        if isinstance(ident, str) and ident in valid:
            return ident
        return None
    return None


def cards(catalog: dict) -> list[dict]:
    listed = []
    for command in catalog["commands"]:
        listed.append({
            "id": command["id"],
            "title": command["title"],
            "group": command["group"],
            "tags": command["tags"],
            "command": command["command"][:300],
            "body": command["body"][:180],
        })
    return listed


def run_opencode(prompt: str) -> str:
    binary = os.environ.get("COMMANDS_OPENCODE", "opencode")
    if shutil.which(binary) is None and not Path(binary).exists():
        raise HelperError("OpenCode nie jest zainstalowane")
    config = {
        "$schema": "https://opencode.ai/config.json",
        "agent": {
            "librarian": {
                "mode": "primary",
                "prompt": (
                    "Wybierasz jedną pozycję z katalogu podanego w wiadomości. "
                    "Odpowiadasz wyłącznie JSON {\"id\": \"<id>\"} albo {\"id\": null}. "
                    "Id musi pochodzić z katalogu. Nie wymyślasz komend i nie używasz narzędzi."
                ),
                "tools": {
                    "write": False,
                    "edit": False,
                    "bash": False,
                    "read": False,
                    "grep": False,
                    "glob": False,
                    "webfetch": False,
                    "skill": False,
                },
            }
        },
    }
    with tempfile.TemporaryDirectory(prefix="commands-ask-") as work:
        (Path(work) / "opencode.json").write_text(json.dumps(config), encoding="utf-8")
        try:
            completed = subprocess.run(
                [binary, "run", "--standalone", "--agent", "librarian", "--title", "Komendy", prompt],
                cwd=work,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise HelperError("OpenCode nie odpowiedziało w czasie") from exc
    if completed.returncode != 0 and not completed.stdout.strip():
        detail = (completed.stderr or "").strip().splitlines()
        tail = detail[-1][:180] if detail else "brak odpowiedzi"
        raise HelperError("OpenCode: " + tail)
    return completed.stdout


def ask(question: str, runner=run_opencode) -> dict:
    if not isinstance(question, str) or not question.strip():
        raise HelperError("Puste pytanie")
    question = question.strip()
    if len(question) > 500:
        raise HelperError("Pytanie jest za długie")
    catalog = load_catalog()
    valid = {item["id"] for item in catalog["commands"]}
    ident = match_question(catalog, question)
    candidates = []
    if ident is None:
        tied = tied_questions(catalog, question)
        if tied:
            candidates = [{"id": command["id"], "title": command["title"]} for command in tied]
        else:
            prompt = (
                "Pytanie użytkownika:\n"
                + question
                + "\n\nKatalog:\n"
                + json.dumps(cards(catalog), ensure_ascii=False)
            )
            ident = parse_match(runner(prompt), valid)
    match = None
    if ident:
        command = next(item for item in catalog["commands"] if item["id"] == ident)
        match = {"id": command["id"], "title": command["title"]}
    return {"match": match, "question": question, "candidates": candidates}


def dispatch(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise HelperError("Żądanie musi być obiektem")
    op = payload.get("op")
    if op == "list":
        return list_state()
    if op == "save":
        return save_command(payload.get("command"))
    if op == "delete":
        return delete_command(str(payload.get("id", "")))
    if op == "saveGroup":
        return save_group(str(payload.get("name", "")), str(payload.get("previous", "")))
    if op == "deleteGroup":
        return delete_group(str(payload.get("name", "")))
    if op == "pin":
        return set_pinned(str(payload.get("id", "")), payload.get("pinned"))
    if op == "saveSettings":
        return save_settings(payload)
    if op == "deliver":
        return deliver(payload)
    if op == "previewSync":
        return preview_sync()
    if op == "pushSync":
        return push_snapshot(load_settings())
    if op == "sync":
        return sync_catalog()
    if op == "applySync":
        return apply_sync(str(payload.get("token", "")), str(payload.get("policy", "")))
    if op == "ask":
        return ask(str(payload.get("question", "")))
    raise HelperError("Nieznana operacja")


def main() -> int:
    # One JSON object per line. The panel keeps stdin open, so waiting for EOF
    # would hang the save until the request is killed.
    raw = sys.stdin.readline()
    try:
        payload = json.loads(raw) if raw.strip() else {}
        result = dispatch(payload)
        result["ok"] = True
    except HelperError as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception:
        result = {"ok": False, "error": "Błąd wewnętrzny"}
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
