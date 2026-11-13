/**
 * DiagStats 单元测试（本机 node 直跑）
 */

import { DiagStats, ACTION_BLOCK, ACTION_FWD, ACTION_FAIL } from '../.test-build/DiagStats.ts';

let pass = 0;
let fail = 0;

function ok(cond: boolean, name: string): void {
  if (cond) {
    pass++;
  } else {
    fail++;
    console.error(`  ✗ ${name}`);
  }
}

function eq(actual: unknown, expected: unknown, name: string): void {
  if (actual === expected) {
    pass++;
  } else {
    fail++;
    console.error(`  ✗ ${name}（期望 ${String(expected)}，实际 ${String(actual)}）`);
  }
}

console.log('\n=== 1. 计数 ===');
{
  const s = new DiagStats();
  s.bumpDns();
  s.bumpDns();
  s.bumpWritten();
  s.bumpWriteErr();
  s.bumpOverload();
  const snap = s.snapshot(1000);
  eq(snap.dns, 2, 'dns');
  eq(snap.written, 1, 'written');
  eq(snap.writeErr, 1, 'writeErr');
  eq(snap.overload, 1, 'overload');
  eq(snap.updatedAt, 1000, 'updatedAt 用传入值');
}

console.log('=== 2. 动作分类计数 ===');
{
  const s = new DiagStats();
  s.record(1, 'a.com', ACTION_BLOCK, 'rule1', 4);
  s.record(2, 'b.com', ACTION_FWD, 'pass', 4);
  s.record(3, 'c.com', ACTION_FAIL, 'timeout', 6);
  const snap = s.snapshot(0);
  eq(snap.block, 1, 'block');
  eq(snap.fwdOk, 1, 'fwdOk');
  eq(snap.fwdFail, 1, 'fwdFail');
  eq(snap.recent.length, 3, 'recent 条数');
  eq(snap.recent[0].q, 'a.com', 'recent 保留顺序');
  eq(snap.recent[2].a, ACTION_FAIL, 'recent 记录动作');
}

console.log('=== 3. recent 环形覆盖（上限 20）===');
{
  const s = new DiagStats();
  for (let i = 0; i < 25; i++) {
    s.record(i, `d${i}.com`, ACTION_FWD, 'p', 4);
  }
  const snap = s.snapshot(0);
  eq(snap.recent.length, 20, '最多保留 20 条');
  eq(snap.recent[0].q, 'd5.com', '最旧的被挤掉（首条是第 6 个）');
  eq(snap.recent[19].q, 'd24.com', '最后一条是最新');
  eq(snap.fwdOk, 25, '总数仍完整计数');
}

console.log('=== 4. TopN 排序（降序 + 同值稳定）===');
{
  const s = new DiagStats();
  s.record(1, 'b.com', ACTION_BLOCK, 'r', 4);
  s.record(2, 'b.com', ACTION_BLOCK, 'r', 4);
  s.record(3, 'a.com', ACTION_BLOCK, 'r', 4);
  s.record(4, 'a.com', ACTION_BLOCK, 'r', 4);
  s.record(5, 'c.com', ACTION_BLOCK, 'r', 4);
  const top = s.snapshot(0).topBlocked;
  eq(top.length, 3, '3 个不同域名');
  eq(top[0].domain, 'a.com', '同计数按字母序：a 在前');
  eq(top[0].count, 2, 'a.com 计数 2');
  eq(top[1].domain, 'b.com', 'b.com 第二');
  eq(top[2].domain, 'c.com', 'c.com 计数 1 排最后');
}

console.log('=== 5. TopN 截断（上限 10）===');
{
  const s = new DiagStats();
  for (let i = 0; i < 15; i++) {
    s.record(i, `x${i}.com`, ACTION_BLOCK, 'r', 4);
  }
  const top = s.snapshot(0).topBlocked;
  eq(top.length, 10, '最多返回 10 条');
}

console.log('=== 6. 黑/白名单分列表独立 ===');
{
  const s = new DiagStats();
  s.record(1, 'ad.com', ACTION_BLOCK, 'r', 4);
  s.record(2, 'api.com', ACTION_FWD, 'p', 4);
  s.record(3, 'api.com', ACTION_FWD, 'p', 4);
  const snap = s.snapshot(0);
  eq(snap.topBlocked.length, 1, '拦截列表 1 个');
  eq(snap.topForwarded.length, 1, '转发列表 1 个');
  eq(snap.topForwarded[0].count, 2, 'api.com 转发 2 次');
  eq(snap.topBlocked[0].domain, 'ad.com', '拦截列表内容正确');
}

console.log('=== 7. snapshot 是拷贝（外部修改不影响内部）===');
{
  const s = new DiagStats();
  s.record(1, 'a.com', ACTION_BLOCK, 'r', 4);
  const snap1 = s.snapshot(0);
  snap1.recent.push({ t: 99, q: 'hack.com', a: ACTION_FWD, m: '', v: 4 });
  const snap2 = s.snapshot(0);
  eq(snap2.recent.length, 1, '外部 push 不影响内部');
}

console.log('=== 8. 可 JSON 序列化（写文件前提）===');
{
  const s = new DiagStats();
  s.record(1, 'a.com', ACTION_BLOCK, 'r', 4);
  const json = JSON.stringify(s.snapshot(123));
  ok(json.indexOf('"topBlocked"') > 0, 'JSON 含 topBlocked');
  const back = JSON.parse(json) as Record<string, Object>;
  ok(back['block'] === 1, 'JSON 往返后计数正确');
}

console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
