#!/usr/bin/env bash
# Publication manuelle d'une release SQLite statique (musl) — alternative au
# workflow GitHub Actions build-sqlite.yml (runner self-hosté) quand il est
# indisponible.
#
# Reproduit build-sqlite.yml : build-sqlite.sh <version> → archive → release
# `sqlite-<version>` sur le repo courant.
#
# Prérequis :
#   - gh authentifié avec accès au repo (gh auth login)
#
# Usage :
#   scripts/release-sqlite.sh 3.53.4
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?Usage: $0 <sqlite_version>}"
REPO="$(git remote get-url origin)"
REPO="${REPO##*github.com:}"
REPO="${REPO##*github.com/}"
REPO="${REPO%.git}"
ARCHIVE="sqlite-${VERSION}-linux_x86_64-musl.tar.gz"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh non authentifié — lancez : gh auth login (accès à $REPO)" >&2
    exit 1
fi

echo "→ Build de SQLite $VERSION (statique, musl)…"
scripts/build-lock.sh scripts/build-sqlite.sh "$VERSION"

if [ ! -f "$ARCHIVE" ]; then
    echo "❌ $ARCHIVE introuvable après le build" >&2
    exit 1
fi
echo "→ Contenu de l'archive :"
tar tzf "$ARCHIVE" | sed 's/^/    /'

echo "→ Vérification du binaire (statique, exécutable) :"
BUILD_DIR=".sqlite-build"
if [ -x "$BUILD_DIR/sqlite3" ]; then
    file "$BUILD_DIR/sqlite3"
    ldd "$BUILD_DIR/sqlite3" 2>&1 | sed 's/^/    /' || true
    "$BUILD_DIR/sqlite3" --version
fi

# Rebuild de la même version → recréation du tag (suppression préalable).
gh release delete "sqlite-$VERSION" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true

gh release create "sqlite-$VERSION" "$ARCHIVE" \
    --repo "$REPO" \
    --title "SQLite $VERSION (static musl)" \
    --notes "Static SQLite $VERSION build for DevConsole.

Cross-compilation musl (musl.cc), sans Docker.

## Binaries
- \`sqlite3\`"

echo "✅ Release sqlite-$VERSION publiée sur $REPO"
