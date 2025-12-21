#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SDK_BASE="$SOURCE_ROOT/prebuilts/ohos-sdk/linux"
export OHOS_SDK_ROOT=$(ls -d $SDK_BASE/* 2>/dev/null | sort -V | tail -n 1)
OHOS_CLANG_ROOT="$SOURCE_ROOT/prebuilts/clang/ohos/linux-x86_64/llvm"
SYSROOT="$OHOS_SDK_ROOT/native/sysroot"

TARGET="aarch64-linux-ohos"
LLAMA_BUILD_DIR="$SCRIPT_DIR/llama_cpp/build_arm64/bin"
LIBS_DIR="$SCRIPT_DIR/product/phone/libs/arm64-v8a"
SRC="$SCRIPT_DIR/product/phone/src/main/cpp/llama_napi.cpp"
OUT="$LIBS_DIR/libllama_napi.so"

mkdir -p "$LIBS_DIR"
cp "$LLAMA_BUILD_DIR"/lib*.so "$LIBS_DIR/"
cd "$LIBS_DIR"

sanitize_lib() {
    if [ -L "$1" ]; then target=$(readlink "$1"); rm "$1"; cp "$target" "$1"; fi
}
for lib in libllama.so libggml.so libggml-base.so libggml-cpu.so; do
    sanitize_lib $lib
    patchelf --set-soname $lib $lib
    patchelf --set-rpath '$ORIGIN' $lib
done

# 清除所有 .so.0 版本号依赖 (llama.cpp 编译产物默认带版本号)
patchelf --replace-needed libggml.so.0 libggml.so libllama.so 2>/dev/null || true
patchelf --replace-needed libggml-base.so.0 libggml-base.so libllama.so 2>/dev/null || true
patchelf --replace-needed libggml-cpu.so.0 libggml-cpu.so libllama.so 2>/dev/null || true
patchelf --replace-needed libggml-cpu.so.0 libggml-cpu.so libggml.so 2>/dev/null || true
patchelf --replace-needed libggml-base.so.0 libggml-base.so libggml.so 2>/dev/null || true
patchelf --replace-needed libggml-base.so.0 libggml-base.so libggml-cpu.so 2>/dev/null || true

cd "$SCRIPT_DIR"
"$OHOS_CLANG_ROOT/bin/clang++" \
    --target=$TARGET --sysroot="$SYSROOT" -fPIC -shared -std=c++17 -O2 \
    -I"$SCRIPT_DIR/llama_cpp/include" -I"$SCRIPT_DIR/llama_cpp/ggml/include" \
    -I"$SYSROOT/usr/include" -I"$SYSROOT/usr/include/napi" \
    -L"$LIBS_DIR" -L"$SYSROOT/usr/lib/$TARGET" \
    -lllama -lggml -lggml-base -lggml-cpu -lace_napi.z -lhilog_ndk.z \
    -Wl,-rpath,'$ORIGIN' -o "$OUT" "$SRC"
