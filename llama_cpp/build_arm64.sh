#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 自动探测 SDK 版本
SDK_BASE="$SOURCE_ROOT/prebuilts/ohos-sdk/linux"
OHOS_SDK_ROOT=$(ls -d $SDK_BASE/* 2>/dev/null | sort -V | tail -n 1)

if [ ! -d "$OHOS_SDK_ROOT" ]; then
    echo "Error: Could not find OHOS SDK in $SDK_BASE"
    exit 1
fi

export OHOS_CLANG_ROOT="$SOURCE_ROOT/prebuilts/clang/ohos/linux-x86_64/llvm"
export PATH="$SOURCE_ROOT/prebuilts/cmake/linux-x86/bin:$PATH"

echo "Using SDK: $OHOS_SDK_ROOT"
cd "$SCRIPT_DIR"
rm -rf build_arm64 && mkdir build_arm64 && cd build_arm64

cmake .. \
    -DCMAKE_TOOLCHAIN_FILE="../ohos_arm64.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH="armv8-a" \
    -DGGML_OPENMP=OFF \
    -DGGML_BLAS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DBUILD_SHARED_LIBS=ON

cmake --build . -j$(nproc) --target llama
