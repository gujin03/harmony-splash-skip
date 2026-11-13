/**
 * 「暂停 10 分钟」状态（FR-8.2）
 *
 * ⚠️ 不用 setTimeout 做自动恢复：应用被系统回收后定时器不可靠（与已移除的 AUTO_STOP 同理）。
 * 改为把截止时间写进沙箱文件，由首页 3 秒轮询检测；到点自动重新拉起 VPN。
 * 即使 App 中途被杀，下次打开也能按截止时间补恢复。
 */

import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Logger';

export interface PauseInfo {
  /** 恢复时刻（ms 时间戳）；0 表示未暂停 */
  until: number;
  startedAt: number;
}

const PAUSE_FILE: string = '/pause.json';

function write(filesDir: string, info: PauseInfo): void {
  const path: string = filesDir + PAUSE_FILE;
  let file: fs.File | null = null;
  try {
    const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
    file = fs.openSync(path, mode);
    fs.writeSync(file.fd, JSON.stringify(info));
  } catch (e) {
    const err = e as BusinessError;
    Log.error(`write pause failed: code=${err.code}`);
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

export function startPause(filesDir: string, minutes: number, now: number): void {
  write(filesDir, { until: now + minutes * 60 * 1000, startedAt: now });
}

export function clearPause(filesDir: string): void {
  write(filesDir, { until: 0, startedAt: 0 });
}

export function readPause(filesDir: string): PauseInfo | null {
  const path: string = filesDir + PAUSE_FILE;
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    return JSON.parse(fs.readTextSync(path)) as PauseInfo;
  } catch (e) {
    const err = e as BusinessError;
    Log.error(`read pause failed: code=${err.code}`);
    return null;
  }
}
