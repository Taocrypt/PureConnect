#!/usr/bin/env bash
# Build zjuconnect-core for one or more targets.
#
#   core/build.sh                 # host OS/arch
#   core/build.sh android         # android arm64 + armv7 + x86_64 -> android/app/src/main/jniLibs
#   core/build.sh linux-amd64 windows-amd64 darwin-arm64 ...
#
# Env: ZJU_CONNECT_REF (default pinned commit), ZJU_CONNECT_DIR (checkout dir),
#      CORE_VERSION (version string baked into the core; default git describe),
#      ANDROID_NDK_HOME (needed for armeabi-v7a / x86_64), REQUIRE_NDK=1 (fail
#      instead of skipping those ABIs; CI sets it so no stale .so is shipped)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${ZJU_CONNECT_REF:-8576e7a16076c4175d6dbe276573a353cf7260be}"
SRC="${ZJU_CONNECT_DIR:-$ROOT/core/.upstream}"
OUT="$ROOT/core/dist"
CORE_VERSION="${CORE_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/Mythologyli/zju-connect.git "$SRC"
fi
git -C "$SRC" fetch --tags --quiet origin || true
git -C "$SRC" checkout --quiet "$REF"
UPSTREAM_VERSION="$(git -C "$SRC" describe --tags --always)"

for p in "$ROOT"/core/patches/*.patch; do
  [ -e "$p" ] || continue
  (cd "$SRC" && (git apply --check "$p" 2>/dev/null && git apply "$p" && echo ">> applied $(basename "$p")") || true)
done
rm -rf "$SRC/cmd/zjuconnect-core"
mkdir -p "$SRC/cmd/zjuconnect-core"
cp "$ROOT"/core/bridge/*.go "$SRC/cmd/zjuconnect-core/"

LDFLAGS="-s -w -X main.coreVersion=$CORE_VERSION -X main.upstreamVersion=$UPSTREAM_VERSION"

build() { # goos goarch [goarm] outfile
  local goos=$1 goarch=$2 goarm=$3 out=$4
  echo ">> $goos/$goarch${goarm:+ v$goarm} -> ${out#$ROOT/}"
  mkdir -p "$(dirname "$out")"
  (cd "$SRC" && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch GOARM=$goarm \
    go build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/zjuconnect-core)
}

# wintun.dll (signed by WireGuard LLC) must sit next to zjuconnect-core.exe
# for desktop TUN mode on Windows; the Windows CMake install copies both.
WINTUN_VERSION=0.14.1
WINTUN_SHA256=07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51
fetch_wintun() { # arch(amd64|arm64) destdir
  local arch=$1 dest=$2 cache="$ROOT/core/.cache"
  local zip="$cache/wintun-$WINTUN_VERSION.zip"
  if [ -f "$dest/wintun.dll" ]; then return 0; fi
  mkdir -p "$cache" "$dest"
  if [ ! -f "$zip" ]; then
    echo ">> downloading wintun $WINTUN_VERSION"
    curl -fsSL --retry 3 -o "$zip.part" "https://www.wintun.net/builds/wintun-$WINTUN_VERSION.zip"
    mv "$zip.part" "$zip"
  fi
  local sum
  sum="$( (sha256sum "$zip" 2>/dev/null || shasum -a 256 "$zip") | cut -d' ' -f1)"
  if [ "$sum" != "$WINTUN_SHA256" ]; then
    echo "!! wintun checksum mismatch ($sum)" >&2
    rm -f "$zip"
    exit 1
  fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -p "$zip" "wintun/bin/$arch/wintun.dll" > "$dest/wintun.dll"
  else
    local tmp="$cache/wintun-x"
    rm -rf "$tmp"
    powershell.exe -NoProfile -Command "Expand-Archive -Force -Path '$(cygpath -w "$zip" 2>/dev/null || echo "$zip")' -DestinationPath '$(cygpath -w "$tmp" 2>/dev/null || echo "$tmp")'"
    cp "$tmp/wintun/bin/$arch/wintun.dll" "$dest/wintun.dll"
  fi
  echo ">> wintun.dll ($arch) -> ${dest#$ROOT/}"
}

targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=("$(go env GOOS)-$(go env GOARCH)")

for t in "${targets[@]}"; do
  case "$t" in
    android)
      JNI="$ROOT/android/app/src/main/jniLibs"
      if [ -z "${ANDROID_NDK_HOME:-}" ] && [ "${REQUIRE_NDK:-0}" = 1 ]; then
        echo "!! REQUIRE_NDK=1 but ANDROID_NDK_HOME is not set" >&2; exit 1
      fi
      # Never ship a stale core for an ABI this run doesn't rebuild.
      rm -f "$JNI"/*/libzjuconnect_core.so
      # Packaged as lib*.so so Android extracts it to nativeLibraryDir, the
      # only app location that allows exec() on modern Android.
      build android arm64 "" "$JNI/arm64-v8a/libzjuconnect_core.so"
      # android/arm needs cgo (external linking) -> only with an NDK.
      if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        CC="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/armv7a-linux-androideabi24-clang | head -1)"
        echo ">> android/arm v7 (cgo) -> android/app/src/main/jniLibs/armeabi-v7a/libzjuconnect_core.so"
        mkdir -p "$JNI/armeabi-v7a"
        (cd "$SRC" && CGO_ENABLED=1 CC="$CC" GOOS=android GOARCH=arm GOARM=7 \
          go build -trimpath -ldflags "$LDFLAGS" -o "$JNI/armeabi-v7a/libzjuconnect_core.so" ./cmd/zjuconnect-core)
      else
        echo "!! skipping android/arm v7: set ANDROID_NDK_HOME to build it" >&2
      fi
      if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        CC="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/x86_64-linux-android24-clang | head -1)"
        echo ">> android/amd64 (cgo) -> android/app/src/main/jniLibs/x86_64/libzjuconnect_core.so"
        mkdir -p "$JNI/x86_64"
        (cd "$SRC" && CGO_ENABLED=1 CC="$CC" GOOS=android GOARCH=amd64 \
          go build -trimpath -ldflags "$LDFLAGS" -o "$JNI/x86_64/libzjuconnect_core.so" ./cmd/zjuconnect-core)
      else
        echo "!! skipping android/amd64 (emulator): set ANDROID_NDK_HOME to build it" >&2
      fi
      ;;
    windows-*)
      build windows "${t#windows-}" "" "$OUT/$t/zjuconnect-core.exe"
      fetch_wintun "${t#windows-}" "$OUT/$t"
      ;;
    *-*)       build "${t%%-*}" "${t#*-}" "" "$OUT/$t/zjuconnect-core" ;;
    *) echo "unknown target $t" >&2; exit 1 ;;
  esac
done
