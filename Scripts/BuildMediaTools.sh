#!/bin/bash
# Independently builds redistributable media tools from their public sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${LIME_DEPS_DIR:-$ROOT/.deps}"
mkdir -p "$WORK" "$ROOT/Resources/Tools" "$ROOT/Resources/Licenses"
WORK="$(cd "$WORK" && pwd)"
PREFIX="$WORK/prefix"
mkdir -p "$WORK/downloads" "$WORK/src" "$PREFIX"
export MACOSX_DEPLOYMENT_TARGET=13.0
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export CFLAGS="-O2 -mmacosx-version-min=13.0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=13.0"
JOBS="${LIME_BUILD_JOBS:-6}"
fetch() {
  local archive="$1" url="$2"
  if [ ! -s "$WORK/downloads/$archive" ]; then
    curl -L --fail --retry 2 "$url" -o "$WORK/downloads/$archive"
  fi
  tar -xf "$WORK/downloads/$archive" -C "$WORK/src"
}
fetch pkg-config-0.29.2.tar.gz https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
fetch lame-3.100.tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
fetch opus-1.5.2.tar.gz https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
fetch libwebp-1.5.0.tar.gz https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz
fetch libvpx-1.15.2.tar.gz https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v1.15.2
fetch libogg-1.3.5.tar.gz https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
fetch libvorbis-1.3.7.tar.gz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
fetch ffmpeg-8.0.tar.xz https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
cd "$WORK/src/pkg-config-0.29.2"
if [ ! -x "$PREFIX/bin/pkg-config" ]; then
  ./configure --prefix="$PREFIX" --with-internal-glib --disable-host-tool CFLAGS="$CFLAGS -Wno-int-conversion -Wno-incompatible-function-pointer-types"
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/lame-3.100"
if [ ! -f "$PREFIX/lib/libmp3lame.a" ]; then
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/opus-1.5.2"
if [ ! -f "$PREFIX/lib/libopus.a" ]; then
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-extra-programs --disable-doc
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/libwebp-1.5.0"
if [ ! -f "$PREFIX/lib/libwebp.a" ]; then
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-sdl --disable-gl --disable-png --disable-jpeg --disable-tiff --disable-gif
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/libvpx-1.15.2"
if [ ! -f "$PREFIX/lib/libvpx.a" ]; then
  ./configure --prefix="$PREFIX" --target=arm64-darwin20-gcc --disable-shared --enable-static --disable-examples --disable-tools --disable-docs --disable-unit-tests
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/libogg-1.3.5"
if [ ! -f "$PREFIX/lib/libogg.a" ]; then
  ./configure --prefix="$PREFIX" --disable-shared --enable-static
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/libvorbis-1.3.7"
if [ ! -f "$PREFIX/lib/libvorbis.a" ]; then
  sed -i '' 's/-force_cpusubtype_ALL//g' configure
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-oggtest --with-ogg="$PREFIX"
  make -j"$JOBS"
  make install
fi
cd "$WORK/src/ffmpeg-8.0"
make distclean >/dev/null 2>&1 || true
./configure --prefix="$PREFIX" --cc=clang --cxx=clang++ --arch=arm64 --target-os=darwin \
  --disable-shared --enable-static --disable-debug --disable-doc --disable-ffplay \
  --disable-network --disable-autodetect --enable-videotoolbox --enable-audiotoolbox \
  --enable-zlib --enable-bzlib --enable-libvorbis --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libwebp \
  --extra-cflags="-I$PREFIX/include -mmacosx-version-min=13.0" \
  --extra-ldflags="-L$PREFIX/lib -mmacosx-version-min=13.0" --pkg-config-flags=--static
make -j"$JOBS"
cp ffmpeg ffprobe "$ROOT/Resources/Tools/"
cp COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md "$ROOT/Resources/Licenses/"
cp "$WORK/src/lame-3.100/COPYING" "$ROOT/Resources/Licenses/LAME.txt"
cp "$WORK/src/opus-1.5.2/COPYING" "$ROOT/Resources/Licenses/Opus.txt"
cp "$WORK/src/libwebp-1.5.0/COPYING" "$ROOT/Resources/Licenses/WebP.txt"
cp "$WORK/src/libvpx-1.15.2/LICENSE" "$ROOT/Resources/Licenses/VPX.txt"
cp "$WORK/src/libvorbis-1.3.7/COPYING" "$ROOT/Resources/Licenses/Vorbis.txt"
cp "$WORK/src/libogg-1.3.5/COPYING" "$ROOT/Resources/Licenses/Ogg.txt"
for executable in "$ROOT/Resources/Tools/ffmpeg" "$ROOT/Resources/Tools/ffprobe"; do
  codesign --force --sign - "$executable"
done
(cd "$WORK/downloads" && shasum -a 256 *) > "$ROOT/Resources/Licenses/SOURCE-SHA256.txt"
echo "Media tools built in $ROOT/Resources/Tools"
