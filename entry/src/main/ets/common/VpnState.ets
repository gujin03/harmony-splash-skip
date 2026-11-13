/**
 * 跨进程共享的 VPN 真实状态（FR-7.1）
 *
 * 扩展进程与 UI 进程内存不共享，只有应用沙箱文件是共同真相源
 * （diag.json 已在真机验证这条通路可用）。
 *  - 扩展 startVpn 成功 → running=true
 *  - 扩展 stopVpn / create 失败 → running=false + reason
 *  - 首页每次 onPageShow 读它，不再用「按钮点过没有」当状态
 */

import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Logger';

export interface VpnStateInfo {
  running: boolean;
  startedAt: number;
  reason: string;
  /** 扩展创建失败时的错误码，0 表示无异常 */
  errCode: number;
}

const STATE_FILE: string = '/vpn_state.json';

export function writeVpnState(filesDir: string, state: VpnStateInfo): void {
  const path: string = filesDir + STATE_FILE;
  let file: fs.File | null = null;
  try {
    const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
    file = fs.openSync(path, mode);
    fs.writeSync(file.fd, JSON.stringify(state));
  } catch (e) {
    const err = e as BusinessError;
    Log.error(`write vpn_state failed: code=${err.code}`);
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

export function readVpnState(filesDir: string): VpnStateInfo | null {
  const path: string = filesDir + STATE_FILE;
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    const text: string = fs.readTextSync(path);
    return JSON.parse(text) as VpnStateInfo;
  } catch (e) {
    const err = e as BusinessError;
    Log.error(`read vpn_state failed: code=${err.code}`);
    return null;
  }
}
