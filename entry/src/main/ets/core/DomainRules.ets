/**
 * 域名规则匹配（纯函数）
 *
 * 契约见 docs/ADR-001-DNS拦截架构决策.md AD-4：
 *   - 扁平数组 + 后缀比较，不上 Trie（规则量级几十到几百条）
 *   - 白名单优先级高于黑名单（PRD FR-3.3）
 *   - suffix 语义：等于该值，或以 "." + 该值 结尾（防 evil-x.com.attacker.net 误命中）
 *
 * ⛔ 禁止 import 任何 `@ohos.*`、禁止打日志、禁止持有状态。
 */

export interface DomainRule {
  domain: string;
  /** 'suffix' | 'exact' | 'keyword' */
  matchType: string;
  enabled: boolean;
  note: string;
}

export const MATCH_SUFFIX: string = 'suffix';
export const MATCH_EXACT: string = 'exact';
export const MATCH_KEYWORD: string = 'keyword';

/** 统一小写、去末尾点、去首尾空白 */
export function normalizeDomain(host: string): string {
  let s: string = host.trim().toLowerCase();
  while (s.length > 0 && s.endsWith('.')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/** 单条规则是否命中（host 应已 normalize） */
export function matchesRule(host: string, rule: DomainRule): boolean {
  if (!rule.enabled) {
    return false;
  }
  const d: string = normalizeDomain(rule.domain);
  if (d.length === 0) {
    return false;
  }
  if (rule.matchType === MATCH_EXACT) {
    return host === d;
  }
  if (rule.matchType === MATCH_KEYWORD) {
    return host.indexOf(d) >= 0;
  }
  // 默认按 suffix 处理：精确等于，或以 .d 结尾
  return host === d || host.endsWith('.' + d);
}

/** 返回命中的规则下标，未命中返回 -1 */
export function findRule(host: string, rules: DomainRule[]): number {
  const h: string = normalizeDomain(host);
  if (h.length === 0) {
    return -1;
  }
  for (let i = 0; i < rules.length; i++) {
    if (matchesRule(h, rules[i])) {
      return i;
    }
  }
  return -1;
}

/** 判定动作：'allow' | 'block' */
export const ACTION_ALLOW: string = 'allow';
export const ACTION_BLOCK: string = 'block';

/**
 * 综合判定：白名单优先于黑名单。
 * 返回命中的规则下标（block 时）或 -1（allow）。
 */
export function decide(host: string, whitelist: DomainRule[], blacklist: DomainRule[]): string {
  if (findRule(host, whitelist) >= 0) {
    return ACTION_ALLOW;
  }
  if (findRule(host, blacklist) >= 0) {
    return ACTION_BLOCK;
  }
  return ACTION_ALLOW;
}
