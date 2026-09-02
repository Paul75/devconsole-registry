#!/usr/bin/env bash
# Détecte les nouvelles versions de PHP, Git et Redis, lance le build (local
# via release-*.sh / build-*.sh, ou GitHub Actions avec --ci), publie la
# release, puis met à jour versions.json (url + sha256 calculés sur
# l'artefact publié).
#
# Prérequis :
#   - gh authentifié avec accès au repo (gh auth login)
#   - build local : outillage de compilation (voir release-php.sh / release-git.sh)
#   - --ci : runner self-hosté en ligne (actions-runner/), sinon le job reste en queue
#
# Usage :
#   scripts/update-builds.sh                # php + git + redis (build local)
#   scripts/update-builds.sh --ci           # build via GitHub Actions
#   scripts/update-builds.sh --tool php     # seulement php
#   scripts/update-builds.sh --tool php,git # php et git uniquement
#   scripts/update-builds.sh --no-build     # release déjà publiée (rebuild
#                                           # manuel) : met juste à jour
#                                           # versions.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
REPO="$(git remote get-url origin)"
REPO="${REPO##*github.com:}"
REPO="${REPO##*github.com/}"
REPO="${REPO%.git}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOOLS="php,git,redis,sqlite"
DO_BUILD=1
CI=0
while [ $# -gt 0 ]; do
    case "$1" in
        --tool)
            TOOLS="${2:?--tool nécessite un argument}"
            shift 2
            ;;
        --no-build)
            DO_BUILD=0
            shift
            ;;
        --ci)
            CI=1
            DO_BUILD=0
            shift
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,2\}//'
            exit 0
            ;;
        *)
            echo "Argument inconnu: $1" >&2
            exit 2
            ;;
    esac
done

# ─── 1. Détection ─────────────────────────────────────────────────────────────
echo "→ Détection des nouvelles versions (${TOOLS})…"
if ! "$PY" scripts/check-versions.py --tool "$TOOLS" --json >"$TMP/updates.json" 2>"$TMP/check.log"; then
    cat "$TMP/check.log" >&2
    exit 1
fi
cat "$TMP/check.log" >&2

"$PY" - "$TMP/updates.json" "$TMP/updates.tsv" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    updates = json.load(f)
with open(sys.argv[2], "w") as f:
    for u in updates:
        if u["mode"] == "build":
            f.write(f"{u['tool']}\t{u['old']}\t{u['new']}\n")
PY

if [ ! -s "$TMP/updates.tsv" ]; then
    echo "✓ Aucun build nécessaire (php, git à jour)."
    exit 0
fi

# ─── helpers CI ───────────────────────────────────────────────────────────────

# Attend que le run dispatché apparaisse dans gh run list (dispatch asynchrone).
wait_for_run() {
    local workflow="$1"
    for _ in $(seq 1 30); do
        local run_id
        run_id="$(gh run list --workflow="$workflow" --repo "$REPO" --limit 1 \
            --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
        if [ -n "$run_id" ] && [ "$run_id" != "null" ]; then
            echo "$run_id"
            return 0
        fi
        sleep 5
    done
    echo "❌ Run $workflow introuvable après dispatch" >&2
    return 1
}

# Dernière release <prefix><x.y.z> du repo (php-8.5.10 → 8.5.10).
newest_release() {
    local prefix="$1"
    REPO="$REPO" PREFIX="$prefix" "$PY" - <<'PY'
import json, os, re, sys, urllib.request
repo = os.environ["REPO"]
prefix = os.environ["PREFIX"]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases?per_page=30",
    headers={"User-Agent": "devconsole-update"},
)
try:
    rels = json.loads(urllib.request.urlopen(req, timeout=60).read())
except Exception as e:
    sys.exit(f"erreur API releases: {e}")
pat = re.compile(rf"^{re.escape(prefix)}(\d+\.\d+\.\d+)$")
def parse(v):
    parts = []
    for chunk in re.split(r"[.+_\-]", v):
        if chunk.isdigit():
            parts.append(int(chunk))
        elif (m := re.match(r"^(\d+)", chunk)):
            parts.append(int(m.group(1)))
        else:
            break
    return tuple(parts) if parts else (0,)
tags = [pat.match(r["tag_name"]) for r in rels]
tags = [m.group(1) for m in tags if m]
if not tags:
    sys.exit(0)
print(max(tags, key=parse))
PY
}

# ─── 2. Build + release ───────────────────────────────────────────────────────
# On charge d'abord le .tsv dans un tableau : la boucle qui suit lit stdin des
# builds (release-*.sh, spc, gh, curl…) → un `while read` direct sur le fichier
# serait avalé par la 1ère commande interne et les lignes suivantes seraient
# perdues (mise à jour d'une seule version au lieu de toutes).
mapfile -t BUILD_LINES <"$TMP/updates.tsv"
for line in "${BUILD_LINES[@]}"; do
    IFS=$'\t' read -r tool old new <<<"$line"
    echo ""
    echo "=== $tool : $old → $new ==="
    rel_tag=""
    case "$tool" in
        php)
            built=""
            # Version déjà publiée (release existante) → skip le build, on se
            # contente de mettre à jour versions.json (sha256 + --add).
            if gh release view "php-$new" --repo "$REPO" >/dev/null 2>&1; then
                echo "→ Release php-$new déjà publiée, build sauté."
                ver="$new"
            elif [ "$CI" = "1" ]; then
                echo "→ Dispatch GitHub Actions build-php.yml (php $new)…"
                gh workflow run build-php.yml -f php_version="$new" --repo "$REPO"
                run_id="$(wait_for_run build-php.yml)"
                echo "→ Run $run_id en cours (attente fin)…"
                timeout "${BUILD_TIMEOUT:-10800}" gh run watch "$run_id" --repo "$REPO" \
                    --exit-status --interval 30
                built="$(newest_release php)"
                ver="${built:-$new}"
            elif [ "$DO_BUILD" = "1" ]; then
                echo "→ Build PHP $new (release-php.sh)…"
                "$ROOT/scripts/release-php.sh" "$new" 2>&1 | tee "$TMP/php-build.log"
                built="$(sed -n 's/.*Version complète : //p' "$TMP/php-build.log" | tail -1)"
                ver="${built:-$new}"
            else
                ver="$new"
            fi
            rel_tag="php-$ver"
            artifact="$ROOT/.build-php/php-$ver-fpm-linux-x86_64.tar.gz"
            linux_url="https://github.com/$REPO/releases/download/$rel_tag/php-$ver-fpm-linux-x86_64.tar.gz"
            ;;
        git)
            ver="$new"
            if gh release view "git-$new" --repo "$REPO" >/dev/null 2>&1; then
                echo "→ Release git-$new déjà publiée, build sauté."
            elif [ "$CI" = "1" ]; then
                echo "→ Dispatch GitHub Actions build-git.yml (git $ver)…"
                gh workflow run build-git.yml -f git_version="$ver" --repo "$REPO"
                run_id="$(wait_for_run build-git.yml)"
                echo "→ Run $run_id en cours (attente fin)…"
                timeout "${BUILD_TIMEOUT:-10800}" gh run watch "$run_id" --repo "$REPO" \
                    --exit-status --interval 30
            elif [ "$DO_BUILD" = "1" ]; then
                echo "→ Build Git $ver (release-git.sh)…"
                "$ROOT/scripts/release-git.sh" "$ver" 2>&1 | tee "$TMP/git-build.log"
            fi
            rel_tag="git-$ver"
            artifact="$ROOT/git-$ver-linux-x86_64.tar.gz"
            linux_url="https://github.com/$REPO/releases/download/$rel_tag/git-$ver-linux-x86_64.tar.gz"
            ;;
        redis)
            ver="$new"
            if gh release view "redis-$new" --repo "$REPO" >/dev/null 2>&1; then
                echo "→ Release redis-$new déjà publiée, build sauté."
            elif [ "$CI" = "1" ]; then
                echo "→ Dispatch GitHub Actions build-redis.yml (redis $ver)…"
                gh workflow run build-redis.yml -f redis_version="$ver" --repo "$REPO"
                run_id="$(wait_for_run build-redis.yml)"
                echo "→ Run $run_id en cours (attente fin)…"
                timeout "${BUILD_TIMEOUT:-10800}" gh run watch "$run_id" --repo "$REPO" \
                    --exit-status --interval 30
            elif [ "$DO_BUILD" = "1" ]; then
                echo "→ Build Redis $ver (release-redis.sh)…"
                "$ROOT/scripts/release-redis.sh" "$ver" 2>&1 | tee "$TMP/redis-build.log"
            fi
            rel_tag="redis-$ver"
            artifact="$ROOT/redis-$ver-linux_x86_64-musl.tar.gz"
            linux_url="https://github.com/$REPO/releases/download/$rel_tag/redis-$ver-linux_x86_64-musl.tar.gz"
            ;;
        sqlite)
            ver="$new"
            if gh release view "sqlite-$new" --repo "$REPO" >/dev/null 2>&1; then
                echo "→ Release sqlite-$new déjà publiée, build sauté."
            elif [ "$CI" = "1" ]; then
                echo "→ Dispatch GitHub Actions build-sqlite.yml (sqlite $ver)…"
                gh workflow run build-sqlite.yml -f sqlite_version="$ver" --repo "$REPO"
                run_id="$(wait_for_run build-sqlite.yml)"
                echo "→ Run $run_id en cours (attente fin)…"
                timeout "${BUILD_TIMEOUT:-10800}" gh run watch "$run_id" --repo "$REPO" \
                    --exit-status --interval 30
            elif [ "$DO_BUILD" = "1" ]; then
                echo "→ Build SQLite $ver (release-sqlite.sh)…"
                "$ROOT/scripts/release-sqlite.sh" "$ver" 2>&1 | tee "$TMP/sqlite-build.log"
            fi
            rel_tag="sqlite-$ver"
            artifact="$ROOT/sqlite-$ver-linux_x86_64-musl.tar.gz"
            linux_url="https://github.com/$REPO/releases/download/$rel_tag/sqlite-$ver-linux_x86_64-musl.tar.gz"
            ;;
        *)
            echo "Outil non géré: $tool" >&2
            continue
            ;;
    esac
    : "${rel_tag:?rel_tag non déterminé}"

    if ! gh release view "$rel_tag" --repo "$REPO" >/dev/null 2>&1; then
        echo "❌ Release $rel_tag introuvable sur $REPO" >&2
        exit 1
    fi

    # sha256 linux : artefact local si présent, sinon téléchargement
    if [ -f "$artifact" ]; then
        echo "→ sha256 linux (artefact local)…"
        linux_sha="$(sha256sum "$artifact" | cut -d' ' -f1)"
    else
        echo "→ sha256 linux (téléchargement)…"
        curl --http1.1 -fsSL -o "$TMP/linux-artifact" "$linux_url"
        linux_sha="$(sha256sum "$TMP/linux-artifact" | cut -d' ' -f1)"
    fi

    # ── Windows (best-effort : URL + sha, sinon vide) ──
    win_url=""
    win_sha=""
    case "$tool" in
        php)
            for vs in 17 16; do
                for base in "https://windows.php.net/downloads/releases" "https://downloads.php.net/~windows/releases"; do
                    u="$base/php-$ver-nts-Win32-vs${vs}-x64.zip"
                    if curl --http1.1 -fsIL "$u" >/dev/null 2>&1; then
                        win_url="$u"
                        break 2
                    fi
                done
                u="https://windows.php.net/downloads/releases/archives/php-$ver-nts-Win32-vs${vs}-x64.zip"
                if curl --http1.1 -fsIL "$u" >/dev/null 2>&1; then
                    win_url="$u"
                    break
                fi
            done
            ;;
        git)
            read -r gitfw_tag gitfw_n < <(VERSION="$ver" "$PY" - <<'PY'
import json, os, re, urllib.request
ver = os.environ["VERSION"]
req = urllib.request.Request(
    "https://api.github.com/repos/git-for-windows/git/tags?per_page=100",
    headers={"User-Agent": "devconsole-update"},
)
tags = json.loads(urllib.request.urlopen(req, timeout=60).read())
pat = re.compile(r"^v" + re.escape(ver) + r"\.windows\.(\d+)$")
best = None
for t in tags:
    m = pat.match(t["name"])
    if m and (best is None or int(m.group(1)) > int(best[1])):
        best = (t["name"], m.group(1))
if best:
    print(f"{best[0]} {best[1]}")
PY
            )
            if [ -n "${gitfw_tag:-}" ]; then
                win_url="https://github.com/git-for-windows/git/releases/download/$gitfw_tag/MinGit-${ver}.${gitfw_n}-64-bit.zip"
            fi
            ;;
        sqlite)
            # Binaire Windows sqlite.org auto-suffisant (pas de glibc) → on le
            # garde tel quel, sur la release officielle.
            prg="$("$PY" -c "import sys; a=sys.argv[1].split('.'); print(f'{a[0]}{int(a[1]):02d}{int(a[2]):02d}00')" "$ver")"
            win_url="https://www.sqlite.org/2026/sqlite-tools-win-x64-${prg}.zip"
            ;;
    esac
    if [ -n "$win_url" ]; then
        echo "→ sha256 windows…"
        win_sha="$(curl --http1.1 -fsSL "$win_url" | sha256sum | cut -d' ' -f1)" || win_sha=""
    fi

    # ─── 3. Mise à jour versions.json ────────────────────────────────────────
    echo "→ Mise à jour versions.json ($tool $ver)…"
    TOOL="$tool" VER="$ver" OLD="$old" LINUX_URL="$linux_url" LINUX_SHA="$linux_sha" \
    WIN_URL="$win_url" WIN_SHA="$win_sha" "$PY" - "$TMP/entry.json" <<'PY'
import json, os, sys
tool, ver, old = os.environ["TOOL"], os.environ["VER"], os.environ["OLD"]
data = json.load(open("versions.json", encoding="utf-8"))
entry = json.loads(json.dumps(data["tools"][tool]["versions"][old]))
entry["url"] = os.environ["LINUX_URL"]
entry["sha256"] = os.environ["LINUX_SHA"] or None
if "url_windows" in entry:
    win_url = os.environ["WIN_URL"]
    entry["url_windows"] = win_url or ""
    entry["sha256_windows"] = os.environ["WIN_SHA"] if win_url else ""
json.dump(entry, open(sys.argv[1], "w"), ensure_ascii=False)
PY
    "$PY" scripts/check-versions.py --add "$tool@$ver" <"$TMP/entry.json"
    echo "✓ $tool $ver ajouté. Vérifier le diff, puis committer et pousser versions.json sur main."
done

# ─── Sync embarquée DevConsole ──────────────────────────────────────────────
# Après une MAJ du registry, synchronise l'embarquée (src-tauri/resources/
# versions.json du repo DevConsole) pour le mode portable hors ligne. Copie
# seule, sans commit : le diff est laissé à la revue de l'utilisateur.
echo "→ Sync du registry embarqué DevConsole…"
scripts/sync-embedded-registry.sh && echo "✓ Embarquée synchronisée" || {
    echo "ℹ️  Sync embarquée ignorée ($(basename "$0") : repo DevConsole introuvable ? DEVCONSOLE_REPO=…)"
    exit 0
}
