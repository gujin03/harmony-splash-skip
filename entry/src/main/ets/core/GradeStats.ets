/**
 * 效果分级统计（PRD §3.4 / FR-5.2 / §10-1）
 *
 * ⚠️ R-11：DNS 层拿不到请求方包名，无法自动归集。按 docs/开发差距分析.md 的建议，
 *    改为「手动选择本次测试 App 标签 + 人工判定 A/B/C/D/E」，由本模块做纯函数聚合。
 *
 * 分层口径：E（一方自有广告）**不计入分母**；第三方层分母 = A+B+C+D，
 * 验收 A+B ≥ 60%、D ≤ 20%。
 *
 * ⛔ 纯函数、零本地 import（供 node 单测直跑）。
 */

export const GRADE_A: string = 'A';
export const GRADE_B: string = 'B';
export const GRADE_C: string = 'C';
export const GRADE_D: string = 'D';
export const GRADE_E: string = 'E';
export const VALID_GRADES: Array<string> = [GRADE_A, GRADE_B, GRADE_C, GRADE_D, GRADE_E];
export const GRADE_FILE_VERSION: number = 1;

export interface GradeRecord {
  /** 展示名，如「车来了」 */
  app: string;
  /** 包名，作为聚合键 */
  bundle: string;
  grade: string;
  /** 记录时间戳（ms），由调用方传入 */
  at: number;
  note: string;
}

export interface GradeFile {
  version: number;
  records: Array<GradeRecord>;
}

export interface GradeSummary {
  app: string;
  bundle: string;
  grade: string;
  at: number;
  note: string;
}

export interface GradeStatsResult {
  /** 计入分母的样本数（排除 E） */
  denominator: number;
  ab: number;
  c: number;
  d: number;
  e: number;
  /** 百分比整数；分母为 0 时返回 0 */
  abRate: number;
  dRate: number;
  /** 是否达到 §10-1 的门槛（样本数 ≥3 时才判定，避免 1 款样本误判达标） */
  enoughSamples: boolean;
  passAb: boolean;
  passD: boolean;
}

export function isValidGrade(g: string): boolean {
  return VALID_GRADES.indexOf(g) >= 0;
}

/** 追加一条分级记录；历史全留，展示时按 bundle 取最新 */
export function upsertGrade(file: GradeFile, rec: GradeRecord): GradeFile {
  const out: Array<GradeRecord> = [];
  for (const r of file.records) {
    out.push(r);
  }
  out.push(rec);
  return { version: GRADE_FILE_VERSION, records: out };
}

/** 每个 App 取 at 最大的一条，按包名排序保证输出稳定 */
export function latestByApp(records: Array<GradeRecord>): Array<GradeSummary> {
  const m: Map<string, GradeRecord> = new Map();
  for (const r of records) {
    const prev = m.get(r.bundle);
    if (prev === undefined || r.at >= prev.at) {
      m.set(r.bundle, r);
    }
  }
  const out: Array<GradeSummary> = [];
  m.forEach((v: GradeRecord) => {
    out.push({
      app: v.app, bundle: v.bundle, grade: v.grade, at: v.at, note: v.note
    });
  });
  out.sort((a: GradeSummary, b: GradeSummary) => {
    return a.bundle < b.bundle ? -1 : (a.bundle > b.bundle ? 1 : 0);
  });
  return out;
}

export function summarizeGrades(records: Array<GradeRecord>): GradeStatsResult {
  const latest: Array<GradeSummary> = latestByApp(records);
  let ab: number = 0;
  let c: number = 0;
  let d: number = 0;
  let e: number = 0;
  for (const s of latest) {
    if (s.grade === GRADE_A || s.grade === GRADE_B) {
      ab++;
    } else if (s.grade === GRADE_C) {
      c++;
    } else if (s.grade === GRADE_D) {
      d++;
    } else if (s.grade === GRADE_E) {
      e++;
    }
  }
  const denominator: number = ab + c + d;
  const abRate: number = denominator > 0 ? Math.round(ab * 100 / denominator) : 0;
  const dRate: number = denominator > 0 ? Math.round(d * 100 / denominator) : 0;
  const enough: boolean = denominator >= 3;
  return {
    denominator: denominator,
    ab: ab,
    c: c,
    d: d,
    e: e,
    abRate: abRate,
    dRate: dRate,
    enoughSamples: enough,
    passAb: enough && abRate >= 60,
    passD: enough && dRate <= 20
  };
}

/** 分级说明，供 UI 展示 */
export function gradeLabel(g: string): string {
  if (g === GRADE_A) {
    return 'A｜直接进入';
  }
  if (g === GRADE_B) {
    return 'B｜超时后进入';
  }
  if (g === GRADE_C) {
    return 'C｜占位残留';
  }
  if (g === GRADE_D) {
    return 'D｜广告照常';
  }
  if (g === GRADE_E) {
    return 'E｜一方自有广告（不计入分母）';
  }
  return '未分级';
}
