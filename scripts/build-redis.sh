#!/bin/sh
# Build Redis statique (musl) pour DevConsole, sans Docker.
#
# Usage : scripts/build-redis.sh <redis_version>
# Ex.   : scripts/build-redis.sh 7.4.11
set -eu

REDIS_VERSION="${1:?Usage: $0 <redis_version>}"

MUSL_TARGET="x86_64-linux-musl"
TOOLCHAIN_URL="https://musl.cc/${MUSL_TARGET}-cross.tgz"

BUILD_DIR="$PWD/.redis-build"
WORKDIR="$PWD"
export PATH="$BUILD_DIR/toolchain/bin:$PATH"

echo "==> redis ${REDIS_VERSION} — build musl statique"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ─── 1. Toolchain musl (cross) ───────────────────────────────────────────────
if [ ! -x "$BUILD_DIR/toolchain/bin/${MUSL_TARGET}-gcc" ]; then
    echo "==> Téléchargement toolchain musl"
    curl -fsSL -o toolchain.tgz "$TOOLCHAIN_URL"
    tar zxf toolchain.tgz
    mv "${MUSL_TARGET}-cross" toolchain
fi

# ─── 2. Téléchargement source Redis ──────────────────────────────────────────
if [ ! -d "redis-${REDIS_VERSION}" ]; then
    echo "==> Téléchargement redis ${REDIS_VERSION}"
    curl -fsSL -o redis.tar.gz \
        "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz"
    tar xzf redis.tar.gz
fi

# ─── 3. Build ────────────────────────────────────────────────────────────────
# Cibles explicites (redis-server / redis-cli), JAMAIS `make` tout court :
# depuis Redis 8, la cible par défaut (`all` → scripts/build.sh) inclut
# `module_tests`, qui compile des .so de tests. Or LDFLAGS="-static" est
# global : lier un objet partagé en statique échoue (relocation
# R_X86_64_32 contre __TMC_END__, crtbeginT.o) et le build meurt AVANT
# d'écrire un seul binaire. On ne lie donc que les deux exécutables
# effectivement archivés en § 4.
cd "redis-${REDIS_VERSION}"
make -j"$(nproc)" -C src \
    redis-server redis-cli \
    CC="${MUSL_TARGET}-gcc" \
    AR="${MUSL_TARGET}-ar" \
    RANLIB="${MUSL_TARGET}-ranlib" \
    LDFLAGS="-static" \
    BUILD_TLS=no \
    USE_SYSTEMD=no \
    > "$BUILD_DIR/build.log" 2>&1 || {
        echo "❌ Build échoué — voir $BUILD_DIR/build.log" >&2
        exit 1
    }

# ─── 4. Archive ──────────────────────────────────────────────────────────────
cd "$WORKDIR"
ARCHIVE="redis-${REDIS_VERSION}-linux_x86_64-musl.tar.gz"
tar czf "$ARCHIVE" \
    -C "$BUILD_DIR/redis-${REDIS_VERSION}/src" \
    redis-server redis-cli

echo "==> OK : ${ARCHIVE}"
echo "Version complète : ${REDIS_VERSION}"
