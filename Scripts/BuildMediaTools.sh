#!/bin/bash
# Independently builds redistributable media tools from their public sources,
# once per architecture, and joins them into universal ffmpeg and ffprobe.
# LIME_ARCHS="arm64" builds a single architecture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${LIME_DEPS_DIR:-$ROOT/.deps}"
mkdir -p "$WORK" "$ROOT/Resources/Tools" "$ROOT/Resources/Licenses"
WORK="$(cd "$WORK" && pwd)"
ARCHS="${LIME_ARCHS:-arm64 x86_64}"
JOBS="${LIME_BUILD_JOBS:-6}"
export MACOSX_DEPLOYMENT_TARGET=13.0
mkdir -p "$WORK/downloads" "$WORK/host"
fetch() {
  local archive="$1" url="$2"
  if [ ! -s "$WORK/downloads/$archive" ]; then
    curl -L --fail --retry 2 "$url" -o "$WORK/downloads/$archive"
  fi
}
fetch pkg-config-0.29.2.tar.gz https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
fetch lame-3.100.tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
fetch opus-1.5.2.tar.gz https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
fetch libwebp-1.5.0.tar.gz https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz
fetch libvpx-1.15.2.tar.gz https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v1.15.2
fetch libogg-1.3.5.tar.gz https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
fetch libvorbis-1.3.7.tar.gz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
fetch ffmpeg-8.0.tar.xz https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz

# pkg-config runs on the build machine, so it is built once, natively.
if [ ! -x "$WORK/host/bin/pkg-config" ]; then
  rm -rf "$WORK/host-src" && mkdir -p "$WORK/host-src"
  tar -xf "$WORK/downloads/pkg-config-0.29.2.tar.gz" -C "$WORK/host-src"
  (cd "$WORK/host-src/pkg-config-0.29.2" &&
    ./configure --prefix="$WORK/host" --with-internal-glib --disable-host-tool CFLAGS="-O2 -Wno-int-conversion -Wno-incompatible-function-pointer-types" &&
    make -j"$JOBS" && make install)
fi
export PATH="$WORK/host/bin:$PATH"

# x86_64 ffmpeg and libvpx need nasm for their hand-written SIMD.
case " $ARCHS " in *" x86_64 "*) command -v nasm >/dev/null || { echo "x86_64 needs nasm (brew install nasm)"; exit 1; } ;; esac

build_arch() {
  local arch="$1" host vpx_target ff_arch
  case "$arch" in
    arm64) host=aarch64-apple-darwin; vpx_target=arm64-darwin20-gcc; ff_arch=aarch64 ;;
    x86_64) host=x86_64-apple-darwin; vpx_target=x86_64-darwin20-gcc; ff_arch=x86_64 ;;
    *) echo "Unknown architecture $arch"; exit 1 ;;
  esac
  local prefix="$WORK/prefix-$arch" src="$WORK/src-$arch"
  mkdir -p "$prefix" "$src"
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  export CFLAGS="-O2 -arch $arch -mmacosx-version-min=13.0"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-arch $arch -mmacosx-version-min=13.0"
  local autoconf=(--prefix="$prefix" --host="$host" --disable-shared --enable-static)
  unpack() { [ -d "$src/$2" ] || tar -xf "$WORK/downloads/$1" -C "$src"; }

  unpack lame-3.100.tar.gz lame-3.100
  if [ ! -f "$prefix/lib/libmp3lame.a" ]; then
    (cd "$src/lame-3.100" && ./configure "${autoconf[@]}" --disable-frontend && make -j"$JOBS" && make install)
  fi
  unpack opus-1.5.2.tar.gz opus-1.5.2
  if [ ! -f "$prefix/lib/libopus.a" ]; then
    (cd "$src/opus-1.5.2" && ./configure "${autoconf[@]}" --disable-extra-programs --disable-doc && make -j"$JOBS" && make install)
  fi
  unpack libwebp-1.5.0.tar.gz libwebp-1.5.0
  if [ ! -f "$prefix/lib/libwebp.a" ]; then
    (cd "$src/libwebp-1.5.0" && ./configure "${autoconf[@]}" --disable-sdl --disable-gl --disable-png --disable-jpeg --disable-tiff --disable-gif &&
      make -j"$JOBS" && make install)
  fi
  unpack libvpx-1.15.2.tar.gz libvpx-1.15.2
  if [ ! -f "$prefix/lib/libvpx.a" ]; then
    (cd "$src/libvpx-1.15.2" && ./configure --prefix="$prefix" --target="$vpx_target" --disable-shared --enable-static \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests && make -j"$JOBS" && make install)
  fi
  unpack libogg-1.3.5.tar.gz libogg-1.3.5
  if [ ! -f "$prefix/lib/libogg.a" ]; then
    (cd "$src/libogg-1.3.5" && ./configure "${autoconf[@]}" && make -j"$JOBS" && make install)
  fi
  unpack libvorbis-1.3.7.tar.gz libvorbis-1.3.7
  if [ ! -f "$prefix/lib/libvorbis.a" ]; then
    (cd "$src/libvorbis-1.3.7" && sed -i '' 's/-force_cpusubtype_ALL//g' configure &&
      ./configure "${autoconf[@]}" --disable-oggtest --with-ogg="$prefix" && make -j"$JOBS" && make install)
  fi
  unpack ffmpeg-8.0.tar.xz ffmpeg-8.0
  (cd "$src/ffmpeg-8.0" && { make distclean >/dev/null 2>&1 || true; } &&
    ./configure --prefix="$prefix" --cc=clang --cxx=clang++ --arch="$ff_arch" --target-os=darwin --enable-cross-compile \
      --disable-shared --enable-static --disable-debug --disable-doc --disable-ffplay \
      --disable-network --disable-autodetect --enable-videotoolbox --enable-audiotoolbox \
      --enable-zlib --enable-bzlib --enable-libvorbis --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libwebp \
      --extra-cflags="-arch $arch -I$prefix/include -mmacosx-version-min=13.0" \
      --extra-ldflags="-arch $arch -L$prefix/lib -mmacosx-version-min=13.0" --pkg-config-flags=--static &&
    make -j"$JOBS")
}

for arch in $ARCHS; do build_arch "$arch"; done
for tool in ffmpeg ffprobe; do
  parts=()
  for arch in $ARCHS; do parts+=("$WORK/src-$arch/ffmpeg-8.0/$tool"); done
  lipo -create "${parts[@]}" -output "$ROOT/Resources/Tools/$tool"
done
SRC="$WORK/src-${ARCHS%% *}"
cp "$SRC/ffmpeg-8.0/COPYING.LGPLv2.1" "$SRC/ffmpeg-8.0/COPYING.LGPLv3" "$SRC/ffmpeg-8.0/LICENSE.md" "$ROOT/Resources/Licenses/"
cp "$SRC/lame-3.100/COPYING" "$ROOT/Resources/Licenses/LAME.txt"
cp "$SRC/opus-1.5.2/COPYING" "$ROOT/Resources/Licenses/Opus.txt"
cp "$SRC/libwebp-1.5.0/COPYING" "$ROOT/Resources/Licenses/WebP.txt"
cp "$SRC/libvpx-1.15.2/LICENSE" "$ROOT/Resources/Licenses/VPX.txt"
cp "$SRC/libvorbis-1.3.7/COPYING" "$ROOT/Resources/Licenses/Vorbis.txt"
cp "$SRC/libogg-1.3.5/COPYING" "$ROOT/Resources/Licenses/Ogg.txt"
for executable in "$ROOT/Resources/Tools/ffmpeg" "$ROOT/Resources/Tools/ffprobe"; do
  codesign --force --sign - "$executable"
done
(cd "$WORK/downloads" && shasum -a 256 *) > "$ROOT/Resources/Licenses/SOURCE-SHA256.txt"
echo "Media tools built for $ARCHS in $ROOT/Resources/Tools"
