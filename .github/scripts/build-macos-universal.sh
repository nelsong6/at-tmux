#!/bin/bash
set -euo pipefail

work_dir="${RUNNER_TEMP:?}/tmux-universal"
prefix="$work_dir/install"
parallel="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=13.0

# Homebrew fetch checks the formula's source checksum before extraction.
brew fetch --build-from-source libevent utf8proc
for formula in libevent utf8proc; do
    source_dir="$work_dir/$formula"
    mkdir -p "$source_dir"
    tar -xf "$(brew --cache --build-from-source "$formula")" \
        -C "$source_dir" --strip-components=1
done

cmake_common=(
    "-DCMAKE_INSTALL_PREFIX=$prefix"
    -DCMAKE_BUILD_TYPE=Release
    '-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64'
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)
cmake -S "$work_dir/libevent" -B "$work_dir/libevent-build" \
    "${cmake_common[@]}" \
    -DEVENT__LIBRARY_TYPE=STATIC \
    -DEVENT__DISABLE_OPENSSL=ON \
    -DEVENT__DISABLE_TESTS=ON \
    -DEVENT__DISABLE_REGRESS=ON \
    -DEVENT__DISABLE_SAMPLES=ON \
    -DEVENT__DISABLE_BENCHMARK=ON
cmake --build "$work_dir/libevent-build" --parallel "$parallel"
cmake --install "$work_dir/libevent-build"

cmake -S "$work_dir/utf8proc" -B "$work_dir/utf8proc-build" \
    "${cmake_common[@]}" -DBUILD_SHARED_LIBS=OFF
cmake --build "$work_dir/utf8proc-build" --parallel "$parallel"
cmake --install "$work_dir/utf8proc-build"

# Static universal dependencies keep the Mac artifact independent of the
# runner's Homebrew architecture. System frameworks remain dynamically linked.
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG='pkg-config --static'
export CC=clang
export CPPFLAGS="-I$prefix/include"
export CFLAGS='-O2 -arch x86_64 -arch arm64'
export LDFLAGS="-arch x86_64 -arch arm64 -L$prefix/lib"
sh autogen.sh
./configure --enable-utf8proc
make -j"$parallel"
lipo tmux -verify_arch x86_64 arm64
otool -L tmux
while read -r dependency; do
    case "$dependency" in
        /usr/lib/*|/System/Library/*) ;;
        *) echo "Unexpected non-system runtime dependency: $dependency" >&2; exit 1 ;;
    esac
done < <(otool -L tmux | awk '/^[[:space:]]/ {print $1}')
