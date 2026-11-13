/**
 * 规则文件化 + 热更新（FR-3.5 / §10-7）
 *
 * ⛔ 旧实现把规则写成 TargetApps.ets 的编译期 const：改一条规则要改码→编译→装机→重启 VPN，
 *    直接违反 §10「新增规则 ≤ 1 分钟且不重启 VPN」。
 *
 * 新实现：首次运行把编译期默认规则播到 filesDir/rules.json，之后**以文件为准**；
 * 扩展每次派发前调用 refreshIfChanged()（内部 500ms 节流），读 updatedAt 变化即热重载。
 * 主进程与扩展进程靠同一个沙箱文件通信（diag.json 已验证这条通路）。
 *
 * FR-8.3「本次放行」：sessionAllow 数组优先于黑白名单；VPN 停止时由扩展清空。
 */

import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  DomainRule,
  normalizeDomain,
  findRule,
  decideWithSessionAllow,
  MATCH_EXACT
} from '../core/DomainRules';
import type { DecisionResult } from '../core/DomainRules';
import {
  RulesBody,
  buildExport,
  parseImport,
  RULE_SCHEMA_VERSION
} from '../core/RuleSchema';
import type { ImportResult } from '../core/RuleSchema';
import { decideInit } from '../core/RuleInit';
import type { InitAction } from '../core/RuleInit';
import { BLACKLIST, WHITELIST } from './TargetApps';
import { Log } from '../common/Logger';

export interface RulesFile {
  schemaVersion: number;
  /** 单调递增版本号：热重载只比较它，不依赖文件系统 mtime 精度 */
  updatedAt: number;
  blacklist: Array<DomainRule>;
  whitelist: Array<DomainRule>;
  /** 本次会话临时放行（normalize 后的主机名），VPN 停止即清空 */
  sessionAllow: Array<string>;
}

export interface Decision {
  action: string;
  /** 命中的规则域名 / session-allow / whitelist，供诊断记录 */
  reason: string;
}

const RULES_FILE: string = '/rules.json';
const SCHEMA_VERSION: number = 1;
const RELOAD_CHECK_MS: number = 500;

export class RuleStore {
  private path: string;
  private blacklist: Array<DomainRule> = [];
  private whitelist: Array<DomainRule> = [];
  private sessionAllow: Array<string> = [];
  private lastUpdatedAt: number = -1;
  private lastCheckAt: number = 0;

  constructor(filesDir: string) {
    this.path = filesDir + RULES_FILE;
  }

  /** 首次运行播种子；之后每次启动都从文件读回当前规则 */
  init(): void {
    // ⚠️ ArkTS 标注 accessSync 可能抛异常；不兜住会让整个规则加载失败 → 全部放行
    let exists: boolean = false;
    try {
      exists = fs.accessSync(this.path);
    } catch (e) {
      exists = false;
    }
    if (!exists) {
      this.persist({
        schemaVersion: SCHEMA_VERSION,
        updatedAt: 0,
        blacklist: BLACKLIST,
        whitelist: WHITELIST,
        sessionAllow: []
      });
      Log.info('RuleStore seed written');
      return;
    }
    const data: RulesFile | null = this.readFile();
    // ⚠️ 用纯函数决策，F-2 不变式落在可单测的地方：
    //    文件存在但读不出来（半写／损坏／权限异常）→ 'reseed'，
    //    绝不能静默保留空规则（VPN 照跑却一条都不拦）。
    const action: InitAction = decideInit(true, data !== null);
    if (action === 'load') {
      this.apply(data as RulesFile, 'loaded');
      return;
    }
    Log.error('RuleStore file unreadable, re-seeding from built-in defaults');
    this.persist({
      schemaVersion: SCHEMA_VERSION,
      updatedAt: 0,
      blacklist: BLACKLIST,
      whitelist: WHITELIST,
      sessionAllow: []
    });
  }

  /** 每次派发前调用；500ms 内最多读一次文件 */
  refreshIfChanged(): void {
    const now: number = Date.now();
    if (now - this.lastCheckAt < RELOAD_CHECK_MS) {
      return;
    }
    this.lastCheckAt = now;
    const data: RulesFile | null = this.readFile();
    if (data === null || data.updatedAt === this.lastUpdatedAt) {
      return;
    }
    this.apply(data, 'reloaded');
  }

  decide(host: string): Decision {
    const r: DecisionResult = decideWithSessionAllow(
      host, this.whitelist, this.blacklist, this.sessionAllow);
    return { action: r.action, reason: r.reason };
  }

  /** FR-8.3：误拦后本次放行，写盘后下一次查询即生效 */
  addSessionAllow(host: string): void {
    const h: string = normalizeDomain(host);
    if (h.length === 0) {
      return;
    }
    const data: RulesFile | null = this.current();
    if (data === null) {
      return;
    }
    if (data.sessionAllow.indexOf(h) < 0) {
      data.sessionAllow.push(h);
      this.persist(data);
      Log.info(`RuleStore session allow + ${h}`);
    }
  }

  /** FR-5.4「TopN 一键加黑」：精确匹配、默认启用；返回是否真的新增 */
  addBlacklistDomain(host: string, note: string): boolean {
    const h: string = normalizeDomain(host);
    if (h.length === 0) {
      return false;
    }
    const data: RulesFile | null = this.current();
    if (data === null) {
      return false;
    }
    if (findRule(h, data.blacklist) >= 0) {
      return false;
    }
    const r: DomainRule = { domain: h, matchType: MATCH_EXACT, enabled: true, note: note };
    data.blacklist.push(r);
    this.persist(data);
    Log.info(`RuleStore blacklist + ${h}`);
    return true;
  }

  /** VPN 停止时清空临时放行，避免下次启动带着旧放行项 */
  clearSessionAllow(): void {
    const data: RulesFile | null = this.current();
    if (data === null || data.sessionAllow.length === 0) {
      return;
    }
    data.sessionAllow = [];
    this.persist(data);
    Log.info('RuleStore session allow cleared');
  }

  // ------------------------------------------------ 规则编辑 UI（FR-4.3 / FR-3.4）

  /** 编辑页读取完整规则体；每次操作都重新读文件，避免覆盖扩展刚写的变更 */
  getSnapshot(): RulesFile | null {
    return this.current();
  }

  /** 域名测试：返回当前规则下的判定结果 */
  testDomain(host: string): Decision {
    return this.decide(host);
  }

  private listOf(data: RulesFile, list: string): Array<DomainRule> {
    return list === 'white' ? data.whitelist : data.blacklist;
  }

  addRule(list: string, r: DomainRule): boolean {
    const data: RulesFile | null = this.current();
    if (data === null) {
      return false;
    }
    const arr: Array<DomainRule> = this.listOf(data, list);
    if (findRule(normalizeDomain(r.domain), arr) >= 0) {
      return false;   // 已存在同名规则，避免重复
    }
    arr.push(r);
    this.persist(data);
    Log.info(`RuleStore ${list} add ${r.domain}`);
    return true;
  }

  updateRule(list: string, index: number, r: DomainRule): boolean {
    const data: RulesFile | null = this.current();
    if (data === null) {
      return false;
    }
    const arr: Array<DomainRule> = this.listOf(data, list);
    if (index < 0 || index >= arr.length) {
      return false;
    }
    arr[index] = r;
    this.persist(data);
    Log.info(`RuleStore ${list} update #${index}`);
    return true;
  }

  deleteRule(list: string, index: number): boolean {
    const data: RulesFile | null = this.current();
    if (data === null) {
      return false;
    }
    const arr: Array<DomainRule> = this.listOf(data, list);
    if (index < 0 || index >= arr.length) {
      return false;
    }
    arr.splice(index, 1);
    this.persist(data);
    Log.info(`RuleStore ${list} delete #${index}`);
    return true;
  }

  toggleRule(list: string, index: number): boolean {
    const data: RulesFile | null = this.current();
    if (data === null) {
      return false;
    }
    const arr: Array<DomainRule> = this.listOf(data, list);
    if (index < 0 || index >= arr.length) {
      return false;
    }
    const old: DomainRule = arr[index];
    arr[index] = {
      domain: old.domain,
      matchType: old.matchType,
      enabled: !old.enabled,
      note: old.note
    };
    this.persist(data);
    Log.info(`RuleStore ${list} toggle #${index} → ${arr[index].enabled}`);
    return true;
  }

  /** 导出为带 checksum 的信封文本（FR-3.4） */
  exportText(): string {
    const data: RulesFile | null = this.current();
    if (data === null) {
      return '';
    }
    const body: RulesBody = {
      blacklist: data.blacklist,
      whitelist: data.whitelist,
      sessionAllow: data.sessionAllow
    };
    return buildExport(body, Date.now());
  }

  /** 导入并校验；返回空串表示成功，否则返回中文错误列表 */
  importText(text: string): string {
    const res: ImportResult = parseImport(text);
    if (!res.ok || res.body === null) {
      return res.errors.join('；');
    }
    const body: RulesBody = res.body;
    this.persist({
      schemaVersion: RULE_SCHEMA_VERSION,
      updatedAt: 0,
      blacklist: body.blacklist,
      whitelist: body.whitelist,
      sessionAllow: body.sessionAllow
    });
    Log.info('RuleStore import ok');
    return '';
  }

  getCounts(): string {
    return `black=${this.blacklist.length} white=${this.whitelist.length} allow=${this.sessionAllow.length}`;
  }

  private current(): RulesFile | null {
    const data: RulesFile | null = this.readFile();
    if (data === null) {
      return null;
    }
    return data;
  }

  private apply(data: RulesFile, tag: string): void {
    if (!Array.isArray(data.blacklist) || !Array.isArray(data.whitelist)) {
      Log.error('RuleStore bad schema: blacklist/whitelist missing, keep previous');
      return;
    }
    this.blacklist = data.blacklist;
    this.whitelist = data.whitelist;
    this.sessionAllow = Array.isArray(data.sessionAllow) ? data.sessionAllow : [];
    this.lastUpdatedAt = data.updatedAt;
    Log.info(`RuleStore ${tag} ${this.getCounts()}`);
  }

  private readFile(): RulesFile | null {
    try {
      if (!fs.accessSync(this.path)) {
        return null;
      }
      return JSON.parse(fs.readTextSync(this.path)) as RulesFile;
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`RuleStore read failed: code=${err.code}`);
      return null;
    }
  }

  /** 写盘并立即让本进程生效；版本号单调递增，跨毫秒也能区分 */
  private persist(data: RulesFile): void {
    const next: number = Math.max(Date.now(), this.lastUpdatedAt + 1);
    data.updatedAt = next;
    data.schemaVersion = SCHEMA_VERSION;
    let file: fs.File | null = null;
    try {
      const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
      file = fs.openSync(this.path, mode);
      fs.writeSync(file.fd, JSON.stringify(data));
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`RuleStore write failed: code=${err.code}`);
      return;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败无需处理
        }
      }
    }
    this.apply(data, 'written');
  }
}
