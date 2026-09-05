#!/usr/bin/env bash
# Build d'une release Spekter (Linux x86_64) depuis le tag GitLab
# hallyhaa/spekter. Binaire formaté pour le registry :
# `spekter-<version>-linux_x86_64.tar.gz` contenant `spekter` (GUI egui) et
# `spekter-nw` (mode terminal), buildés avec la toolchain Rust (système ou
# DevConsole gérée par VersionManager).
#
# Pourquoi un build maison : spekter ne publie aucun binaire précompilé (seulement
# snap + cargo install). egui/eframe → binaire autonome, pas de dépendances
# GTK/Qt, mais lié dynamiquement à la glibc (fontconfig/freetype : présents sur
# tout système avec une GUI).
#
# Usage : scripts/build-spekter.sh <version>   (ex. 1.3.1)
# Sortie : spekter-<version>-linux_x86_64.tar.gz + son SHA256 (stdout).
set -euo pipefail

SPEKTER_VERSION="${1:?Usage: $0 <spekter_version>}"
TAG="v${SPEKTER_VERSION}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── 1. Cargo : PATH d'abord (min 1.92), sinon toolchain DevConsole ─────────
resolve_cargo() {
    if command -v cargo >/dev/null 2>&1; then
        c="$(command -v cargo)"
        [ "$("$c" --version | grep -oE 'cargo [0-9.]+' | cut -d' ' -f2 | cut -d. -f1-2 | tr -d '.')" -ge 192 ] 2>/dev/null \
            && echo "$c" && return 0
    fi
    # Toolchain Rust gérée par DevConsole (VersionManager) : chemins connus.
    for base in \
        "${DEVCONSOLE_TOOLS_DIR:-}" \
        "$HOME/devconsole/data/tools/rust" \
        "/srv/devconsole/data/tools/rust" \
        "$HOME/devconsole/devconsole_src/src-tauri/toolchains" \
        ; do
        [ -n "$base" ] || continue
        for cand in "$base"/*/bin/cargo "$base"/rust/*/bin/cargo; do
            [ -x "$cand" ] && echo "$cand" && return 0
        done
    done
    return 1
}

CARGO="$(resolve_cargo || true)"
if [ -z "$CARGO" ]; then
    echo "❌ cargo introuvable (≥ 1.92 requis). Installez Rust ou précisez DEVCONSOLE_TOOLS_DIR." >&2
    exit 1
fi
CARGO_DIR="$(cd "$(dirname "$CARGO")/.." && pwd)"
echo "==> cargo : $CARGO_DIR"

BUILD_DIR="$PWD/.spekter-build"
SRC_DIR="$BUILD_DIR/spekter-${SPEKTER_VERSION}"
ARCHIVE="spekter-${SPEKTER_VERSION}-linux_x86_64.tar.gz"

# ─── 2. Sources (tag GitLab) ─────────────────────────────────────────────────
mkdir -p "$BUILD_DIR"
if [ ! -d "$SRC_DIR" ]; then
    echo "==> Téléchargement des sources spekter ${TAG}"
    curl -fsSL -o "$BUILD_DIR/spekter-src.tar.gz" \
        "https://gitlab.com/hallyhaa/spekter/-/archive/${TAG}/spekter-${TAG}.tar.gz"
    tar xzf "$BUILD_DIR/spekter-src.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/spekter-${TAG}" "$SRC_DIR"
fi

# ─── 3. Build release (Cargo.lock du repo, LTO + strip, ~6 min) ──────────────
echo "==> cargo build --release --locked (P1 : ~6 min)"
(
    cd "$SRC_DIR"
    "$CARGO" build --release --locked
) || { echo "❌ Echec du build (verifiez la version de rustc ≥ 1.92)" >&2; exit 1; }

GUI="$SRC_DIR/target/release/spekter"
NW="$SRC_DIR/target/release/spekter-nw"
[ -x "$GUI" ] || { echo "❌ binaire GUI introuvable: $GUI" >&2; exit 1; }
[ -x "$NW" ]  || { echo "❌ binaire spekter-nw introuvable: $NW" >&2; exit 1; }

# ─── 4. Vérifications ────────────────────────────────────────────────────────
"$GUI" --version
file "$GUI" "$NW"
printf '==> Dépendances (attendu : fontconfig/freetype/zlib, PAS GTK/Qt) :\n'
ldd "$GUI" 2>&1 | sed 's/^/    /' || true

# ─── 5. Archivage déterministe ───────────────────────────────────────────────
# Les binaires sont déjà reproductibles bit-à-bit (même cargo + même sources).
# Le SHA final ne doit pas dépendre du mtime des fichiers ni de l'horodatage
# gzip, sinon chaque rebuild CI produit un SHA différent de celui de
# versions.json. SOURCE_DATE_EPOCH = date du tag GitLab (source de vérité),
# override possible via l'environnement.
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

STAGE="$BUILD_DIR/pkg/spekter-${SPEKTER_VERSION}-linux_x86_64"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$GUI" "$NW" "$STAGE/"

# ─── 6. Icônes officielles (issues des sources du tag) ───────────────────────
# Le .desktop/lancement cherche l'icône : (1) thème système, (2) en absolu à
# travers find_icon_abs (share/pixmaps, share/icons/hicolor/…, à côté du
# binaire). Embarquées dans l'archive → install + .desktop immédiats.
ICON_PNG="$SRC_DIR/spekter-gui/assets/icon.png"
ICON_SVG="$SRC_DIR/assets/icon.svg"
for icon in "$ICON_PNG" "$ICON_SVG"; do
    [ -f "$icon" ] || echo "ℹ️  icône absente des sources : $icon" >&2
done

ICON_ASSETS="$STAGE/share/icons/hicolor"
PIXMAPS="$STAGE/share/pixmaps"
mkdir -p "$PIXMAPS"
if [ -f "$ICON_PNG" ]; then
    cp "$ICON_PNG" "$PIXMAPS/spekter.png"
    cp "$ICON_PNG" "$STAGE/spekter.png"
    # Sous-icônes hicolor (512/48) : downscale si ImageMagick dispo, sinon
    # copie brute (le thème accepte un PNG de toute taille).
    mkdir -p "$ICON_ASSETS/512x512/apps" "$ICON_ASSETS/48x48/apps"
    if command -v convert >/dev/null 2>&1; then
        convert "$ICON_PNG" -resize 512x512 "$ICON_ASSETS/512x512/apps/spekter.png"
        convert "$ICON_PNG" -resize 48x48 "$ICON_ASSETS/48x48/apps/spekter.png"
    else
        cp "$ICON_PNG" "$ICON_ASSETS/512x512/apps/spekter.png"
        cp "$ICON_PNG" "$ICON_ASSETS/48x48/apps/spekter.png"
    fi
fi
if [ -f "$ICON_SVG" ]; then
    mkdir -p "$ICON_ASSETS/scalable/apps"
    cp "$ICON_SVG" "$ICON_ASSETS/scalable/apps/spekter.svg"
fi

tar -C "$BUILD_DIR/pkg" \
    --sort=name --mtime=@"$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner \
    -cf "$BUILD_DIR/pkg.tar" \
    "spekter-${SPEKTER_VERSION}-linux_x86_64"
gzip -9n "$BUILD_DIR/pkg.tar"
mv "$BUILD_DIR/pkg.tar.gz" "$ARCHIVE"

echo "==> OK : ${ARCHIVE}"
sha256sum "$ARCHIVE"