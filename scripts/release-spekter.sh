#!/usr/bin/env bash
# Publication manuelle d'une release Spekter — alternative au workflow GitHub
# Actions build-spekter.yml (runner self-hosté) quand il est indisponible.
#
# Reproduit build-spekter.yml : build-spekter.sh <version> → archive → release
# `spekter-<version>` sur le repo courant.
#
# Prérequis :
#   - cargo ≥ 1.92 (système ou toolchain DevConsole, cf. build-spekter.sh)
#   - gh authentifié avec accès au repo (gh auth login)
#
# Usage :
#   scripts/release-spekter.sh 1.3.1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?Usage: $0 <spekter_version>}"
REPO="$(git remote get-url origin)"
REPO="${REPO##*github.com:}"
REPO="${REPO##*github.com/}"
REPO="${REPO%.git}"
ARCHIVE="spekter-${VERSION}-linux_x86_64.tar.gz"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh non authentifié — lancez : gh auth login (accès à $REPO)" >&2
    exit 1
fi

echo "→ Build de Spekter $VERSION (egui, toolchain Rust)…"
scripts/build-lock.sh scripts/build-spekter.sh "$VERSION"

if [ ! -f "$ARCHIVE" ]; then
    echo "❌ $ARCHIVE introuvable après le build" >&2
    exit 1
fi
echo "→ Contenu de l'archive :"
tar tzf "$ARCHIVE" | sed 's/^/    /'
sha256sum "$ARCHIVE" | sed 's/^/    /'

echo "→ Vérification du binaire GUI :"
BUILD_DIR=".spekter-build"
GUI="$BUILD_DIR/spekter-${VERSION}/target/release/spekter"
if [ -x "$GUI" ]; then
    "$GUI" --version
    ldd "$GUI" 2>&1 | sed 's/^/    /' || true
fi

# Rebuild de la même version → recréation du tag (suppression préalable).
gh release delete "spekter-$VERSION" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true

gh release create "spekter-$VERSION" "$ARCHIVE" \
    --repo "$REPO" \
    --title "Spekter $VERSION (Linux x86_64)" \
    --notes "Spekter $VERSION — diff visuel fichiers/dossiers (Meld-like), binaire egui/eframe autonome, build depuis le tag GitLab hallyhaa/spekter (MIT).

## Binaries
- \`spekter\` — GUI (comparaison side-by-side/unified, syntax highlighting)
- \`spekter-nw\` — mode terminal"

echo "✅ Release spekter-$VERSION publiée sur $REPO"