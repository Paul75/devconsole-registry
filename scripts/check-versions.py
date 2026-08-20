#!/usr/bin/env python3
"""Detecte les nouvelles versions upstream et met a jour versions.json.

Usage:
  scripts/check-versions.py                  # rapport seul
  scripts/check-versions.py --write          # ecrit versions.json
  scripts/check-versions.py --tool node,bun  # sous-ensemble
  scripts/check-versions.py --write --sha    # + telecharge pour calculer sha256
  scripts/check-versions.py --write --fill-sha  # calcule les sha256 manquants des entrees existantes
  scripts/check-versions.py --add php@8.5.10 # ajoute une version (entry JSON stdin)

Outils GitHub releases: node, bun, caddy, mailpit, composer, zed, vscodium,
tabby, go, postgres, windterm, bruno, cloudflared, gh, jq, lazygit, mkcert,
uv.
Outils APIs dediees: python (python-build-standalone + SHA256SUMS), vscode
(update.code.visualstudio.com), jdk (Adoptium API), rust (channel-rust-stable.toml),
mariadb (downloads.mariadb.org REST), maven (apache/maven tags),
android_studio (page stable developer.android.com/studio),
android_sdk (repository2-3.xml de Google),
redis (redis/redis GitHub releases), mongodb (mongodb/mongo tags).
Outils detect-only (build local/CI requis): php, git — reportent la nouvelle
version sans deriver les URLs; lancer scripts/update-builds.sh pour construire
et publier, puis integrer la release dans versions.json.

Non couverts (pas d'API publique stable): mysql, wezterm, sublime_merge.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
VERSIONS_PATH = ROOT / "versions.json"
USER_AGENT = "devconsole-registry-check-versions/1.0"


# ─── helpers ─────────────────────────────────────────────────────────────────


def github_token() -> str | None:
    if token := os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN"):
        return token
    try:
        out = subprocess.check_output(
            ["gh", "auth", "token"], text=True, stderr=subprocess.DEVNULL
        )
        return out.strip() or None
    except (OSError, subprocess.CalledProcessError):
        pass

    # Fallback: gh < 2.31 n'a pas "auth token" → lire hosts.yml
    try:
        hosts = Path(
            os.environ.get("GH_CONFIG_DIR", Path.home() / ".config" / "gh")
        ) / "hosts.yml"
        if hosts.is_file() and (
            m := re.search(
                r"(?m)^\s*oauth_token:\s*([^\s]+)\s*$",
                hosts.read_text(encoding="utf-8"),
            )
        ):
            return m.group(1)
    except OSError:
        pass
    return None


def http_get(url: str, *, binary: bool = False) -> Any:
    headers = {"User-Agent": USER_AGENT}
    if "api.github.com" in url:
        headers["Accept"] = "application/vnd.github+json"
        if token := github_token():
            headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    return data if binary else data.decode("utf-8")


def http_get_json(url: str) -> Any:
    return json.loads(http_get(url))


def parse_version(v: str) -> tuple[int, ...]:
    """Parse un numero de version en tuple comparable (ignore suffixe non numerique)."""
    parts: list[int] = []
    for chunk in re.split(r"[.+_\-]", v.lstrip("v")):
        if chunk.isdigit():
            parts.append(int(chunk))
        elif m := re.match(r"^(\d+)", chunk):
            parts.append(int(m.group(1)))
        else:
            break
    return tuple(parts) if parts else (0,)


def version_gt(a: str, b: str) -> bool:
    return parse_version(a) > parse_version(b)


def max_version(versions: list[str]) -> str:
    return max(versions, key=parse_version)


def version_group(v: str) -> tuple[int, int]:
    """Extrait le tuple (major, minor) d'une version pour le groupement par ligne."""
    parts = parse_version(v)
    major = parts[0] if len(parts) > 0 else 0
    minor = parts[1] if len(parts) > 1 else 0
    return (major, minor)


def substitute_version(template: str, old: str, new: str) -> str:
    """Remplace toutes les occurrences de old par new dans une URL/chemin."""
    if old not in template:
        raise ValueError(f"version {old!r} introuvable dans le template: {template}")
    return template.replace(old, new)


def sha256_url(url: str) -> str:
    digest = hashlib.sha256()
    headers = {"User-Agent": USER_AGENT}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=300) as resp:
        while chunk := resp.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_from_shasums(text: str, filename: str) -> str | None:
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].lstrip("*") == filename:
            return parts[0]
    return None


@dataclass
class Update:
    tool: str
    old_version: str | None
    new_version: str
    entry: dict[str, Any]
    mode: str  # "add" | "replace"


Checker = Callable[[dict[str, Any], argparse.Namespace], list[Update]]


# ─── checkers ────────────────────────────────────────────────────────────────


def make_entry(
    template: dict[str, Any],
    old_ver: str,
    new_ver: str,
    args: argparse.Namespace,
    tool: str = "",
) -> dict[str, Any]:
    """Derive une entry a partir du template (substitution de version) et gere
    sha256 (calcul si --sha, sinon None)."""
    entry = deepcopy(template)
    for key in ("url", "url_windows"):
        if key in entry and isinstance(entry[key], str):
            entry[key] = substitute_version(entry[key], old_ver, new_ver)
    if args.sha:
        for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
            if entry.get(src):
                print(f"  … {tool}: sha256 {src} …", file=sys.stderr)
                try:
                    entry[dst] = sha256_url(entry[src])
                except urllib.error.HTTPError as e:
                    print(f"  ! {tool}: echec sha {src}: {e}", file=sys.stderr)
                    entry[dst] = None
    else:
        for key in ("sha256", "sha256_windows"):
            if key in entry:
                entry[key] = None
    return entry


def check_github_latest(
    tool: str,
    repo: str,
    current: dict[str, Any],
    args: argparse.Namespace,
    *,
    tag_to_version: Callable[[str], str | None] | None = None,
) -> list[Update]:
    """Compare la release GitHub latest a la version max locale."""
    versions = current.get("versions") or {}
    if not versions:
        return []

    latest = http_get_json(f"https://api.github.com/repos/{repo}/releases/latest")
    tag = latest.get("tag_name") or ""
    if tag_to_version:
        new_ver = tag_to_version(tag)
    else:
        new_ver = tag.lstrip("v") if tag else None
    if not new_ver:
        print(f"  ! {tool}: tag ignore {tag!r}", file=sys.stderr)
        return []

    old_ver = max_version(list(versions))
    if not version_gt(new_ver, old_ver):
        return []

    template = versions[old_ver]
    entry = make_entry(template, old_ver, new_ver, args, tool)

    return [Update(tool, old_ver, new_ver, entry, "add")]


def check_bun(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    def tag_to_version(tag: str) -> str | None:
        # bun-v1.3.14
        m = re.match(r"^bun-v(.+)$", tag)
        return m.group(1) if m else tag.lstrip("v") or None

    return check_github_latest("bun", "oven-sh/bun", current, args, tag_to_version=tag_to_version)


def check_caddy(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("caddy", "caddyserver/caddy", current, args)


def check_mailpit(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("mailpit", "axllent/mailpit", current, args)


def check_composer(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("composer", "composer/composer", current, args)


def check_zed(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("zed", "zed-industries/zed", current, args)


def check_vscodium(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("vscodium", "VSCodium/vscodium", current, args)


def check_tabby(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("tabby", "Eugeny/tabby", current, args)


def check_go(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    versions = current.get("versions") or {}
    if not versions:
        return []

    data = http_get_json("https://go.dev/dl/?mode=json")
    stable = next((r for r in data if r.get("stable")), None)
    if not stable:
        return []

    # version: "go1.26.5"
    new_ver = stable["version"].removeprefix("go")
    old_ver = max_version(list(versions))
    if not version_gt(new_ver, old_ver):
        return []

    template = versions[old_ver]
    entry = deepcopy(template)
    files = {f["filename"]: f for f in stable.get("files", [])}

    linux = files.get(f"go{new_ver}.linux-amd64.tar.gz")
    windows = files.get(f"go{new_ver}.windows-amd64.zip")
    if linux:
        entry["url"] = f"https://go.dev/dl/{linux['filename']}"
        entry["sha256"] = linux.get("sha256")
    else:
        entry["url"] = substitute_version(template["url"], old_ver, new_ver)
        entry["sha256"] = None

    if "url_windows" in template:
        if windows:
            entry["url_windows"] = f"https://go.dev/dl/{windows['filename']}"
            entry["sha256_windows"] = windows.get("sha256")
        else:
            entry["url_windows"] = substitute_version(template["url_windows"], old_ver, new_ver)
            entry["sha256_windows"] = None

    if args.sha:
        for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
            if entry.get(src) and not entry.get(dst):
                print(f"  … go: sha256 {src} …", file=sys.stderr)
                entry[dst] = sha256_url(entry[src])

    return [Update("go", old_ver, new_ver, entry, "add")]


def check_needs_build(
    tool: str,
    repo: str,
    current: dict[str, Any],
    args: argparse.Namespace,
    *,
    tag_regex: str,
    prefix: str,
) -> list[Update]:
    """Detect-only pour les outils dont le binaire est produit par un build
    local/CI (php, git Linux) : signale la nouvelle version upstream sans
    deriver les URLs. Le build est declenche par scripts/update-builds.sh.

    Gere le suivi par ligne majeure (ex: PHP 8.3, 8.4, 8.5) : chaque ligne
    suivie est comparee independamment a l'upstream.
    """
    versions = current.get("versions") or {}
    if not versions:
        return []

    tags = http_get_json(f"https://api.github.com/repos/{repo}/tags?per_page=100")
    stable = [t["name"] for t in tags if re.match(tag_regex, t["name"])]
    if not stable:
        return []

    # Index upstream par groupe (major, minor) → meilleure version du groupe
    upstream_by_group: dict[tuple[int, int], str] = {}
    for tag in stable:
        m = re.match(tag_regex, tag)
        if not m:
            continue
        ver = m.group(1)
        grp = version_group(ver)
        if grp not in upstream_by_group or version_gt(ver, upstream_by_group[grp]):
            upstream_by_group[grp] = ver

    # Index local par groupe → meilleure version du groupe
    current_by_group: dict[tuple[int, int], str] = {}
    for ver in versions:
        grp = version_group(ver)
        if grp not in current_by_group or version_gt(ver, current_by_group[grp]):
            current_by_group[grp] = ver

    updates: list[Update] = []
    for grp, old_ver in sorted(current_by_group.items()):
        new_ver = upstream_by_group.get(grp)
        if not new_ver or not version_gt(new_ver, old_ver):
            continue
        template = versions[old_ver]
        entry = deepcopy(template)
        updates.append(Update(tool, old_ver, new_ver, entry, "build"))

    return updates


def check_php(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    # Tags php-src : php-8.5.9, php-8.6.0alpha3 (exclu par le regex strict),
    # php-8.5.9RC1 (exclu).
    return check_needs_build(
        "php", "php/php-src", current, args,
        tag_regex=r"^php-(\d+\.\d+\.\d+)$",
        prefix="php-",
    )


def check_git(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    # Tags git/git : v2.55.0, v2.55.0-rc2 (exclu par le regex strict).
    return check_needs_build(
        "git", "git/git", current, args,
        tag_regex=r"^v(\d+\.\d+\.\d+)$",
        prefix="v",
    )


def check_node(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    """Met a jour chaque ligne majeure deja presente (24, 22, 20, …)."""
    versions = current.get("versions") or {}
    if not versions:
        return []

    index = http_get_json("https://nodejs.org/dist/index.json")
    majors_present = {parse_version(v)[0] for v in versions}

    best_by_major: dict[int, str] = {}
    for major in majors_present:
        candidates = [
            rel["version"].lstrip("v")
            for rel in index
            if parse_version(rel["version"].lstrip("v"))[0] == major
            and rel.get("lts") not in (False, None)
        ]
        if not candidates:
            candidates = [
                rel["version"].lstrip("v")
                for rel in index
                if parse_version(rel["version"].lstrip("v"))[0] == major
            ]
        if candidates:
            best_by_major[major] = max_version(candidates)

    current_by_major: dict[int, str] = {}
    for ver in versions:
        major = parse_version(ver)[0]
        if major not in current_by_major or version_gt(ver, current_by_major[major]):
            current_by_major[major] = ver

    updates: list[Update] = []
    for major, new_ver in sorted(best_by_major.items(), reverse=True):
        old_ver = current_by_major[major]
        if not version_gt(new_ver, old_ver):
            continue

        template = versions[old_ver]
        entry = deepcopy(template)
        entry["url"] = substitute_version(template["url"], old_ver, new_ver)
        if "url_windows" in template:
            entry["url_windows"] = substitute_version(template["url_windows"], old_ver, new_ver)

        try:
            shasums = http_get(f"https://nodejs.org/dist/v{new_ver}/SHASUMS256.txt")
            linux_name = f"node-v{new_ver}-linux-x64.tar.xz"
            win_name = f"node-v{new_ver}-win-x64.zip"
            entry["sha256"] = sha256_from_shasums(shasums, linux_name)
            if "sha256_windows" in entry:
                entry["sha256_windows"] = sha256_from_shasums(shasums, win_name)
        except urllib.error.HTTPError:
            entry["sha256"] = None
            if "sha256_windows" in entry:
                entry["sha256_windows"] = None
            if args.sha:
                for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
                    if entry.get(src):
                        print(f"  … node: sha256 {src} …", file=sys.stderr)
                        entry[dst] = sha256_url(entry[src])

        updates.append(Update("node", old_ver, new_ver, entry, "replace"))

    return updates


def check_vscode(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    versions = current.get("versions") or {}
    if not versions:
        return []
    releases = http_get_json("https://update.code.visualstudio.com/api/releases/stable")
    if not releases:
        return []
    new_ver = releases[0]
    old_ver = max_version(list(versions))
    if not version_gt(new_ver, old_ver):
        return []
    entry = make_entry(versions[old_ver], old_ver, new_ver, args, "vscode")
    return [Update("vscode", old_ver, new_ver, entry, "add")]


def check_postgres(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("postgres", "theseus-rs/postgresql-binaries", current, args)


def check_windterm(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("windterm", "kingToolbox/WindTerm", current, args)


def check_bruno(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("bruno", "usebruno/bruno", current, args)


def check_cloudflared(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("cloudflared", "cloudflare/cloudflared", current, args)


def check_gh(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("gh", "cli/cli", current, args)


def check_jq(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    def tag_to_version(tag: str) -> str | None:
        m = re.match(r"^jq-(.+)$", tag)
        return m.group(1) if m else tag.lstrip("v") or None

    return check_github_latest("jq", "jqlang/jq", current, args, tag_to_version=tag_to_version)


def check_lazygit(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("lazygit", "jesseduffield/lazygit", current, args)


def check_mkcert(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("mkcert", "FiloSottile/mkcert", current, args)


def check_maven(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    def tag_to_version(tag: str) -> str | None:
        m = re.match(r"^maven-(\d+\.\d+\.\d+)$", tag)
        return m.group(1) if m else None

    return check_github_latest("maven", "apache/maven", current, args, tag_to_version=tag_to_version)


def check_uv(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    return check_github_latest("uv", "astral-sh/uv", current, args)


def check_redis(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    """Detecte les nouvelles versions via l'API GitHub de redis/redis.

    Le registre utilise une URL CDN (fastdl.mongodb.org) pour les binaires
    officiels. Le fork becomeliminal/redis (musl) n'a pas d'API fiable pour
    la detection automatique — il faut le rebuild manuellement apres detection.
    """
    versions = current.get("versions") or {}
    if not versions:
        return []

    data = http_get_json("https://api.github.com/repos/redis/redis/releases?per_page=30")
    stable = [r for r in data if re.match(r"^\d+\.\d+\.\d+$", r.get("tag_name", ""))]
    if not stable:
        return []

    current_by_major: dict[int, str] = {}
    for ver in versions:
        major = parse_version(ver)[0]
        if major not in current_by_major or version_gt(ver, current_by_major[major]):
            current_by_major[major] = ver

    best_by_major: dict[int, str] = {}
    for rel in stable:
        ver = rel["tag_name"]
        major = parse_version(ver)[0]
        if major not in best_by_major or version_gt(ver, best_by_major[major]):
            best_by_major[major] = ver

    updates: list[Update] = []
    for major, new_ver in sorted(best_by_major.items()):
        old_ver = current_by_major.get(major)
        if not old_ver or not version_gt(new_ver, old_ver):
            continue

        entry = deepcopy(versions[old_ver])
        entry["url"] = (
            f"https://github.com/redis/redis/archive/refs/tags/{new_ver}.tar.gz"
        )
        for src, dst in (("url", "sha256"),):
            if args.sha and entry.get(src) and not entry.get(dst):
                print(f"  … redis: sha256 {src} …", file=sys.stderr)
                try:
                    entry[dst] = sha256_url(entry[src])
                except urllib.error.HTTPError as e:
                    print(f"  ! redis: echec sha {src}: {e}", file=sys.stderr)
                    entry[dst] = None
            elif not args.sha:
                entry[dst] = None

        updates.append(Update("redis", old_ver, new_ver, entry, "add"))

    return updates


def check_mongodb(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    """Detecte les nouvelles versions via les tags de mongodb/mongo.

    Les tags suivent le format ``r<version>`` (ex: ``r8.3.8``). Les pre-releases
    (alpha, rc) sont exclues. Les URLs sont derivees du pattern CDN
    ``fastdl.mongodb.org``. Les sha256 ne sont pas fournis par MongoDB :
    utiliser ``--sha`` pour les calculer.
    """
    versions = current.get("versions") or {}
    if not versions:
        return []

    tags = http_get_json("https://api.github.com/repos/mongodb/mongo/tags?per_page=100")
    stable = []
    for t in tags:
        m = re.match(r"^r(\d+\.\d+\.\d+)$", t["name"])
        if m:
            stable.append(m.group(1))
    if not stable:
        return []

    current_by_major: dict[int, str] = {}
    for ver in versions:
        major = parse_version(ver)[0]
        if major not in current_by_major or version_gt(ver, current_by_major[major]):
            current_by_major[major] = ver

    best_by_major: dict[int, str] = {}
    for ver in stable:
        major = parse_version(ver)[0]
        if major not in best_by_major or version_gt(ver, best_by_major[major]):
            best_by_major[major] = ver

    updates: list[Update] = []
    for major, new_ver in sorted(best_by_major.items()):
        old_ver = current_by_major.get(major)
        if not old_ver or not version_gt(new_ver, old_ver):
            continue

        entry = deepcopy(versions[old_ver])
        entry["url"] = (
            f"https://fastdl.mongodb.org/linux/"
            f"mongodb-linux-x86_64-ubuntu2204-{new_ver}.tgz"
        )
        if "url_windows" in entry:
            entry["url_windows"] = (
                f"https://fastdl.mongodb.org/windows/"
                f"mongodb-windows-x86_64-{new_ver}.zip"
            )

        for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
            if entry.get(src):
                if args.sha:
                    print(f"  … mongodb: sha256 {src} …", file=sys.stderr)
                    try:
                        entry[dst] = sha256_url(entry[src])
                    except urllib.error.HTTPError as e:
                        print(f"  ! mongodb: echec sha {src}: {e}", file=sys.stderr)
                        entry[dst] = None
                else:
                    entry[dst] = None

        updates.append(Update("mongodb", old_ver, new_ver, entry, "add"))

    return updates


def check_rust(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    versions = current.get("versions") or {}
    if not versions:
        return []

    text = http_get("https://static.rust-lang.org/dist/channel-rust-stable.toml")
    m = re.search(r'\[pkg\.rust\]\s*version = "([^"]+)"', text)
    if not m:
        return []
    # "1.97.1 (8bab26f4f 2026-07-14)" → "1.97.1"
    new_ver = m.group(1).split()[0]
    old_ver = max_version(list(versions))
    if not version_gt(new_ver, old_ver):
        return []

    entry = deepcopy(versions[old_ver])
    for key, triple, dst in (
        ("url", "x86_64-unknown-linux-gnu", "sha256"),
        ("url_windows", "x86_64-pc-windows-msvc", "sha256_windows"),
    ):
        if key not in entry or not isinstance(entry[key], str):
            continue
        entry[key] = substitute_version(entry[key], old_ver, new_ver)
        hm = re.search(
            r"\[pkg\.rust\.target\." + re.escape(triple) + r"\]\s*(?:[^\[]*?)xz_hash = \"([0-9a-f]+)\"",
            text,
        )
        if hm:
            entry[dst] = hm.group(1)
        elif args.sha:
            entry[dst] = sha256_url(entry[key])
        else:
            entry[dst] = None

    return [Update("rust", old_ver, new_ver, entry, "add")]


def check_jdk(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    versions = current.get("versions") or {}
    if not versions:
        return []

    current_by_feature: dict[int, str] = {}
    for ver in versions:
        feature = parse_version(ver)[0]
        if feature not in current_by_feature or version_gt(ver, current_by_feature[feature]):
            current_by_feature[feature] = ver

    updates: list[Update] = []
    for feature in sorted(current_by_feature):
        try:
            linux = http_get_json(
                f"https://api.adoptium.net/v3/assets/latest/{feature}/hotspot"
                "?architecture=x64&image_type=jdk&os=linux&project=jdk"
            )
            windows = http_get_json(
                f"https://api.adoptium.net/v3/assets/latest/{feature}/hotspot"
                "?architecture=x64&image_type=jdk&os=windows&project=jdk"
            )
        except urllib.error.HTTPError:
            continue
        if not linux or not windows:
            continue

        m = re.match(r"^jdk-(\d+\.\d+\.\d+)\+(\d+)$", linux[0]["release_name"])
        if not m:
            continue
        new_ver = m.group(1)
        old_ver = current_by_feature[feature]
        if not version_gt(new_ver, old_ver):
            continue

        entry = deepcopy(versions[old_ver])
        linux_pkg = linux[0]["binary"]["package"]
        entry["url"] = linux_pkg["link"]
        entry["sha256"] = linux_pkg.get("checksum")
        if "url_windows" in entry:
            windows_pkg = windows[0]["binary"]["package"]
            entry["url_windows"] = windows_pkg["link"]
            entry["sha256_windows"] = windows_pkg.get("checksum")
        updates.append(Update("jdk", old_ver, new_ver, entry, "replace"))

    return updates


def check_python(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    versions = current.get("versions") or {}
    if not versions:
        return []

    release = http_get_json(
        "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
    )
    tag = release.get("tag_name") or ""
    assets = {a["name"] for a in release.get("assets", [])}
    if not tag or not assets:
        return []

    asset_re = re.compile(
        r"^cpython-(\d+\.\d+\.\d+)\+\d{8}-([a-zA-Z0-9_.-]+)-install_only\.tar\.gz$"
    )
    platform_re = re.compile(r"cpython-[\d.]+\+\d{8}-(.+)-install_only\.tar\.gz")

    majors = {version_group(v) for v in versions}
    current_by_major: dict[tuple[int, int], str] = {}
    for ver in versions:
        major = version_group(ver)
        if major not in current_by_major or version_gt(ver, current_by_major[major]):
            current_by_major[major] = ver

    best_by_major: dict[tuple[int, int], str] = {}
    for name in assets:
        m = asset_re.match(name)
        if not m:
            continue
        major = version_group(m.group(1))
        if major not in majors:
            continue
        if major not in best_by_major or version_gt(m.group(1), best_by_major[major]):
            best_by_major[major] = m.group(1)

    if not best_by_major:
        return []

    try:
        shasums = http_get(
            f"https://github.com/astral-sh/python-build-standalone/releases/download/{tag}/SHA256SUMS"
        )
    except urllib.error.HTTPError:
        shasums = None

    updates: list[Update] = []
    for major, new_ver in sorted(best_by_major.items()):
        old_ver = current_by_major[major]
        if not version_gt(new_ver, old_ver):
            continue

        entry = deepcopy(versions[old_ver])
        for key in ("url", "url_windows"):
            if key not in entry or not isinstance(entry[key], str):
                continue
            pm = platform_re.search(entry[key])
            platform = pm.group(1) if pm else None
            asset_name = (
                f"cpython-{new_ver}+{tag}-{platform}-install_only.tar.gz" if platform else None
            )
            if asset_name and asset_name not in assets:
                fallback = (
                    "x86_64-unknown-linux-gnu"
                    if platform and platform.endswith("unknown-linux-gnu")
                    else "x86_64-pc-windows-msvc"
                )
                asset_name = f"cpython-{new_ver}+{tag}-{fallback}-install_only.tar.gz"
            if not asset_name or asset_name not in assets:
                continue
            entry[key] = (
                f"https://github.com/astral-sh/python-build-standalone/releases/download/{tag}/{asset_name}"
            )
            dst = "sha256" if key == "url" else "sha256_windows"
            if shasums:
                entry[dst] = sha256_from_shasums(shasums, asset_name)
            elif args.sha:
                entry[dst] = sha256_url(entry[key])
            else:
                entry[dst] = None

        updates.append(Update("python", old_ver, new_ver, entry, "add"))

    return updates


def check_mariadb(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    versions = current.get("versions") or {}
    if not versions:
        return []

    current_by_major: dict[str, str] = {}
    for ver in versions:
        parts = parse_version(ver)
        major = f"{parts[0]}.{parts[1]}" if len(parts) >= 2 else ver
        if major not in current_by_major or version_gt(ver, current_by_major[major]):
            current_by_major[major] = ver

    updates: list[Update] = []
    for major, old_ver in current_by_major.items():
        try:
            data = http_get_json(f"https://downloads.mariadb.org/rest-api/mariadb/{major}/")
        except urllib.error.HTTPError:
            continue
        releases = data.get("releases") or {}
        candidates = [v for v in releases if re.match(r"^\d+\.\d+\.\d+$", v)]
        if not candidates:
            continue
        new_ver = max_version(candidates)
        if not version_gt(new_ver, old_ver):
            continue

        entry = deepcopy(versions[old_ver])
        entry["url"] = substitute_version(entry["url"], old_ver, new_ver)
        if "url_windows" in entry:
            entry["url_windows"] = substitute_version(entry["url_windows"], old_ver, new_ver)

        linux_sha = next(
            (
                f.get("checksum", {}).get("sha256sum")
                for f in releases[new_ver].get("files", [])
                if f.get("file_name") == f"mariadb-{new_ver}-linux-systemd-x86_64.tar.gz"
            ),
            None,
        )
        entry["sha256"] = linux_sha
        if not linux_sha and args.sha:
            entry["sha256"] = sha256_url(entry["url"])

        if "sha256_windows" in entry:
            entry["sha256_windows"] = sha256_url(entry["url_windows"]) if args.sha else None

        updates.append(Update("mariadb", old_ver, new_ver, entry, "add"))

    return updates


def check_android_studio(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    """Detecte la version stable d'Android Studio.

    La page https://developer.android.com/studio est rendue cote serveur avec
    les liens ide-zips du build stable courant:
      https://edgedl.me.gvt1.com/android/studio/ide-zips/{version}/android-studio-{codename}-linux.tar.gz
    """
    versions = current.get("versions") or {}
    if not versions:
        return []

    html = http_get("https://developer.android.com/studio")
    links = re.findall(
        r"(https://[a-z0-9.-]*gvt1\.com/android/studio/ide-zips/"
        r"(\d+(?:\.\d+)+)/android-studio-[a-z0-9]+-linux\.tar\.gz)",
        html,
    )
    if not links:
        return []

    url = max(links, key=lambda m: parse_version(m[1]))[0]
    m_ver = re.search(r"ide-zips/(\d+(?:\.\d+)+)/", url)
    if not m_ver:
        return []
    new_ver = m_ver.group(1)

    old_ver = max_version(list(versions))
    if not version_gt(new_ver, old_ver):
        return []

    entry = deepcopy(versions[old_ver])
    entry["url"] = url
    if isinstance(entry.get("url_windows"), str):
        entry["url_windows"] = url.replace("-linux.tar.gz", "-windows.zip")

    for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
        if entry.get(src):
            if args.sha:
                print(f"  … android_studio: sha256 {src} …", file=sys.stderr)
                try:
                    entry[dst] = sha256_url(entry[src])
                except urllib.error.HTTPError as e:
                    print(f"  ! android_studio: echec sha {src}: {e}", file=sys.stderr)
                    entry[dst] = None
            else:
                entry[dst] = None

    return [Update("android_studio", old_ver, new_ver, entry, "add")]


def check_android_sdk(current: dict[str, Any], args: argparse.Namespace) -> list[Update]:
    """Detecte le dernier API level Android et les cmdline-tools.

    Le registre versionne android_sdk par API level (35, 36, ...). La source est
    le repository XML de Google (repository2-3.xml): platforms;android-NN pour
    l'API level, et le paquet cmdline-tools;latest pour l'archive sdkmanager.
    """
    versions = current.get("versions") or {}
    if not versions:
        return []

    xml = http_get("https://dl.google.com/android/repository/repository2-3.xml")
    apis = [int(a) for a in re.findall(r'path="platforms;android-(\d+)"', xml)]
    if not apis:
        return []

    new_ver = str(max(apis))
    old_ver = max_version(list(versions))
    if not version_gt(new_ver, old_ver):
        return []

    seg = re.search(
        r'<remotePackage path="cmdline-tools;latest">.*?</remotePackage>', xml, re.S
    )
    linux_tools = win_tools = None
    if seg:
        ml = re.search(
            r"<url>commandlinetools-linux-(\d+)_latest\.zip</url>", seg.group(0)
        )
        mw = re.search(
            r"<url>commandlinetools-win-(\d+)_latest\.zip</url>", seg.group(0)
        )
        linux_tools = ml.group(1) if ml else None
        win_tools = mw.group(1) if mw else None
    if not linux_tools:
        return []

    entry = deepcopy(versions[old_ver])
    entry["url"] = (
        f"https://dl.google.com/android/repository/"
        f"commandlinetools-linux-{linux_tools}_latest.zip"
    )
    if isinstance(entry.get("url_windows"), str) and win_tools:
        entry["url_windows"] = (
            f"https://dl.google.com/android/repository/"
            f"commandlinetools-win-{win_tools}_latest.zip"
        )

    for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
        if entry.get(src):
            if args.sha:
                print(f"  … android_sdk: sha256 {src} …", file=sys.stderr)
                try:
                    entry[dst] = sha256_url(entry[src])
                except urllib.error.HTTPError as e:
                    print(f"  ! android_sdk: echec sha {src}: {e}", file=sys.stderr)
                    entry[dst] = None
            else:
                entry[dst] = None

    return [Update("android_sdk", old_ver, new_ver, entry, "add")]


CHECKERS: dict[str, Checker] = {
    "node": check_node,
    "bun": check_bun,
    "caddy": check_caddy,
    "mailpit": check_mailpit,
    "composer": check_composer,
    "zed": check_zed,
    "vscodium": check_vscodium,
    "tabby": check_tabby,
    "go": check_go,
    "php": check_php,
    "git": check_git,
    "python": check_python,
    "vscode": check_vscode,
    "jdk": check_jdk,
    "rust": check_rust,
    "postgres": check_postgres,
    "mariadb": check_mariadb,
    "windterm": check_windterm,
    "bruno": check_bruno,
    "cloudflared": check_cloudflared,
    "gh": check_gh,
    "jq": check_jq,
    "lazygit": check_lazygit,
    "mkcert": check_mkcert,
    "maven": check_maven,
    "uv": check_uv,
    "redis": check_redis,
    "mongodb": check_mongodb,
    "android_studio": check_android_studio,
    "android_sdk": check_android_sdk,
}


# ─── apply / main ────────────────────────────────────────────────────────────


def fill_missing_shas(data: dict[str, Any], tools: list[str]) -> int:
    """Calcule les sha256 manquants (None/"") des entrees existantes.

    Passe independante des checkers : telecharge chaque URL pour calculer le
    hash des entrees deja presentes dans versions.json dont le sha256 (ou
    sha256_windows) est vide. Retourne le nombre de hashes remplis.
    """
    filled = 0
    for name, tool in (data.get("tools") or {}).items():
        if tools and name not in tools:
            continue
        for ver, entry in (tool.get("versions") or {}).items():
            if not isinstance(entry, dict):
                continue
            for src, dst in (("url", "sha256"), ("url_windows", "sha256_windows")):
                url = entry.get(src)
                if not isinstance(url, str) or not url:
                    continue
                if entry.get(dst):
                    continue
                print(f"  … {name} {ver}: sha256 {src} …", file=sys.stderr)
                try:
                    entry[dst] = sha256_url(url)
                    filled += 1
                except urllib.error.HTTPError as e:
                    print(f"  ! {name} {ver}: echec sha {src}: {e}", file=sys.stderr)
    return filled


def apply_updates(data: dict[str, Any], updates: list[Update]) -> dict[str, Any]:
    out = deepcopy(data)
    tools = out.setdefault("tools", {})

    for upd in updates:
        tool = tools.setdefault(upd.tool, {"versions": {}})
        versions: dict[str, Any] = tool.setdefault("versions", {})

        if upd.mode == "replace" and upd.old_version and upd.old_version in versions:
            # Remplace la cle (nouvelle version) en conservant l'ordre relatif
            new_versions: dict[str, Any] = {}
            for ver, meta in versions.items():
                if ver == upd.old_version:
                    new_versions[upd.new_version] = upd.entry
                else:
                    new_versions[ver] = meta
            tool["versions"] = new_versions
        else:
            # Inserer en tete
            tool["versions"] = {upd.new_version: upd.entry, **versions}

    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write",
        action="store_true",
        help="Ecrit les mises a jour dans versions.json",
    )
    parser.add_argument(
        "--sha",
        action="store_true",
        help="Telecharge les archives pour calculer sha256 (lent)",
    )
    parser.add_argument(
        "--fill-sha",
        action="store_true",
        help="Calcule les sha256 manquants (null/vides) des entrees existantes, "
        "sans verifier les nouveautes. Combiner avec --write pour appliquer.",
    )
    parser.add_argument(
        "--tool",
        help="Outils a traiter (csv). Defaut: tous les checkers, ou tous les "
        "outils du registre avec --fill-sha",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Sortie machine (liste d'updates)",
    )
    parser.add_argument(
        "--add",
        metavar="tool@version",
        help="Ajoute une version dans versions.json (entry JSON sur stdin). "
        "Usage par scripts/update-builds.sh apres publication de la release.",
    )
    args = parser.parse_args()

    if args.add:
        tool, _, version = args.add.partition("@")
        if not tool or not version:
            print("Usage: --add tool@version  (entry JSON sur stdin)", file=sys.stderr)
            return 2
        entry = json.load(sys.stdin)
        data = json.loads(VERSIONS_PATH.read_text(encoding="utf-8"))
        data = apply_updates(data, [Update(tool, None, version, entry, "add")])
        VERSIONS_PATH.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"Ajoute {tool} {version} dans {VERSIONS_PATH}", file=sys.stderr)
        return 0

    tools = [t.strip() for t in args.tool.split(",") if t.strip()] if args.tool else []
    data = json.loads(VERSIONS_PATH.read_text(encoding="utf-8"))

    if args.fill_sha:
        # Sans --tool, couvre tous les outils du registre (pas seulement les
        # checkers : le fill s'applique aussi a mysql, wezterm, ...).
        fill_tools = tools or list(data.get("tools") or {})
        unknown = [t for t in fill_tools if t not in (data.get("tools") or {})]
        if unknown:
            print(f"Outils inconnus: {', '.join(unknown)}", file=sys.stderr)
            print(f"Disponibles: {', '.join(data.get('tools') or {})}", file=sys.stderr)
            return 2
        filled = fill_missing_shas(data, fill_tools)
        if args.write:
            if filled:
                VERSIONS_PATH.write_text(
                    json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8",
                )
                print(
                    f"Ecrit {VERSIONS_PATH} ({filled} sha256 rempli(s))",
                    file=sys.stderr,
                )
            else:
                print("Aucun sha256 manquant.", file=sys.stderr)
        else:
            print(
                f"{filled} sha256 a remplir. Relancer avec --write pour appliquer.",
                file=sys.stderr,
            )
        return 0

    if not tools:
        tools = list(CHECKERS)
    unknown = [t for t in tools if t not in CHECKERS]
    if unknown:
        print(f"Outils inconnus: {', '.join(unknown)}", file=sys.stderr)
        print(f"Disponibles: {', '.join(CHECKERS)}", file=sys.stderr)
        return 2

    all_updates: list[Update] = []

    for name in tools:
        current = (data.get("tools") or {}).get(name) or {}
        print(f"→ {name}", file=sys.stderr)
        try:
            found = CHECKERS[name](current, args)
        except Exception as e:
            print(f"  ! erreur: {e}", file=sys.stderr)
            continue
        if not found:
            cur = list((current.get("versions") or {}))
            label = max_version(cur) if cur else "?"
            print(f"  = a jour ({label})", file=sys.stderr)
        for upd in found:
            print(f"  ↑ {upd.old_version} → {upd.new_version} [{upd.mode}]", file=sys.stderr)
        all_updates.extend(found)

    if args.json:
        print(
            json.dumps(
                [
                    {
                        "tool": u.tool,
                        "old": u.old_version,
                        "new": u.new_version,
                        "mode": u.mode,
                    }
                    for u in all_updates
                ],
                indent=2,
            )
        )

    if not all_updates:
        print("Aucune mise a jour.", file=sys.stderr)
        return 0

    build_updates = [u for u in all_updates if u.mode == "build"]
    write_updates = [u for u in all_updates if u.mode != "build"]
    if build_updates:
        tools_build = ", ".join(sorted({u.tool for u in build_updates}))
        print(
            f"{len(build_updates)} outil(s) a construire ({tools_build}) : "
            "lancer scripts/update-builds.sh",
            file=sys.stderr,
        )

    if args.write:
        if write_updates:
            new_data = apply_updates(data, write_updates)
            VERSIONS_PATH.write_text(
                json.dumps(new_data, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            print(
                f"Ecrit {VERSIONS_PATH} ({len(write_updates)} update(s))",
                file=sys.stderr,
            )
    else:
        print(
            f"{len(write_updates)} update(s) ecrivable(s). Relancer avec --write "
            "pour appliquer.",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrompu.", file=sys.stderr)
        raise SystemExit(130)
