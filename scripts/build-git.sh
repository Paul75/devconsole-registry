#!/bin/sh
# Build Git statique (musl) pour DevConsole, sans Docker.
#
# Utilise un cross-compilateur musl autonome (musl.cc) + compilation statique
# des dépendances (zlib, openssl, curl) depuis leurs sources. Aucun paquet
# système, aucun sudo, aucun démon requis.
#
# Usage : scripts/build-git.sh <git_version>
set -eu

GIT_VERSION="${1:?Usage: $0 <git_version>}"

ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.4.1"
CURL_VERSION="8.14.0"

MUSL_TARGET="x86_64-linux-musl"
TOOLCHAIN_URL="https://musl.cc/${MUSL_TARGET}-cross.tgz"

BUILD_DIR="$PWD/.git-build"
WORKDIR="$PWD"
PREFIX="$BUILD_DIR/prefix"
STAGE="$BUILD_DIR/stage"
export PATH="$BUILD_DIR/toolchain/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
echo "==> git ${GIT_VERSION} — build musl statique"
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

# ─── 3. openssl (statique) ───────────────────────────────────────────────────
if [ ! -f "$PREFIX/lib/libssl.a" ]; then
    echo "==> openssl ${OPENSSL_VERSION}"
    curl -fsSL -o openssl.tar.gz "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
    tar zxf openssl.tar.gz
    cd "openssl-${OPENSSL_VERSION}"
    # CC explicite (évite le wrapper `ccache` auto-détecté par openssl) et
    # --libdir=lib (sinon openssl installe dans lib64 sur x86_64).
    CC="${MUSL_TARGET}-gcc" ./Configure "linux-x86_64" no-shared no-tests \
        --prefix="$PREFIX" --libdir=lib
    make -j"$(nproc)" && make install_sw
    cd ..
fi

# ─── 4. curl (statique) ──────────────────────────────────────────────────────
if [ ! -f "$PREFIX/lib/libcurl.a" ]; then
    echo "==> curl ${CURL_VERSION}"
    curl -fsSL -o curl.tar.gz "https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
    tar zxf curl.tar.gz
    cd "curl-${CURL_VERSION}"
    CC="${MUSL_TARGET}-gcc" ./configure --host="${MUSL_TARGET}" \
        --prefix="$PREFIX" --disable-shared --enable-static \
        --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
        --without-libidn2 --without-libpsl --without-brotli --without-zstd \
        --without-nghttp2 --without-libssh2 --without-librtmp \
        --disable-doc --disable-manual \
        CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
    make -j"$(nproc)" && make install
    cd ..
fi

# ─── 5. git (statique) ───────────────────────────────────────────────────────
if [ ! -d "git-${GIT_VERSION}" ]; then
    echo "==> git ${GIT_VERSION}"
    curl -fsSL -o git.tar.gz \
        "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.gz"
    tar zxf git.tar.gz
fi

cd "git-${GIT_VERSION}"
make configure
CC="${MUSL_TARGET}-gcc" ./configure --host="${MUSL_TARGET}" \
    --prefix="/dist/git-${GIT_VERSION}" \
    --with-curl="$PREFIX" \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="-L$PREFIX/lib -static" \
    ac_cv_fread_reads_directories=yes \
    NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 NO_EXPAT=1
make -j"$(nproc)"
rm -rf "$STAGE"
make install DESTDIR="$STAGE"

# ─── 6. Archive ──────────────────────────────────────────────────────────────
cd "$WORKDIR"
tar czf "git-${GIT_VERSION}-linux-x86_64.tar.gz" \
    -C "$STAGE/dist/git-${GIT_VERSION}" \
    bin/git libexec/git-core/ share/git-core/templates/

echo "==> OK : git-${GIT_VERSION}-linux-x86_64.tar.gz"
