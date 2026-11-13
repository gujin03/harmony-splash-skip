#!/bin/bash
# 本机跑纯函数层单元测试（不装机、不编译 HAP）
#
# 原理：Node 24 的 type stripping 默认开启，把 .ets 复制成 .ts 即可直接运行。
#      核心模块必须自包含（零本地 import），否则 node 无法解析扩展名；
#      测试文件里纯类型必须用 `import type`。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="/Applications/DevEco-Studio.app/Contents/tools/node/bin/node"
BUILD="$ROOT/.test-build"
CORE="$ROOT/entry/src/main/ets/core"

if [ ! -x "$NODE" ]; then
  echo "找不到 node：$NODE"
  exit 1
fi

mkdir -p "$BUILD"

# .ets → .ts（只复制纯函数模块，适配层不参与测试）
MODULES=("DnsCodec" "DomainRules" "DiagStats" "RuleSchema" "GradeStats")
for m in "${MODULES[@]}"; do
  if [ ! -f "$CORE/$m.ets" ]; then
    echo "缺少核心模块：$CORE/$m.ets"
    exit 1
  fi
  cp "$CORE/$m.ets" "$BUILD/$m.ts"
done

echo "node: $($NODE --version)"
echo "模块: ${MODULES[*]}"
echo

FAILED=0
for t in "$ROOT"/test/*.test.ts; do
  echo "▶ $(basename "$t")"
  if ! "$NODE" "$t"; then
    FAILED=1
  fi
  echo
done

if [ "$FAILED" -ne 0 ]; then
  echo "❌ 有测试文件失败"
  exit 1
fi
echo "✅ 全部测试通过"
