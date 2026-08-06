#!/usr/bin/env bash
# Publication manuelle d'une release Git statique — alternative au workflow
# GitHub Actions build-git.yml (runner self-hosté) quand il est indisponible.
#
# Reproduit build-git.yml : build-git.sh <version> → archive → release
# `git-<version>` sur le repo courant.
#
# Prérequis :
#   - gh authentifié avec accès au repo (gh auth login)
#
# Usage :
#   scripts/release-git.sh 2.54.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?Usage: $0 <git_version>}"
REPO="$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+/[^/]+)(\.git)?$#\1#')"
ARCHIVE="git-${VERSION}-linux-x86_64.tar.gz"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh non authentifié — lancez : gh auth login (accès à $REPO)" >&2
    exit 1
fi

echo "→ Build de Git $VERSION (statique, musl)…"
scripts/build-lock.sh scripts/build-git.sh "$VERSION"

if [ ! -f "$ARCHIVE" ]; then
    echo "❌ $ARCHIVE introuvable après le build" >&2
    exit 1
fi
echo "→ Contenu de l'archive :"
tar tzf "$ARCHIVE" | sed 's/^/    /'

# Rebuild de la même version → recréation du tag (suppression préalable).
gh release delete "git-$VERSION" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true

gh release create "git-$VERSION" "$ARCHIVE" \
    --repo "$REPO" \
    --title "Git $VERSION (static)" \
    --notes "Static Git $VERSION build for DevConsole.

Full build with submodule support — unlike \`darkvertex/static-git\`.

## Build config
- Cross-compilation musl (musl.cc), sans Docker
- zlib, openssl, curl compilés en statique depuis leurs sources
- NO_GETTEXT=1, NO_TCLTK=1, NO_PERL=1, NO_PYTHON=1
- Includes \`libexec/git-core/\` with \`git-submodule\`"

echo "✅ Release git-$VERSION publiée sur $REPO"
