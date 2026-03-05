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

    # 安装到设备
    if command -v hdc &> /dev/null; then
        echo "安装 HAP..."
        hdc install "$HAP_PATH"

        # 修复 SSL 根证书（RK3568 出厂证书包不全，缺少 DigiCert/GeoTrust 等常用 CA，
        # 会导致 HTTPS 请求报错 2300060 "SSL peer certificate was not OK"）
        CACERT="product/phone/src/main/resources/rawfile/cacert.pem"
        if [ -f "$CACERT" ]; then
            echo "推送 CA 根证书到设备..."
            hdc shell 'mount -o remount,rw /'
            hdc file send "$CACERT" /etc/ssl/certs/cacert.pem
            echo "CA 根证书已更新"
        fi

        echo ""
        echo "=== 部署完成 ==="
    else
        echo "hdc 未找到，请手动安装:"
        echo "  hdc install $HAP_PATH"
    fi
else
    echo ""
    echo "=== 编译失败 ==="
    exit 1
fi
