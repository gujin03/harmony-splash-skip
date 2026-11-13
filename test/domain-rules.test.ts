/**
 * DomainRules 单元测试（本机 node 直跑）
 * 覆盖 ADR-001 AD-4：suffix 语义、白名单优先、enabled 开关、防误命中。
 */

import {
  normalizeDomain,
  matchesRule,
  findRule,
  decide,
  ACTION_ALLOW,
  ACTION_BLOCK,
  MATCH_SUFFIX,
  MATCH_EXACT,
  MATCH_KEYWORD
} from '../.test-build/DomainRules.ts';
import type { DomainRule } from '../.test-build/DomainRules.ts';

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

function rule(domain: string, matchType: string, enabled: boolean): DomainRule {
  return { domain: domain, matchType: matchType, enabled: enabled, note: '' };
}

console.log('\n=== 1. normalizeDomain ===');
eq(normalizeDomain('  Ads.Pangolin.COM.  '), 'ads.pangolin.com', '去空白、转小写、去末尾点');
eq(normalizeDomain('a.b.'), 'a.b', '单个末尾点');
eq(normalizeDomain('a.b...'), 'a.b', '多个末尾点');
eq(normalizeDomain(''), '', '空串');
eq(normalizeDomain('   '), '', '空白串');

console.log('=== 2. suffix 语义（AD-4 关键）===');
{
  const r = rule('pangolin-sdk-toutiao.com', MATCH_SUFFIX, true);
  ok(matchesRule('pangolin-sdk-toutiao.com', r), '完全等于 → 命中');
  ok(matchesRule('api-access.pangolin-sdk-toutiao.com', r), '多级子域 → 命中');
  ok(matchesRule('a.b.pangolin-sdk-toutiao.com', r), '更深子域 → 命中');
  ok(!matchesRule('notpangolin-sdk-toutiao.com', r), '前缀粘连 → 不命中');
  ok(!matchesRule('pangolin-sdk-toutiao.com.attacker.net', r), '后缀被追加 → 不命中');
  ok(!matchesRule('evil-pangolin-sdk-toutiao.com.attacker.net', r), '内嵌伪装域名 → 不命中');
  ok(!matchesRule('pangolin-sdk-toutiao.co', r), '缩短后缀 → 不命中');
}

console.log('=== 3. exact 语义 ===');
{
  const r = rule('api.example.com', MATCH_EXACT, true);
  ok(matchesRule('api.example.com', r), '精确相等 → 命中');
  ok(!matchesRule('x.api.example.com', r), '子域 → 不命中');
}

console.log('=== 4. keyword 语义 ===');
{
  const r = rule('pangolin', MATCH_KEYWORD, true);
  ok(matchesRule('api.pangolin-sdk-toutiao.com', r), '包含关键字 → 命中');
  ok(!matchesRule('example.com', r), '不含 → 不命中');
}

console.log('=== 5. enabled 开关 ===');
{
  const off = rule('a.com', MATCH_SUFFIX, false);
  ok(!matchesRule('a.com', off), 'enabled=false 不生效');
  eq(findRule('a.com', [off]), -1, 'findRule 返回 -1');
}

console.log('=== 6. findRule 顺序与越界安全 ===');
{
  const rules: DomainRule[] = [
    rule('a.com', MATCH_SUFFIX, true),
    rule('sub.a.com', MATCH_SUFFIX, true)
  ];
  eq(findRule('x.sub.a.com', rules), 0, '先命中的下标优先');
  eq(findRule('other.com', rules), -1, '不命中 → -1');
  eq(findRule('', rules), -1, '空 host → -1');
  eq(findRule('a.com', []), -1, '空规则 → -1');
}

console.log('=== 7. 白名单优先于黑名单（FR-3.3）===');
{
  // 假设黑名单误把 api.chelaile.net.cn 的父域加入，白名单应救回来
  const black: DomainRule[] = [rule('chelaile.net.cn', MATCH_SUFFIX, true)];
  const white: DomainRule[] = [rule('api.chelaile.net.cn', MATCH_EXACT, true)];
  eq(decide('api.chelaile.net.cn', white, black), ACTION_ALLOW, '白名单精确命中 → 放行');
  eq(decide('ad.chelaile.net.cn', white, black), ACTION_BLOCK, '白名单未命中、黑名单命中 → 拦截');
  eq(decide('other.com', white, black), ACTION_ALLOW, '都不命中 → 放行');
}

console.log('=== 8. 支付类硬白名单场景 ===');
{
  const black: DomainRule[] = [rule('alipay.com', MATCH_SUFFIX, true)];
  const white: DomainRule[] = [rule('alipay.com', MATCH_SUFFIX, true)];
  eq(decide('mclient.alipay.com', white, black), ACTION_ALLOW, '同时出现在两边时白名单胜出');
}

console.log('=== 9. 空规则域名的防护 ===');
{
  const bad = rule('', MATCH_SUFFIX, true);
  ok(!matchesRule('a.com', bad), '空域名规则不命中任何 host');
  const dot = rule('.', MATCH_SUFFIX, true);
  ok(!matchesRule('a.com', dot), '仅一个点的规则归一化后为空 → 不命中');
}

console.log('=== 10. 联通自有广告规则：默认关闭 + 绝不误伤业务域（PRD R-13）===');
{
  // 与 TargetApps.ets 真实配置一致：实测无效的广告子域保持 enabled=false
  const off: DomainRule[] = [
    rule('smartad.10010.com', MATCH_EXACT, false),
    rule('m1.ad.10010.com', MATCH_EXACT, false),
    rule('m1.img.10010.com', MATCH_EXACT, false)
  ];
  const white: DomainRule[] = [
    rule('loginxx.10010.com', MATCH_EXACT, true),
    rule('m.client.10010.com', MATCH_EXACT, true),
    rule('enrichgw.10010.com', MATCH_EXACT, true),
    rule('mobile.unicompayment.com', MATCH_EXACT, true)
  ];
  eq(decide('smartad.10010.com', white, off), ACTION_ALLOW, '实测无效 → 默认放行（不灌水命中率）');
  eq(decide('m1.ad.10010.com', white, off), ACTION_ALLOW, '实测无效 → 默认放行');
  eq(decide('m1.img.10010.com', white, off), ACTION_ALLOW, '实测无效 → 默认放行');

  // 负向断言：即便以后有人临时开启，也只能命中最精确的主机名
  const on: DomainRule[] = [
    rule('smartad.10010.com', MATCH_EXACT, true),
    rule('m1.ad.10010.com', MATCH_EXACT, true),
    rule('m1.img.10010.com', MATCH_EXACT, true)
  ];
  eq(decide('smartad.10010.com', white, on), ACTION_BLOCK, '临时开启 → 只拦精确主机名');
  const biz: string[] = [
    'loginxx.10010.com', 'm.client.10010.com', 'img.client.10010.com',
    'hlclient.10010.com', 'pushservice.10010.com', 'enrichgw.10010.com',
    'mobile.unicompayment.com', '10010.com', 'm1.ad.10010.com.evil.net'
  ];
  for (const h of biz) {
    eq(decide(h, white, on), ACTION_ALLOW, `业务域/非广告域放行：${h}`);
  }
}

console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
