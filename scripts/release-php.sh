#!/usr/bin/env bash
# Publication manuelle d'une release PHP statique — alternative au workflow
# GitHub Actions build-php.yml (runner self-hosté) quand il est indisponible.
#
# Reproduit build-php.yml : télécharge spc (static-php-cli) → craft.yml →
# build → archive → release `php-<version>` sur le repo courant.
#
# Tout le build se déroule dans .build-php/ (gitignoré) : spc, sources,
# buildroot, archive — rien ne pollue le repo.
#
# Prérequis :
#   - gh authentifié avec accès au repo (gh auth login)
#   - outillage de compilation (gcc, make, cmake, autoconf, bison, re2c,
#     libxml2-dev, …) + toolchain musl-cross (/usr/local/musl)
#   - GITHUB_TOKEN : récupéré automatiquement depuis gh (gh auth token, ou
#     ~/.config/gh/hosts.yml sur gh < 2.35) pour éviter le rate-limit
#     api.github.com de spc (60 req/h sans token, un seul run/heure)
#
# Usage :
#   scripts/release-php.sh 8.4              # spc 2.8.5 par défaut
#   scripts/release-php.sh 8.4 2.8.5
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PHP_VERSION="${1:?Usage: $0 <php_version> [spc_version]}"
SPC_VERSION="${2:-2.8.5}"
REPO="$(git remote get-url origin)"
REPO="${REPO##*github.com:}"
REPO="${REPO##*github.com/}"
REPO="${REPO%.git}"
BUILD_DIR="$ROOT/.build-php"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh non authentifié — lancez : gh auth login (accès à $REPO)" >&2
    exit 1
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
    if GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && [ -n "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN
        echo "→ GITHUB_TOKEN non défini : récupéré via \`gh auth token\` (API authentifiée, 5000 req/h)."
    elif GITHUB_TOKEN="$(sed -n 's/^[[:space:]]*oauth_token:[[:space:]]*//p' ~/.config/gh/hosts.yml | head -1)" && [ -n "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN
        echo "→ GITHUB_TOKEN non défini : récupéré depuis ~/.config/gh/hosts.yml (gh trop ancien pour \`gh auth token\`)."
    else
        echo "⚠️  GITHUB_TOKEN indisponible : spc résoudra certaines dépendances (libcares, …)"
        echo "    via api.github.com sans authentification → limité à 60 req/h (un seul build/heure)."
        echo "    Exportez un PAT (public repos read) :  export GITHUB_TOKEN=ghp_xxx"
    fi
fi

echo "→ Build dans $BUILD_DIR…"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ── Relocation : l'état de build n'est PAS relocalisable ─────────────────────
# .build-php/ est lié à l'emplacement ABSOLU du dépôt : les .pc de pkg-config
# (buildroot/lib/pkgconfig/*.pc) annoncent un prefix= (→ include/lib) dont PHP
# tire ses -I/-L via pkg-config. Déplacer le dépôt (clé USB → dossier,
# /media → /home, renommage) laisse ce prefix pointer dans le vide ; spc
# ré-utilise alors les bibliothèques déjà construites ("lib [libxml2] already
# built") sans rien recalculer, et le configure échoue sur :
#     fatal error: libxml/tree.h: No such file or directory
# Le message ne parle pas du déplacement — il faut le voir pour le croire.
#
# Les archives statiques (.a) sont insensibles au chemin (aucun rpath vérifié
# dedans) : seul le MÉTADONNÉ pkg-config est périmé. On le répare donc, plutôt
# que de tout reconstruire — un déplacement ne doit pas coûter un rebuild.
sed_escape() {
    printf '%s' "$1" | sed -e 's/[^a-zA-Z0-9_/:=-]/\\&/g'
}

repair_relocated_buildroot() {
    local pc prefix stale fixed=0
    shopt -s nullglob
    for pc in "$BUILD_DIR"/buildroot/lib/pkgconfig/*.pc; do
        prefix="$(sed -n 's/^prefix=//p' "$pc" | head -1)"
        [ -n "$prefix" ] || continue
        [ "$prefix" = "$BUILD_DIR/buildroot" ] && continue
        stale="$prefix"
        # Toutes les occurrences du prefix périmé (prefix, libdir, includedir,
        # Libs.private…) → chemin courant.
        sed -i "s|$(sed_escape "$prefix")|$(sed_escape "$BUILD_DIR/buildroot")|g" "$pc"
        fixed=1
    done
    shopt -u nullglob
    [ "$fixed" = "1" ] || return 1
    echo "→ Buildroot déplacé (prefix périmé : $stale) → métadonnées pkg-config réparées."
    return 0
}

if [ -d "$BUILD_DIR/buildroot/lib/pkgconfig" ]; then
    repair_relocated_buildroot || true
fi

# Garde : le buildroot doit résoudre les en-têtes qu'il annonce. Sans ce
# contrôle, un déplacement non détecté produirait une erreur de compilation
# qui ne parle pas du déplacement — on le dit ici, une fois, avec la cause.
if [ -d "$BUILD_DIR/buildroot" ] && [ ! -f "$BUILD_DIR/buildroot/include/libxml2/libxml/tree.h" ]; then
    echo "❌ Buildroot incohérent : en-têtes libxml2 absents de $BUILD_DIR/buildroot/include" >&2
    echo "   → purger l'état de build (downloads/ conservés) :" >&2
    echo "       rm -rf $BUILD_DIR/buildroot $BUILD_DIR/source $BUILD_DIR/pkgroot" >&2
    exit 1
fi

echo "→ Téléchargement de spc (static-php-cli ${SPC_VERSION})…"
curl -fsSL -o spc.tar.gz "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-linux-x86_64.tar.gz"
tar -xzf spc.tar.gz
chmod +x spc

echo "→ Génération de la config craft (PHP $PHP_VERSION)…"
cat > craft.yml <<CRAFT
php-version: "$PHP_VERSION"
extensions: "bcmath,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,mbstring,mongodb,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,readline,session,simplexml,sockets,sodium,sqlite3,tokenizer,xml,xmlwriter,xmlreader,xsl,zip,zlib"
sapi: [cli, fpm, cgi]
craft-options:
  clean: true
CRAFT

# Sur un runner self-hosté (cas local), la toolchain musl-cross est pré-installée
# dans /usr/local/musl : CC/CXX explicites, sinon certains configure (zlib…)
# prennent le gcc système (glibc) et ld musl échoue (-DNO_STRERROR, …).
export CC=x86_64-linux-musl-gcc
export CXX=x86_64-linux-musl-g++

echo "→ Build PHP (static-php-cli)…"
"$ROOT/scripts/build-lock.sh" ./spc craft craft.yml

FULL_VERSION="$(./buildroot/bin/php -r 'echo PHP_VERSION;')"
echo "→ Version complète : $FULL_VERSION"

# static-php-cli met php-fpm dans bin/, DevConsole l'attend dans sbin/.
mkdir -p buildroot/sbin
cp buildroot/bin/php-fpm buildroot/sbin/php-fpm
ARCHIVE="php-${FULL_VERSION}-fpm-linux-x86_64.tar.gz"
tar czf "$ARCHIVE" -C buildroot bin/php bin/php-cgi sbin/php-fpm

# Rebuild de la même version → recréation du tag (suppression préalable).
gh release delete "php-$FULL_VERSION" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true

gh release create "php-$FULL_VERSION" "$ARCHIVE" \
    --repo "$REPO" \
    --title "PHP $FULL_VERSION (static FPM)" \
    --notes "Static PHP $FULL_VERSION build with FPM support for DevConsole.

## Extensions
bcmath, ctype, curl, dom, exif, fileinfo, filter, gd, iconv, mbstring,
mongodb, mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql,
pdo_sqlite, pgsql, phar, posix, readline, session, simplexml, sockets, sodium,
sqlite3, tokenizer, xml, xmlwriter, xmlreader, xsl, zip, zlib

## SAPIs
- \`bin/php\` (CLI)
- \`sbin/php-fpm\` (FPM)
- \`bin/php-cgi\` (CGI)

## Build config
See [\`craft.yml\`](https://github.com/$REPO/blob/main/craft.yml)"

echo "✅ Release php-$FULL_VERSION publiée sur $REPO"
echo "   Artefact : $BUILD_DIR/$ARCHIVE"
