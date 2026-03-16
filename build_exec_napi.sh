#!/bin/bash
# Build exec_napi.so (popen wrapper) for aarch64 OpenHarmony
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SDK_BASE="$SOURCE_ROOT/prebuilts/ohos-sdk/linux"
OHOS_SDK_ROOT=$(ls -d $SDK_BASE/* 2>/dev/null | sort -V | tail -n 1)
OHOS_CLANG_ROOT="$SOURCE_ROOT/prebuilts/clang/ohos/linux-x86_64/llvm"
SYSROOT="$OHOS_SDK_ROOT/native/sysroot"

TARGET="aarch64-linux-ohos"
LIBS_DIR="$SCRIPT_DIR/product/phone/libs/arm64-v8a"
SRC="$SCRIPT_DIR/product/phone/src/main/cpp/exec_napi.cpp"
OUT="$LIBS_DIR/libexec_napi.so"

mkdir -p "$LIBS_DIR"

echo "Building exec_napi.so..."
"$OHOS_CLANG_ROOT/bin/clang++" \
    --target=$TARGET --sysroot="$SYSROOT" -fPIC -shared -std=c++17 -O2 \
    -I"$SYSROOT/usr/include" -I"$SYSROOT/usr/include/napi" \
    -L"$SYSROOT/usr/lib/$TARGET" \
    -lace_napi.z -lhilog_ndk.z \
    -o "$OUT" "$SRC"

echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
