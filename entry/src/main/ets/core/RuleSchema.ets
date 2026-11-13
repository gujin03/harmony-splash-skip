/**
 * 规则导入／导出与完整性校验（PRD FR-3.4、附录 D）
 *
 * ⛔ 纯函数、零本地 import：run.sh 会把 core/*.ets 复制成 .ts 供 node 直跑，
 *    模块间带 import 会让 node 无法解析扩展名，所以本文件自带所需的小工具函数。
 *
 * 导出信封格式：
 *   { format, schemaVersion, exportedAt, checksum, rules: { blacklist, whitelist, sessionAllow } }
 * checksum = FNV-1a32(规范化后的规则体)，不含 exportedAt／updatedAt，保证可复算。
 */

export interface RuleLike {
  domain: string;
  matchType: string;
  enabled: boolean;
  note: string;
}

export interface RulesBody {
  blacklist: Array<RuleLike>;
  whitelist: Array<RuleLike>;
  sessionAllow: Array<string>;
}

export interface ExportEnvelope {
  format: string;
  schemaVersion: number;
  exportedAt: number;
  checksum: string;
  rules?: RulesBody;
}

export interface ValidationResult {
  ok: boolean;
  errors: Array<string>;
}

export interface ImportResult {
  ok: boolean;
  body: RulesBody | null;
  errors: Array<string>;
}

export const EXPORT_FORMAT: string = 'splashskip-rules';
export const RULE_SCHEMA_VERSION: number = 1;
export const CHECKSUM_ALGO: string = 'fnv1a32';
export const VALID_MATCH_TYPES: Array<string> = ['suffix', 'exact', 'keyword'];

/** 与 DomainRules.normalizeDomain 同语义（此处自包含以便 node 直跑） */
export function normalizeDomainLocal(host: string): string {
  let s: string = host.trim().toLowerCase();
  while (s.length > 0 && s.endsWith('.')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/** FNV-1a 32 位，返回 8 位小写十六进制；用 Math.imul 避免 32 位乘法丢精度 */
export function fnv1a32(text: string): string {
  let h: number = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h = h ^ (text.charCodeAt(i) & 0xFF);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  let hex: string = (h >>> 0).toString(16);
  while (hex.length < 8) {
    hex = '0' + hex;
  }
  return hex;
}

function ruleLine(r: RuleLike): string {
  const d: string = typeof r.domain === 'string' ? normalizeDomainLocal(r.domain) : '';
  const m: string = typeof r.matchType === 'string' ? r.matchType : '';
  const n: string = typeof r.note === 'string' ? r.note : '';
  return d + '|' + m + '|' + (r.enabled ? '1' : '0') + '|' + n;
}

/** 稳定序列化：字段顺序固定、域名归一化、sessionAllow 排序，保证同一规则体 checksum 恒定 */
export function canonicalRules(body: RulesBody): string {
  const lines: Array<string> = [];
  lines.push('v' + String(RULE_SCHEMA_VERSION));
  lines.push('B');
  for (const r of body.blacklist) {
    lines.push(ruleLine(r));
  }
  lines.push('W');
  for (const r of body.whitelist) {
    lines.push(ruleLine(r));
  }
  lines.push('A');
  const allow: Array<string> = [];
  for (const s of body.sessionAllow) {
    allow.push(normalizeDomainLocal(s));
  }
  allow.sort();
  for (const s of allow) {
    lines.push(s);
  }
  return lines.join('\n');
}

export function rulesChecksum(body: RulesBody): string {
  return fnv1a32(canonicalRules(body));
}

export function buildExport(body: RulesBody, exportedAt: number): string {
  const env: ExportEnvelope = {
    format: EXPORT_FORMAT,
    schemaVersion: RULE_SCHEMA_VERSION,
    exportedAt: exportedAt,
    checksum: rulesChecksum(body),
    rules: body
  };
  return JSON.stringify(env);
}

function checkRule(r: RuleLike, errors: Array<string>, tag: string): void {
  const raw: string = typeof r.domain === 'string' ? r.domain : '';
  if (normalizeDomainLocal(raw).length === 0) {
    errors.push(tag + ' 存在空域名规则');
  }
  const mt: string = typeof r.matchType === 'string' ? r.matchType : '';
  if (VALID_MATCH_TYPES.indexOf(mt) < 0) {
    errors.push(tag + ' 匹配类型非法：' + mt);
  }
}

export function validateBody(body: RulesBody): ValidationResult {
  const errors: Array<string> = [];
  if (!Array.isArray(body.blacklist) || !Array.isArray(body.whitelist) ||
      !Array.isArray(body.sessionAllow)) {
    errors.push('blacklist / whitelist / sessionAllow 必须都是数组');
    return { ok: false, errors: errors };
  }
  for (const r of body.blacklist) {
    checkRule(r, errors, 'blacklist');
  }
  for (const r of body.whitelist) {
    checkRule(r, errors, 'whitelist');
  }
  return { ok: errors.length === 0, errors: errors };
}

/** 解析并校验导入文本：格式标记、schema 版本、字段合法性、checksum 四关全过才放行 */
export function parseImport(text: string): ImportResult {
  const errors: Array<string> = [];
  let env: ExportEnvelope;
  try {
    env = JSON.parse(text) as ExportEnvelope;
  } catch (e) {
    errors.push('JSON 解析失败');
    return { ok: false, body: null, errors: errors };
  }
  if (env.format !== EXPORT_FORMAT) {
    errors.push('format 不是 ' + EXPORT_FORMAT);
  }
  if (env.schemaVersion !== RULE_SCHEMA_VERSION) {
    errors.push('schemaVersion 不兼容（需要 ' + String(RULE_SCHEMA_VERSION) + '）');
  }
  if (env.rules === undefined || env.rules === null) {
    errors.push('缺少 rules 字段');
    return { ok: false, body: null, errors: errors };
  }
  const body: RulesBody = env.rules;
  const v: ValidationResult = validateBody(body);
  for (const e of v.errors) {
    errors.push(e);
  }
  const expect: string = rulesChecksum(body);
  if (env.checksum !== expect) {
    errors.push('checksum 不匹配（期望 ' + expect + '，实际 ' + String(env.checksum) + '）');
  }
  if (errors.length > 0) {
    return { ok: false, body: null, errors: errors };
  }
  return { ok: true, body: body, errors: errors };
}
