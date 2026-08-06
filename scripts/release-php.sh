#!/usr/bin/env bash
# Publication manuelle d'une release PHP statique — alternative au workflow
# GitHub Actions build-php.yml (runner self-hosté) quand il est indisponible.
#
# Reproduit build-php.yml : télécharge spc (static-php-cli) → craft.yml →
# build → archive → release `php-<version>` sur le repo courant.
#
# Prérequis :
#   - gh authentifié avec accès au repo (gh auth login)
#   - outillage de compilation (gcc, make, cmake, autoconf, bison, re2c,
#     libxml2-dev, …) + toolchain musl-cross (/usr/local/musl)
#   - optionnel : GITHUB_TOKEN (PAT) exporté pour éviter le rate-limit
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
REPO="$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+/[^/]+)(\.git)?$#\1#')"
CRAFT_FILE=".craft.local.yml"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh non authentifié — lancez : gh auth login (accès à $REPO)" >&2
    exit 1
fi

echo "→ Téléchargement de spc (static-php-cli ${SPC_VERSION})…"
curl -fsSL -o spc.tar.gz "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-linux-x86_64.tar.gz"
tar -xzf spc.tar.gz
chmod +x spc

echo "→ Génération de la config craft (PHP $PHP_VERSION)…"
cat > "$CRAFT_FILE" <<CRAFT
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
scripts/build-lock.sh ./spc craft "$CRAFT_FILE"

FULL_VERSION="$(./buildroot/bin/php -r 'echo PHP_VERSION;')"
echo "→ Version complète : $FULL_VERSION"

# static-php-cli met php-fpm dans bin/, DevConsole l'attend dans sbin/.
mkdir -p buildroot/sbin
cp buildroot/bin/php-fpm buildroot/sbin/php-fpm
ARCHIVE="php-${FULL_VERSION}-fpm-linux-x86_64.tar.gz"
tar czf "$ARCHIVE" -C buildroot bin/php bin/php-cgi sbin/php-fpm

rm -f "$CRAFT_FILE"

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
