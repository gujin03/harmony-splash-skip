/**
 * 核心模块集成测试（本机 node 直跑，不装机）
 *
 * 覆盖一条完整链路：
 *   DNS 查询解析 → 诊断统计 → TopN 漏拦发现 → 规则加黑／导出导入 → 判定变化
 *   → 效果分级汇总；并校验跨进程快照新增的收包分项与 DoH 计数字段。
 *
 * ⚠️ SkipVpnExtension / UpstreamForwarder 依赖 @ohos.*，无法在 node 跑，
 *    它们与文件 IO 的集成由《真机 PoC 验证手册》的人工／hdc 流程覆盖。
 */

import assert from 'node:assert';
import { parseDnsQuery } from '../.test-build/DnsCodec.ts';
import type { DnsQuery } from '../.test-build/DnsCodec.ts';
import { DiagStats, ACTION_BLOCK, ACTION_FWD } from '../.test-build/DiagStats.ts';
import {
  decideWithSessionAllow,
  MATCH_EXACT,
  MATCH_SUFFIX,
  ACTION_ALLOW,
  ACTION_BLOCK as RULE_BLOCK
} from '../.test-build/DomainRules.ts';
import type { DomainRule } from '../.test-build/DomainRules.ts';
import { buildExport, parseImport } from '../.test-build/RuleSchema.ts';
import type { RulesBody } from '../.test-build/RuleSchema.ts';
import { upsertGrade, summarizeGrades, GRADE_A, GRADE_B, GRADE_E } from '../.test-build/GradeStats.ts';
import type { GradeFile } from '../.test-build/GradeStats.ts';

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

/** 测试自带的 DNS 报文构造器（buildDnsMessage 不属于 DnsCodec 模块） */
function encodeQname(name: string): number[] {
  const out: number[] = [];
  const parts: string[] = name.split('.');
  for (const p of parts) {
    out.push(p.length);
    for (let i = 0; i < p.length; i++) {
      out.push(p.charCodeAt(i));
    }
  }
  out.push(0);
  return out;
}

function buildDnsMessage(transId: number, name: string, qtype: number, rd: boolean): number[] {
  const msg: number[] = [];
  msg.push((transId >> 8) & 0xFF, transId & 0xFF);
  msg.push(rd ? 0x01 : 0x00, 0x00);
  msg.push(0x00, 0x01);   // QDCOUNT
  msg.push(0x00, 0x00, 0x00, 0x00, 0x00, 0x00);
  const q: number[] = encodeQname(name);
  for (const b of q) {
    msg.push(b);
  }
  msg.push((qtype >> 8) & 0xFF, qtype & 0xFF, 0x00, 0x01);
  return msg;
}

/** 构造最小 IPv4 UDP DNS 查询包 */
function queryPacket(name: string): Uint8Array {
  const dns: number[] = buildDnsMessage(0x1234, name, 1, true);
  const total: number = 28 + dns.length;
  const out = new Uint8Array(total);
  out[0] = 0x45;
  out[2] = (total >> 8) & 0xFF;
  out[3] = total & 0xFF;
  out[8] = 64;
  out[9] = 17;
  out[12] = 10; out[13] = 0; out[14] = 0; out[15] = 2;
  out[16] = 10; out[17] = 0; out[18] = 0; out[19] = 1;
  out[20] = 0xD4; out[21] = 0x31;   // src port
  out[22] = 0x00; out[23] = 0x35;   // dst port 53
  out[24] = ((8 + dns.length) >> 8) & 0xFF;
  out[25] = (8 + dns.length) & 0xFF;
  for (let i = 0; i < dns.length; i++) {
    out[28 + i] = dns[i];
  }
  return out;
}

console.log('\n=== 1. 解析 → 统计 → TopN 漏拦发现 ===');
{
  const pkt = queryPacket('ads.example.com');
  const q = parseDnsQuery(pkt) as DnsQuery;
  ok(q !== null, 'DNS 查询解析成功');
  eq(q.qname, 'ads.example.com', 'qname 正确');

  const stats = new DiagStats();
  stats.bumpRead(4);
  stats.bumpRead(6);
  stats.bumpRead(4);
  stats.bumpDohLike();
  stats.bumpDns();
  stats.record(1000, q.qname, ACTION_FWD, 'upstream', 4);
  stats.record(1001, q.qname, ACTION_FWD, 'upstream', 4);
  stats.record(1002, 'blocked.example.com', ACTION_BLOCK, 'example.com', 4);
  const snap = stats.snapshot(1003);

  eq(snap.dns, 1, 'dns 计数');
  eq(snap.reads, 3, 'reads 分项（FR-5.3）');
  eq(snap.v4, 2, 'v4 分项');
  eq(snap.v6, 1, 'v6 分项');
  eq(snap.dohLike, 1, 'dohLike 计数（FR-8.1）');
  eq(snap.topForwarded[0].domain, 'ads.example.com', '转发 Top1 是漏拦域名');
  eq(snap.topForwarded[0].count, 2, 'Top1 计数 2');
  eq(snap.topBlocked[0].domain, 'blocked.example.com', '拦截 Top1');
}

console.log('=== 2. TopN 一键加黑 → 判定从放行变拦截 ===');
{
  const blacklist: Array<DomainRule> = [
    { domain: 'known.example.com', matchType: MATCH_SUFFIX, enabled: true, note: '' }
  ];
  const whitelist: Array<DomainRule> = [];
  const sessionAllow: Array<string> = [];

  const before = decideWithSessionAllow('ads.example.com', whitelist, blacklist, sessionAllow);
  eq(before.action, ACTION_ALLOW, '加黑前放行');

  // 模拟 RuleStore.addBlacklistDomain：精确匹配、默认启用
  blacklist.push({ domain: 'ads.example.com', matchType: MATCH_EXACT, enabled: true, note: 'TopN 一键加黑' });
  const after = decideWithSessionAllow('ads.example.com', whitelist, blacklist, sessionAllow);
  eq(after.action, RULE_BLOCK, '加黑后拦截');
  eq(after.reason, 'ads.example.com', '命中原因回传新规则');

  // 本次放行优先于黑名单
  sessionAllow.push('ads.example.com');
  eq(decideWithSessionAllow('ads.example.com', whitelist, blacklist, sessionAllow).reason,
    'session-allow', '本次放行优先（FR-8.3）');
}

console.log('=== 3. 规则导出 → 篡改拒绝 → 原样导入 ===');
{
  const body: RulesBody = {
    blacklist: [
      { domain: 'ads.example.com', matchType: MATCH_EXACT, enabled: true, note: 'TopN 一键加黑' }
    ],
    whitelist: [{ domain: 'alipay.com', matchType: MATCH_SUFFIX, enabled: true, note: '' }],
    sessionAllow: []
  };
  const text = buildExport(body, 1700000000000);
  ok(parseImport(text).ok, '原样导出可导入');

  const tampered = JSON.parse(text);
  tampered.rules.blacklist[0].domain = 'evil.example.com';
  const bad = parseImport(JSON.stringify(tampered));
  ok(!bad.ok, '篡改域名被 checksum 拒绝');
  ok(bad.errors.join('').indexOf('checksum') >= 0, '错误信息指出 checksum');

  const good = parseImport(text);
  ok(good.body !== null, '合法信封返回规则体');
  if (good.body !== null) {
    const d = decideWithSessionAllow('ads.example.com', good.body.whitelist,
      good.body.blacklist, good.body.sessionAllow);
    eq(d.action, RULE_BLOCK, '导入后的规则立即参与判定');
  }
}

console.log('=== 4. 效果分级汇总（E 不计入分母） ===');
{
  let f: GradeFile = { version: 1, records: [] };
  f = upsertGrade(f, { app: '车来了', bundle: 'com.chelaile', grade: GRADE_B, at: 1, note: '' });
  f = upsertGrade(f, { app: '样本2', bundle: 'com.s2', grade: GRADE_A, at: 1, note: '' });
  f = upsertGrade(f, { app: '样本3', bundle: 'com.s3', grade: GRADE_A, at: 1, note: '' });
  f = upsertGrade(f, { app: '平安好车主', bundle: 'com.pingan', grade: GRADE_E, at: 1, note: '' });
  f = upsertGrade(f, { app: '中国联通', bundle: 'com.unicom', grade: GRADE_E, at: 1, note: '' });
  const s = summarizeGrades(f.records);
  eq(s.denominator, 3, '第三方层分母 3');
  eq(s.e, 2, 'E 级 2 款不计入');
  eq(s.abRate, 100, 'A+B 占比 100%');
  eq(s.enoughSamples, true, '样本数达标可判定');
  eq(s.passAb, true, 'A+B 门槛通过');
  eq(s.passD, true, 'D 门槛通过');
}

console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
