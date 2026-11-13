#!/bin/bash
# 本机跑纯函数层单元测试（不装机、不编译 HAP）
#
# 原理：Node 24 的 type stripping 默认开启，把 .ets 复制成 .ts 即可直接运行。
#      核心模块必须自包含（零本地 import），否则 node 无法解析扩展名；
#      测试文件里纯类型必须用 `import type`。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.test-build"
CORE="$ROOT/entry/src/main/ets/core"

# 解析 node：优先 $NODE_HOME/bin/node，否则回退 PATH 中的 node（等价 which node）
if [ -n "$NODE_HOME" ] && [ -x "$NODE_HOME/bin/node" ]; then
  NODE="$NODE_HOME/bin/node"
elif command -v node >/dev/null 2>&1; then
  NODE="$(command -v node)"
else
  echo "找不到 node：请设置 NODE_HOME（指向含 bin/node 的目录，如 DevEco Studio 自带的 Node 路径），或把 node 加入 PATH。"
  exit 1
fi

mkdir -p "$BUILD"

# .ets → .ts（只复制纯函数模块，适配层不参与测试）
MODULES=("DnsCodec" "DomainRules" "DiagStats" "RuleSchema" "GradeStats" "RuleInit")
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
