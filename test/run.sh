#!/bin/bash
# 本机跑 DnsCodec 单元测试（不装机、不编译 HAP）
#
# 原理：Node 24 的 type stripping 默认开启，把 .ets 复制成 .ts 即可直接运行。
#      核心模块必须自包含（零本地 import），否则 node 无法解析扩展名。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="/Applications/DevEco-Studio.app/Contents/tools/node/bin/node"
BUILD="$ROOT/.test-build"
SRC="$ROOT/entry/src/main/ets/core"

if [ ! -x "$NODE" ]; then
  echo "找不到 node：$NODE"
  exit 1
fi

mkdir -p "$BUILD"

# .ets → .ts（只复制纯函数模块，适配层不参与测试）
cp "$SRC/DnsCodec.ets" "$BUILD/DnsCodec.ts"

echo "node: $($NODE --version)"
echo "源码: $SRC/DnsCodec.ets"
echo

"$NODE" "$ROOT/test/dns-codec.test.ts"
