/**
 * 效果分级记录持久化（FR-5.2 / §10-1）
 *
 * 数据落在 filesDir/grades.json，聚合逻辑全部委托给纯函数 core/GradeStats，
 * 便于本机 node 直接单测（见 test/grade-stats.test.ts）。
 */

import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  upsertGrade,
  latestByApp,
  summarizeGrades,
  GRADE_FILE_VERSION
} from '../core/GradeStats';
import type { GradeFile, GradeRecord, GradeSummary, GradeStatsResult } from '../core/GradeStats';
import { Log } from '../common/Logger';

const GRADE_FILE: string = '/grades.json';

export class GradeStore {
  private path: string;

  constructor(filesDir: string) {
    this.path = filesDir + GRADE_FILE;
  }

  all(): GradeFile {
    return this.read();
  }

  add(app: string, bundle: string, grade: string, note: string, at: number): void {
    const rec: GradeRecord = {
      app: app, bundle: bundle, grade: grade, at: at, note: note
    };
    const next: GradeFile = upsertGrade(this.read(), rec);
    this.write(next);
    Log.info(`GradeStore + ${app} ${grade}`);
  }

  latest(): Array<GradeSummary> {
    return latestByApp(this.read().records);
  }

  stats(): GradeStatsResult {
    return summarizeGrades(this.read().records);
  }

  private read(): GradeFile {
    try {
      if (!fs.accessSync(this.path)) {
        return { version: GRADE_FILE_VERSION, records: [] };
      }
      const f = JSON.parse(fs.readTextSync(this.path)) as GradeFile;
      if (!Array.isArray(f.records)) {
        return { version: GRADE_FILE_VERSION, records: [] };
      }
      return f;
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`GradeStore read failed: code=${err.code}`);
      return { version: GRADE_FILE_VERSION, records: [] };
    }
  }

  private write(data: GradeFile): void {
    let file: fs.File | null = null;
    try {
      const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
      file = fs.openSync(this.path, mode);
      fs.writeSync(file.fd, JSON.stringify(data));
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`GradeStore write failed: code=${err.code}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败无需处理
        }
      }
    }
  }
}
