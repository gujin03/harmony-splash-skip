/**
 * GradeStats 单元测试（效果分级与分层验收口径，FR-5.2 / §10-1）
 * 运行：bash test/run.sh
 */

import assert from 'node:assert';
import {
  GRADE_A,
  GRADE_B,
  GRADE_C,
  GRADE_D,
  GRADE_E,
  isValidGrade,
  upsertGrade,
  latestByApp,
  summarizeGrades,
  gradeLabel
} from '../.test-build/GradeStats.ts';
import type { GradeFile, GradeRecord } from '../.test-build/GradeStats.ts';

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

function rec(app: string, bundle: string, grade: string, at: number): GradeRecord {
  return { app: app, bundle: bundle, grade: grade, at: at, note: '' };
}

console.log('\n=== 1. 分级合法性 ===');
{
  ok(isValidGrade(GRADE_A) && isValidGrade(GRADE_E), 'A 与 E 合法');
  ok(!isValidGrade('F') && !isValidGrade(''), 'F 与空串非法');
  ok(gradeLabel(GRADE_E).indexOf('不计入分母') >= 0, 'E 级说明含分层口径');
}

console.log('=== 2. 追加与按 App 取最新 ===');
{
  const f0: GradeFile = { version: 1, records: [] };
  const f1 = upsertGrade(f0, rec('车来了', 'com.chelaile', GRADE_D, 100));
  const f2 = upsertGrade(f1, rec('车来了', 'com.chelaile', GRADE_B, 200));
  eq(f1.records.length, 1, '追加后条数 1');
  eq(f2.records.length, 2, '历史全留（不覆盖）');
  eq(f0.records.length, 0, '不改原对象（纯函数）');
  const latest = latestByApp(f2.records);
  eq(latest.length, 1, '同一 bundle 聚合为 1 条');
  eq(latest[0].grade, GRADE_B, '取时间戳更大的 B');
}

console.log('=== 3. 分层统计：E 不计入分母 ===');
{
  const records: Array<GradeRecord> = [
    rec('车来了', 'com.chelaile', GRADE_B, 100),
    rec('应用2', 'com.app2', GRADE_A, 100),
    rec('应用3', 'com.app3', GRADE_A, 100),
    rec('应用4', 'com.app4', GRADE_D, 100),
    rec('平安好车主', 'com.pingan', GRADE_E, 100),
    rec('中国联通', 'com.unicom', GRADE_E, 100)
  ];
  const s = summarizeGrades(records);
  eq(s.denominator, 4, '分母 = A+B+C+D，E 被排除');
  eq(s.e, 2, 'E 级样本 2 款单独计数');
  eq(s.ab, 3, 'A+B = 3');
  eq(s.d, 1, 'D = 1');
  eq(s.abRate, 75, 'A+B 占比 75%');
  eq(s.dRate, 25, 'D 占比 25%');
  eq(s.enoughSamples, true, '4 款样本足够判定');
  eq(s.passAb, true, 'A+B ≥ 60% 达标');
  eq(s.passD, false, 'D ≤ 20% 未达标');
}

console.log('=== 4. 样本不足与更新后重算 ===');
{
  const few: Array<GradeRecord> = [
    rec('车来了', 'com.chelaile', GRADE_B, 100),
    rec('平安', 'com.pingan', GRADE_E, 100)
  ];
  const s = summarizeGrades(few);
  eq(s.denominator, 1, '只有 1 款计入分母');
  eq(s.abRate, 100, '单样本 A+B 占比 100%');
  eq(s.enoughSamples, false, '样本 <3 不判定达标');
  eq(s.passAb, false, '样本不足时不误报达标');

  const updated: Array<GradeRecord> = [
    rec('车来了', 'com.chelaile', GRADE_B, 100),
    rec('车来了', 'com.chelaile', GRADE_D, 999)
  ];
  eq(summarizeGrades(updated).d, 1, '更新为 D 后按最新记录统计');
  eq(summarizeGrades(updated).ab, 0, '旧 B 不再计入');

  const c: Array<GradeRecord> = [rec('占位', 'com.c', GRADE_C, 1)];
  eq(summarizeGrades(c).c, 1, 'C 级计入分母但不计入 A+B');
}

console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
