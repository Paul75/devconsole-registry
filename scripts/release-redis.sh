#!/usr/bin/env bash
# Publication manuelle d'une release Redis statique (musl) — alternative au
# workflow GitHub Actions build-redis.yml (runner self-hosté) quand il est
# indisponible.
#
# Reproduit build-redis.yml : build-redis.sh <version> → archive → release
# `redis-<version>` sur le repo courant.
#
# Prérequis :
#   - gh authentifié avec accès au repo (gh auth login)
#
# Usage :
#   scripts/release-redis.sh 7.4.11
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?Usage: $0 <redis_version>}"
REPO="$(git remote get-url origin)"
REPO="${REPO##*github.com:}"
REPO="${REPO##*github.com/}"
REPO="${REPO%.git}"
ARCHIVE="redis-${VERSION}-linux_x86_64-musl.tar.gz"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh non authentifié — lancez : gh auth login (accès à $REPO)" >&2
    exit 1
fi

echo "→ Build de Redis $VERSION (statique, musl)…"
scripts/build-lock.sh scripts/build-redis.sh "$VERSION"

if [ ! -f "$ARCHIVE" ]; then
    echo "❌ $ARCHIVE introuvable après le build" >&2
    exit 1
fi
echo "→ Contenu de l'archive :"
tar tzf "$ARCHIVE" | sed 's/^/    /'

# Rebuild de la même version → recréation du tag (suppression préalable).
gh release delete "redis-$VERSION" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true

gh release create "redis-$VERSION" "$ARCHIVE" \
    --repo "$REPO" \
    --title "Redis $VERSION (static musl)" \
    --notes "Static Redis $VERSION build for DevConsole.

Cross-compilation musl (musl.cc), sans Docker.
Jemalloc inclus, systemd désactivé.

## Binaries
- \`redis-server\`
- \`redis-cli\`"

echo "✅ Release redis-$VERSION publiée sur $REPO"
