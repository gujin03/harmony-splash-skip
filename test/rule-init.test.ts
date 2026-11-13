/**
 * RuleInit 单元测试（F-2 损坏回退不变式，FR-3.5）
 * 运行：bash test/run.sh
 *
 * 只测纯函数 decideInit：规则文件损坏（存在但不可读）必须返回 'reseed'，
 * 绝不能退化为「静默保留空规则」——这正是 F-2 要锁死的回归点。
 */

import assert from 'node:assert';
import { decideInit } from '../.test-build/RuleInit.ts';
import type { InitAction } from '../.test-build/RuleInit.ts';

let pass = 0;
let fail = 0;

function eq(actual: unknown, expected: unknown, name: string): void {
  if (actual === expected) {
    pass++;
  } else {
    fail++;
    console.error(`  ✗ ${name}（期望 ${String(expected)}，实际 ${String(actual)}）`);
  }
}

function isAction(a: unknown): boolean {
  return a === 'seed' || a === 'load' || a === 'reseed';
}

console.log('\n=== RuleInit.decideInit ===');

// 1. 文件不存在 → seed（首次启动播种子）
eq(decideInit(false, false), 'seed', '文件不存在 → seed');
eq(decideInit(false, true), 'seed', '文件不存在（即便 readable 为真）→ seed');

// 2. 文件存在且可读 → load（以文件为准）
eq(decideInit(true, true), 'load', '文件存在且可读 → load');

// 3. ⛔ F-2 核心不变式：文件存在但不可读（半写/损坏/权限异常）→ reseed
eq(decideInit(true, false), 'reseed', '文件损坏（存在但不可读）→ reseed（绝不静默留空）');

// 4. 返回值必须是合法的 InitAction，且 seed/load 不会误判为 reseed
{
  const actions: Array<[boolean, boolean]> = [
    [false, false], [false, true], [true, true], [true, false]
  ];
  for (const [exists, readable] of actions) {
    const a: InitAction = decideInit(exists, readable);
    if (isAction(a)) {
      pass++;
    } else {
      fail++;
      console.error(`  ✗ decideInit(${exists}, ${readable}) 返回非法动作：${a}`);
    }
  }
  eq(decideInit(false, false) !== 'reseed', true, 'seed 不会误判为 reseed');
  eq(decideInit(true, true) !== 'reseed', true, 'load 不会误判为 reseed');
  eq(decideInit(true, false) === 'reseed', true, '损坏场景一定是 reseed');
}

console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
