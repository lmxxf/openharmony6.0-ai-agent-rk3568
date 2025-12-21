#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# 自动生成 local.properties
SDK_BASE="$SOURCE_ROOT/prebuilts/ohos-sdk/linux"
LATEST_SDK=$(ls -d $SDK_BASE/* 2>/dev/null | sort -V | tail -n 1)
echo "sdk.dir=$LATEST_SDK" > "$SCRIPT_DIR/local.properties"

echo ">>> SDK Path: $LATEST_SDK"
chmod +x "$SCRIPT_DIR/llama_cpp/build_arm64.sh" "$SCRIPT_DIR/build_napi_arm64.sh"
"$SCRIPT_DIR/llama_cpp/build_arm64.sh"
"$SCRIPT_DIR/build_napi_arm64.sh"

echo ">>> Done! Now run hvigorw."
