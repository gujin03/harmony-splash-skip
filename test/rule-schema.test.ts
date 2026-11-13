/**
 * RuleSchema 单元测试（导入导出 / checksum / 校验，FR-3.4）
 * 运行：bash test/run.sh
 */

import assert from 'node:assert';
import {
  fnv1a32,
  canonicalRules,
  rulesChecksum,
  buildExport,
  parseImport,
  validateBody,
  EXPORT_FORMAT,
  RULE_SCHEMA_VERSION
} from '../.test-build/RuleSchema.ts';
import type { RulesBody, RuleLike } from '../.test-build/RuleSchema.ts';

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

function r(domain: string, matchType: string, enabled: boolean): RuleLike {
  return { domain: domain, matchType: matchType, enabled: enabled, note: '' };
}

function body(): RulesBody {
  return {
    blacklist: [r('ads.example.com', 'suffix', true), r('sdk.e.qq.com', 'exact', true)],
    whitelist: [r('alipay.com', 'suffix', true)],
    sessionAllow: ['b.example.com', 'a.example.com']
  };
}

console.log('\n=== 1. FNV-1a 32 校验和 ===');
{
  eq(fnv1a32(''), '811c9dc5', '空串为 FNV offset basis');
  eq(fnv1a32('a'), 'e40c292c', '单字符 a 的标准 FNV-1a 值');
  eq(fnv1a32('hello'), '4f9f2cab', 'hello 的标准 FNV-1a 值');
  eq(fnv1a32('x').length, 8, '固定 8 位十六进制');
  ok(fnv1a32('foo') !== fnv1a32('bar'), '不同输入得到不同校验和');
}

console.log('=== 2. 规范化与稳定性 ===');
{
  const b = body();
  eq(canonicalRules(b), canonicalRules(b), '同一规则体两次规范化结果一致');
  const c1: string = rulesChecksum(b);
  const b2: RulesBody = {
    blacklist: [r(' ADS.EXAMPLE.COM. ', 'suffix', true), r('sdk.e.qq.com', 'exact', true)],
    whitelist: [r('alipay.com', 'suffix', true)],
    sessionAllow: ['a.example.com', 'b.example.com']
  };
  eq(rulesChecksum(b2), c1, '大小写/末尾点归一化 + sessionAllow 排序后 checksum 不变');
  ok(c1 !== rulesChecksum({
    blacklist: [r('ads.example.com', 'suffix', false), r('sdk.e.qq.com', 'exact', true)],
    whitelist: [r('alipay.com', 'suffix', true)],
    sessionAllow: []
  }), 'enabled/sessionAllow 变化会改变 checksum');
}

console.log('=== 3. 导出 → 导入往返 ===');
{
  const text: string = buildExport(body(), 1700000000000);
  const env = JSON.parse(text);
  eq(env.format, EXPORT_FORMAT, 'format 标记');
  eq(env.schemaVersion, RULE_SCHEMA_VERSION, 'schemaVersion');
  eq(env.exportedAt, 1700000000000, '导出时间由调用方传入');
  eq(env.checksum, rulesChecksum(body()), 'checksum 可复算');
  const res = parseImport(text);
  ok(res.ok, '合法信封导入通过');
  eq(res.body === null, false, '返回规则体');
  eq(res.errors.length, 0, '无错误');
  if (res.body !== null) {
    eq(res.body.blacklist.length, 2, '黑名单条数');
    eq(res.body.whitelist[0].domain, 'alipay.com', '白名单内容');
  }
}

console.log('=== 4. 篡改与非法输入必须被拒 ===');
{
  const text: string = buildExport(body(), 1);
  const tampered = JSON.parse(text);
  tampered.rules.blacklist[0].domain = 'evil.example.com';
  ok(!parseImport(JSON.stringify(tampered)).ok, '改域名后 checksum 不匹配 → 拒绝');

  const badFmt = JSON.parse(text);
  badFmt.format = 'other';
  ok(!parseImport(JSON.stringify(badFmt)).ok, 'format 不符 → 拒绝');

  const badVer = JSON.parse(text);
  badVer.schemaVersion = 99;
  ok(!parseImport(JSON.stringify(badVer)).ok, 'schemaVersion 不兼容 → 拒绝');

  ok(!parseImport('{not json').ok, '非 JSON → 拒绝');
  ok(!parseImport('{}').ok, '缺 rules → 拒绝');

  const badType: RulesBody = {
    blacklist: [r('a.com', 'regex', true)],
    whitelist: [],
    sessionAllow: []
  };
  eq(validateBody(badType).ok, false, '非法 matchType → 校验失败');
  const emptyDomain: RulesBody = {
    blacklist: [r('   ', 'exact', true)],
    whitelist: [],
    sessionAllow: []
  };
  eq(validateBody(emptyDomain).ok, false, '空域名 → 校验失败');
  eq(validateBody(body()).ok, true, '合法规则体 → 校验通过');
}

console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
