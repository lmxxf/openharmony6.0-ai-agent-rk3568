#!/bin/bash
# Settings HAP 编译脚本
# 用法: ./build.sh

set -e

# 切换到 Node 18 (hvigor 不兼容 Node 22)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
nvm use 18 > /dev/null 2>&1 || true

echo "=== 编译 Settings HAP ==="
echo "Node: $(node --version)"

# 清理旧构建
if [ -d "product/phone/build" ]; then
    echo "清理旧构建..."
    rm -rf product/phone/build
fi

# 清理 hvigor 缓存（如果编译有问题）
if [ "$1" = "--clean" ]; then
    echo "清理 hvigor 缓存..."
    rm -rf .hvigor
fi

# 编译
echo "开始编译..."
./hvigorw assembleHap --mode module -p product=default -p module=phone

HAP_PATH="product/phone/build/default/outputs/default/phone-default-signed.hap"

if [ -f "$HAP_PATH" ]; then
    echo ""
    echo "=== 编译成功 ==="
    echo "HAP 路径: $HAP_PATH"
    echo ""
    echo "安装命令: hdc install $HAP_PATH"
else
    echo ""
    echo "=== 编译失败 ==="
    exit 1
fi
