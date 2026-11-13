import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'SplashSkip';

/**
 * 统一日志出口。真机用 `hdc hilog | grep SplashSkip` 观察。
 * 所有 PoC 结论都打点成 V1..V5 / PASS / FAIL，便于逐项判读。
 */
export class Log {
  // ⚠️ 全部用 %{private}s：日志内容含 DNS 域名／IP 等浏览元数据（个人信息），
  //    标记 private 后普通读日志方看不到，开发者仍可用 `hilog -p off` 查看（隐私合规）。
  static info(msg: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{private}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{private}s', msg);
  }

  static error(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{private}s', msg);
  }
}
