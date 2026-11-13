/**
 * 诊断统计聚合（无 IO、无 @ohos 依赖，可在本机 node 上测）
 *
 * 契约见 docs/ADR-001-DNS拦截架构决策.md AD-3。
 *
 * 设计要点：
 *   1. 时间戳由调用方传入（本模块不读时钟），保证可复现测试
 *   2. recent 固定长度环形覆盖，避免内存无上限增长
 *   3. TopN 用 Map 计数 + 排序取前 N（规则量级小，不必上堆）
 *   4. snapshot() 产出可 JSON.stringify 的纯数据，供扩展进程写文件 / UI 读取
 */

export interface DiagRecord {
  /** 时间戳（ms），由调用方提供 */
  t: number;
  /** 查询域名 */
  q: string;
  /** 'block' | 'fwd' | 'fail' */
  a: string;
  /** 命中原因／规则说明 */
  m: string;
  /** IP 版本 4 | 6 */
  v: number;
}

export interface DomainCount {
  domain: string;
  count: number;
}

export interface DiagSnapshot {
  updatedAt: number;
  dns: number;
  block: number;
  fwdOk: number;
  fwdFail: number;
  overload: number;
  written: number;
  writeErr: number;
  recent: DiagRecord[];
  topBlocked: DomainCount[];
  topForwarded: DomainCount[];
}

export const ACTION_BLOCK: string = 'block';
export const ACTION_FWD: string = 'fwd';
export const ACTION_FAIL: string = 'fail';

const RECENT_MAX: number = 20;
const TOPN: number = 10;

export class DiagStats {
  private dns: number = 0;
  private block: number = 0;
  private fwdOk: number = 0;
  private fwdFail: number = 0;
  private overload: number = 0;
  private written: number = 0;
  private writeErr: number = 0;

  private recent: DiagRecord[] = [];
  private blockMap: Map<string, number> = new Map();
  private fwdMap: Map<string, number> = new Map();

  bumpDns(): void {
    this.dns++;
  }

  getDns(): number {
    return this.dns;
  }

  getBlock(): number {
    return this.block;
  }

  getFwdOk(): number {
    return this.fwdOk;
  }

  getFwdFail(): number {
    return this.fwdFail;
  }

  bumpWritten(): void {
    this.written++;
  }

  bumpWriteErr(): void {
    this.writeErr++;
  }

  bumpOverload(): void {
    this.overload++;
  }

  /** 记录一条查询结果；action 用 ACTION_* 常量 */
  record(t: number, qname: string, action: string, reason: string, ver: number): void {
    if (action === ACTION_BLOCK) {
      this.block++;
      this.incMap(this.blockMap, qname);
    } else if (action === ACTION_FWD) {
      this.fwdOk++;
      this.incMap(this.fwdMap, qname);
    } else if (action === ACTION_FAIL) {
      this.fwdFail++;
    }
    const rec: DiagRecord = { t: t, q: qname, a: action, m: reason, v: ver };
    this.recent.push(rec);
    if (this.recent.length > RECENT_MAX) {
      this.recent.shift();
    }
  }

  private incMap(m: Map<string, number>, key: string): void {
    const prev = m.get(key);
    m.set(key, prev === undefined ? 1 : prev + 1);
  }

  private topOf(m: Map<string, number>): DomainCount[] {
    const all: DomainCount[] = [];
    m.forEach((v: number, k: string) => {
      all.push({ domain: k, count: v });
    });
    // 计数降序；同计数按域名升序，保证输出稳定可测
    all.sort((a: DomainCount, b: DomainCount) => {
      if (b.count !== a.count) {
        return b.count - a.count;
      }
      return a.domain < b.domain ? -1 : (a.domain > b.domain ? 1 : 0);
    });
    return all.length > TOPN ? all.slice(0, TOPN) : all;
  }

  snapshot(now: number): DiagSnapshot {
    return {
      updatedAt: now,
      dns: this.dns,
      block: this.block,
      fwdOk: this.fwdOk,
      fwdFail: this.fwdFail,
      overload: this.overload,
      written: this.written,
      writeErr: this.writeErr,
      recent: this.recent.slice(0),
      topBlocked: this.topOf(this.blockMap),
      topForwarded: this.topOf(this.fwdMap)
    };
  }
}
