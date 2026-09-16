#!/usr/bin/env bash
# Build d'une release Spekter (Windows x86_64) depuis le tag GitLab
# hallyhaa/spekter. Formaté pour le registry :
# `spekter-<version>-windows_x86_64.tar.gz` contenant `spekter.exe` (GUI egui)
# et `spekter-nw.exe` (mode terminal), buildés nativement sous Windows (le
# Linux build est cross-compilé musl mais egui/spekter cible les .exe Windows
# via le runner GitHub `windows-latest`).
#
# À lancer sous Git Bash (msys2) — le runner windows-latest en dispose ; la
# toolchain Rust est celle du PATH (rustup stable sur le runner).
#
# Usage : scripts/build-spekter-windows.sh <version>   (ex. 1.3.1)
# Sortie : spekter-<version>-windows_x86_64.tar.gz + son SHA256 (stdout).
set -euo pipefail

SPEKTER_VERSION="${1:?Usage: $0 <spekter_version>}"
TAG="v${SPEKTER_VERSION}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── 1. Cargo : PATH d'abord (min 1.92) ─────────────────────────────────────
resolve_cargo() {
    if command -v cargo >/dev/null 2>&1; then
        c="$(command -v cargo)"
        [ "$("$c" --version | grep -oE 'cargo [0-9.]+' | cut -d' ' -f2 | cut -d. -f1-2 | tr -d '.')" -ge 192 ] 2>/dev/null \
            && echo "$c" && return 0
    fi
    return 1
}

CARGO="$(resolve_cargo || true)"
if [ -z "$CARGO" ]; then
    echo "❌ cargo introuvable (≥ 1.92 requis)." >&2
    exit 1
fi
echo "==> cargo : $CARGO"

BUILD_DIR="$PWD/.spekter-build-windows"
SRC_DIR="$BUILD_DIR/spekter-${SPEKTER_VERSION}"
ARCHIVE="spekter-${SPEKTER_VERSION}-windows_x86_64.tar.gz"

# ─── 2. Sources (tag GitLab) ─────────────────────────────────────────────────
mkdir -p "$BUILD_DIR"
if [ ! -d "$SRC_DIR" ]; then
    echo "==> Téléchargement des sources spekter ${TAG}"
    curl -fsSL -o "$BUILD_DIR/spekter-src.tar.gz" \
        "https://gitlab.com/hallyhaa/spekter/-/archive/${TAG}/spekter-${TAG}.tar.gz"
    tar xzf "$BUILD_DIR/spekter-src.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/spekter-${TAG}" "$SRC_DIR"
fi

# ─── 3. Build release (Cargo.lock du repo, LTO + strip, ~10 min) ─────────────
echo "==> cargo build --release --locked (Windows, ~10 min)"
(
    cd "$SRC_DIR"
    "$CARGO" build --release --locked
) || { echo "❌ Echec du build (verifiez la version de rustc ≥ 1.92)" >&2; exit 1; }

GUI="$SRC_DIR/target/release/spekter.exe"
NW="$SRC_DIR/target/release/spekter-nw.exe"
[ -f "$GUI" ] || { echo "❌ binaire GUI introuvable: $GUI" >&2; exit 1; }
[ -f "$NW" ]  || { echo "❌ binaire spekter-nw introuvable: $NW" >&2; exit 1; }

"$GUI" --version

# ─── 4. Archivage déterministe (SOURCE_DATE_EPOCH = date du tag GitLab) ──────
# Même approche que le build Linux : le SHA final ne doit pas dépendre du
# mtime des fichiers ni de l'horodatage gzip.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    tag_date="$(curl -fsSL \
        "https://gitlab.com/api/v4/projects/hallyhaa%2Fspekter/repository/tags" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next((t['commit']['committed_date'] for t in d if t['name'] == '$TAG'), ''))
" 2>/dev/null || true)"
    SOURCE_DATE_EPOCH="$(date -d "$tag_date" +%s 2>/dev/null || echo 0)"
fi
export SOURCE_DATE_EPOCH

STAGE="$BUILD_DIR/pkg/spekter-${SPEKTER_VERSION}-windows_x86_64"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$GUI" "$NW" "$STAGE/"

# Icônes officielles (mêmes sources que le build Linux) → find_icon_abs.
ICON_PNG="$SRC_DIR/spekter-gui/assets/icon.png"
ICON_SVG="$SRC_DIR/assets/icon.svg"
ICON_ASSETS="$STAGE/share/icons/hicolor"
PIXMAPS="$STAGE/share/pixmaps"
mkdir -p "$PIXMAPS" "$ICON_ASSETS/512x512/apps" "$ICON_ASSETS/48x48/apps"
if [ -f "$ICON_PNG" ]; then
    cp "$ICON_PNG" "$PIXMAPS/spekter.png"
    cp "$ICON_PNG" "$STAGE/spekter.png"
    cp "$ICON_PNG" "$ICON_ASSETS/512x512/apps/spekter.png"
    cp "$ICON_PNG" "$ICON_ASSETS/48x48/apps/spekter.png"
fi
if [ -f "$ICON_SVG" ]; then
    mkdir -p "$ICON_ASSETS/scalable/apps"
    cp "$ICON_SVG" "$ICON_ASSETS/scalable/apps/spekter.svg"
fi

tar -C "$BUILD_DIR/pkg" \
    --sort=name --mtime=@"$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner \
    -czf "$ARCHIVE" \
    "spekter-${SPEKTER_VERSION}-windows_x86_64"

echo "==> OK : ${ARCHIVE}"
sha256sum "$ARCHIVE"