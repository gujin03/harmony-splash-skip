import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'SplashSkip';

/**
 * 统一日志出口。真机用 `hdc hilog | grep SplashSkip` 观察。
 * 所有 PoC 结论都打点成 V1..V5 / PASS / FAIL，便于逐项判读。
 */
export class Log {
  static info(msg: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }
}
