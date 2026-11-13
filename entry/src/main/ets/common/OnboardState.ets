/**
 * 首次启动引导标记（FR-7.2 / FR-7.3）
 * 只显示一次：写 filesDir/onboarded.json，卸载重装后重新提示。
 */

import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Logger';

const ONBOARD_FILE: string = '/onboarded.json';

export function isOnboarded(filesDir: string): boolean {
  try {
    return fs.accessSync(filesDir + ONBOARD_FILE);
  } catch (e) {
    return false;
  }
}

export function markOnboarded(filesDir: string): void {
  const path: string = filesDir + ONBOARD_FILE;
  let file: fs.File | null = null;
  try {
    const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
    file = fs.openSync(path, mode);
    fs.writeSync(file.fd, JSON.stringify({ done: true, at: Date.now() }));
  } catch (e) {
    const err = e as BusinessError;
    Log.error(`mark onboarded failed: code=${err.code}`);
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
