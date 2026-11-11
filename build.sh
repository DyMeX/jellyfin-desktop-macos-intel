#!/bin/bash
# Builds an unofficial Jellyfin Desktop for Intel Macs (x86_64), macOS 13+.
# All media libraries (ffmpeg, libmpv, libass, libplacebo, ...) are built from source
# with MACOSX_DEPLOYMENT_TARGET=13.0, so nothing from Homebrew ends up in the app.
#
# Usage: ./build.sh            (work dir: ./work, result: ./dist/*.dmg)
#        JELLYFIN_TAG=v2.1.0 ./build.sh
# Needs: Xcode Command Line Tools (clang, swiftc), cmake, ninja, nasm, pkg-config, python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
. "$ROOT/versions.env"

WORK="${WORK:-$ROOT/work}"
SRC="$WORK/src"
PREFIX="$WORK/prefix"
VENV="$WORK/venv"
QTROOT="$WORK/qt/$QT_VERSION/macos"
DIST="$ROOT/dist"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$SRC" "$PREFIX" "$DIST"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "error: run this on an Intel Mac (or a macos-*-intel runner)" >&2
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export PATH="$VENV/bin:$PATH"
# only our own .pc files - never pick up Homebrew libraries
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH
export CFLAGS="-mmacosx-version-min=$MACOS_MIN -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=$MACOS_MIN -Wl,-headerpad_max_install_names"

log() { printf '\n==== %s\n' "$*"; }

fetch() { # fetch <dir> <git url> <tag> [--recurse]; retries, because runners sometimes lose DNS for a moment
  local dir="$SRC/$1" try
  [ -d "$dir" ] && return 0
  for try in 1 2 3 4; do
    if [ "${4:-}" = "--recurse" ]; then
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" --recurse-submodules --shallow-submodules "$2" "$dir" && return 0
    else
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "$2" "$dir" && return 0
    fi
    rm -rf "$dir"
    echo "clone of $2 failed (attempt $try), retrying" >&2
    sleep $((try * 15))
  done
  return 1
}

done_flag() { [ -f "$PREFIX/.done-$1" ]; }
mark_done() { touch "$PREFIX/.done-$1"; }

meson_build() { # meson_build <name> [meson options...]
  local name="$1"; shift
  done_flag "$name" && return 0
  log "$name"
  (cd "$SRC/$name" && rm -rf _build \
    && meson setup _build --prefix="$PREFIX" --libdir=lib --buildtype=release \
         -Ddefault_library=shared -Db_ndebug=true "$@" \
    && ninja -C _build -j "$JOBS" install)
  mark_done "$name"
}

log "python venv (meson, jinja2, aqtinstall)"
if [ ! -x "$VENV/bin/meson" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q meson jinja2 aqtinstall
fi

log "Qt $QT_VERSION"
if [ ! -d "$QTROOT" ]; then
  aqt install-qt mac desktop "$QT_VERSION" -m qtwebengine qtwebchannel qtpositioning -O "$WORK/qt"
fi

# --- text rendering --------------------------------------------------------
fetch freetype https://github.com/freetype/freetype.git "$FREETYPE_TAG"
meson_build freetype -Dharfbuzz=disabled -Dpng=disabled -Dbzip2=disabled -Dbrotli=disabled -Dzlib=internal -Dtests=disabled

fetch fribidi https://github.com/fribidi/fribidi.git "$FRIBIDI_TAG"
meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false

fetch harfbuzz https://github.com/harfbuzz/harfbuzz.git "$HARFBUZZ_TAG"
meson_build harfbuzz -Dfreetype=enabled -Dcoretext=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
  -Dicu=disabled -Dchafa=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled

fetch libass https://github.com/libass/libass.git "$LIBASS_TAG"
meson_build libass -Dfontconfig=disabled -Dcoretext=enabled -Dlibunibreak=disabled -Ddirectwrite=disabled

# --- video -----------------------------------------------------------------
fetch lcms2 https://github.com/mm2/Little-CMS.git "$LCMS2_TAG"
meson_build lcms2 -Dutils=false -Dtests=disabled -Djpeg=disabled -Dtiff=disabled

fetch dav1d https://code.videolan.org/videolan/dav1d.git "$DAV1D_TAG"
meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false

fetch libplacebo https://code.videolan.org/videolan/libplacebo.git "$LIBPLACEBO_TAG" --recurse
meson_build libplacebo -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dd3d11=disabled \
  -Dopengl=enabled -Dlcms=enabled -Ddovi=enabled -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled \
  -Ddemos=false -Dtests=false

if ! done_flag ffmpeg; then
  log "ffmpeg $FFMPEG_VERSION (LGPL, VideoToolbox, Secure Transport for https)"
  if [ ! -d "$SRC/ffmpeg" ]; then
    mkdir -p "$SRC/ffmpeg"
    curl -fsSL --retry 4 --retry-delay 15 --retry-all-errors "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ -C "$SRC/ffmpeg" --strip-components 1
  fi
  (cd "$SRC/ffmpeg" && ./configure --prefix="$PREFIX" --enable-shared --disable-static \
      --disable-programs --disable-doc --disable-debug --disable-autodetect \
      --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
      --enable-zlib --enable-bzlib --enable-iconv --enable-libdav1d \
      --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --extra-libs="-liconv" \
    && make -j "$JOBS" && make install)
  mark_done ffmpeg
fi

if ! done_flag sdl2; then
  log "SDL2 (game controllers)"
  fetch sdl2 https://github.com/libsdl-org/SDL.git "$SDL2_TAG"
  cmake -S "$SRC/sdl2" -B "$SRC/sdl2/_build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL_X11=OFF
  cmake --build "$SRC/sdl2/_build" --target install
  # SDL installs with an @rpath install name; the app bundler only copies libraries referenced by
  # absolute path, so give it one like the meson-built libraries have
  install_name_tool -id "$PREFIX/lib/libSDL2-2.0.0.dylib" "$PREFIX/lib/libSDL2-2.0.0.dylib"
  mark_done sdl2
fi

fetch mpv https://github.com/mpv-player/mpv.git "$MPV_TAG"
if ! done_flag mpv; then
  for p in "$ROOT"/patches/mpv/*.patch; do
    [ -e "$p" ] || continue
    git -C "$SRC/mpv" apply --check "$p" 2>/dev/null && git -C "$SRC/mpv" apply "$p" && echo "applied $(basename "$p")"
  done
fi
meson_build mpv -Dlibmpv=true -Dcplayer=false -Dtests=false -Dfuzzers=false \
  -Dlua=disabled -Djavascript=disabled -Dvapoursynth=disabled -Dvulkan=disabled -Dshaderc=disabled \
  -Dlibarchive=disabled -Duchardet=disabled -Drubberband=disabled -Dzimg=disabled -Dlibbluray=disabled \
  -Ddvdnav=disabled -Dcdda=disabled -Djpeg=disabled -Dsdl2-audio=disabled -Dsdl2-video=disabled \
  -Dsdl2-gamepad=disabled -Dlibcurl=disabled -Dsubrandr=disabled -Dspirv-cross=disabled -Dlcms2=enabled -Dzlib=enabled -Diconv=enabled \
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled

# --- Jellyfin Desktop ---------------------------------------------------------
log "jellyfin-desktop $JELLYFIN_TAG"
JFD="$SRC/jellyfin-desktop-$JELLYFIN_TAG"
fetch "jellyfin-desktop-$JELLYFIN_TAG" https://github.com/jellyfin/jellyfin-desktop.git "$JELLYFIN_TAG" --recurse
for p in "$ROOT"/patches/jellyfin-desktop/*.patch; do
  [ -e "$p" ] || continue
  git -C "$JFD" apply --check "$p" 2>/dev/null && git -C "$JFD" apply "$p" && echo "applied $(basename "$p")"
done
rm -rf "$JFD/build"
cmake -S "$JFD" -B "$JFD/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$JFD/build/output" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DQTROOT="$QTROOT" \
  -DCMAKE_PREFIX_PATH="$QTROOT;$PREFIX" \
  -DCMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew" \
  -DCHECK_FOR_UPDATES=OFF \
  -DUSE_STATIC_MPVQT=ON
cmake --build "$JFD/build" --target install

APP="$JFD/build/output/Jellyfin Desktop.app"
# Qt SQL drivers for PostgreSQL/ODBC/Mimer are pulled in by macdeployqt but link to external client
# libraries and are not used by the app
rm -f "$APP"/Contents/PlugIns/sqldrivers/libqsql{psql,odbc,mimer}.dylib
# same for the NMEA (serial GPS) positioning plugin, which needs QtSerialPort
rm -f "$APP"/Contents/PlugIns/position/libqtposition_nmea.dylib

log "verify bundle"
"$ROOT/scripts/verify-bundle.sh" "$APP" "$MACOS_MIN"

log "sign (ad-hoc) and package"
codesign --force --deep -s - "$APP"
VER="${JELLYFIN_TAG#v}"
DMG="$DIST/JellyfinDesktop-$VER-macos-x86_64.dmg"
STAGE="$WORK/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Jellyfin Desktop $VER (Intel)" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "DMG: $DMG"
