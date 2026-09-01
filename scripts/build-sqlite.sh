#!/bin/sh
# Build SQLite CLI statique (musl) pour DevConsole, sans Docker.
#
# Pourquoi : les binaires officiels sqlite.org (sqlite-tools-linux-x64) sont
# liés dynamiquement contre une glibc récente (≥ 2.38). Sur les systèmes plus
# anciens (Ubuntu 22.04 = glibc 2.35) ils ne démarrent pas :
#   « version `GLIBC_2.38' not found (required by …/sqlite3) »
# Un build musl statique (même principe que git/redis) est portable partout.
#
# Le CLI est compilé depuis l'amalgame officiel (sqlite3.c + shell.c), avec
# zlib en statique (support .gz). Aucun paquet système, aucun sudo.
#
# Usage : scripts/build-sqlite.sh <sqlite_version>   (ex. 3.53.4)
set -eu

SQLITE_VERSION="${1:?Usage: $0 <sqlite_version>}"

ZLIB_VERSION="1.3.1"
MUSL_TARGET="x86_64-linux-musl"
TOOLCHAIN_URL="https://musl.cc/${MUSL_TARGET}-cross.tgz"

# « 3.53.4 » → « 3530400 » (format sqlite.org : A B C D → ABBCCDD). L'amalgame
# comme les tools utilisent le même code complet (y compris le « 00 »).
num() {
    echo "$SQLITE_VERSION" | awk -F. '{ printf "%d%02d%02d00", $1, $2, $3 }'
}
PRG=$(num)

BUILD_DIR="$PWD/.sqlite-build"
WORKDIR="$PWD"
PREFIX="$BUILD_DIR/prefix"
export PATH="$BUILD_DIR/toolchain/bin:$PATH"
echo "==> sqlite ${SQLITE_VERSION} — build musl statique"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ─── 1. Toolchain musl (cross) ───────────────────────────────────────────────
if [ ! -x "$BUILD_DIR/toolchain/bin/${MUSL_TARGET}-gcc" ]; then
    echo "==> Téléchargement toolchain musl"
    curl -fsSL -o toolchain.tgz "$TOOLCHAIN_URL"
    tar zxf toolchain.tgz
    mv "${MUSL_TARGET}-cross" toolchain
fi

# ─── 2. zlib (statique) ──────────────────────────────────────────────────────
if [ ! -f "$PREFIX/lib/libz.a" ]; then
    echo "==> zlib ${ZLIB_VERSION}"
    curl -fsSL -o zlib.tar.gz "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"
    tar zxf zlib.tar.gz
    cd "zlib-${ZLIB_VERSION}"
    CC="${MUSL_TARGET}-gcc" AR="${MUSL_TARGET}-ar" RANLIB="${MUSL_TARGET}-ranlib" \
        ./configure --prefix="$PREFIX" --static
    make -j"$(nproc)" && make install
    cd ..
fi

# ─── 3. Amalgame SQLite ──────────────────────────────────────────────────────
if [ ! -f "amalgamation/sqlite3.c" ]; then
    echo "==> amalgame sqlite ${PRG}"
    curl -fsSL -o amalgamation.zip \
        "https://www.sqlite.org/2026/sqlite-amalgamation-${PRG}.zip"
    unzip -q amalgamation.zip
    mv "sqlite-amalgamation-${PRG}" amalgamation
fi

# ─── 4. Compilation du CLI (shell + amalgame) ────────────────────────────────
echo "==> Compilation sqlite3 (statique)"
${MUSL_TARGET}-gcc -static -O2 -DSQLITE_ENABLE_COLUMN_METADATA \
    -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4 \
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE \
    -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_EXPLAIN_COMMENTS \
    -DSQLITE_OMIT_LOAD_EXTENSION \
    -o sqlite3 amalgamation/shell.c amalgamation/sqlite3.c \
    -I"$PREFIX/include" -L"$PREFIX/lib" \
    -lpthread -ldl -lm -lz

# ─── 5. Archive ──────────────────────────────────────────────────────────────
cd "$WORKDIR"
ARCHIVE="sqlite-${SQLITE_VERSION}-linux_x86_64-musl.tar.gz"
tar czf "$ARCHIVE" \
    -C "$BUILD_DIR" \
    sqlite3

echo "==> OK : ${ARCHIVE}"
echo "Version complète : ${SQLITE_VERSION}"
