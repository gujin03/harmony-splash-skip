import vpnExtension from '@ohos.net.vpnExtension';
import notificationManager from '@ohos.notificationManager';
import common from '@ohos.app.ability.common';
import { Want } from '@kit.AbilityKit';
import router from '@ohos.router';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { readVpnState } from '../common/VpnState';

/**
 * 主界面（PRD v0.3.0 / FR-6 / FR-7）
 *
 * 方案：本地 VPN + DNS 拦截。
 *  - 「启动拦截」拉起 SkipVpnExtension，拦截开屏广告域名并转发其余查询
 *  - 「停止拦截」调用 stopVpnExtensionAbility
 *  - 通知栏常驻通知也带「停止拦截」按钮（FR-6.1），意图由 EntryAbility 处理
 *  - FR-7.1：状态读扩展写下的共享文件 vpn_state.json，不再用「按钮点过没有」当状态
 *
 * ⚠️ 无障碍点击路线已按 PRD D9 整体移除。
 */

const BUNDLE: string = 'com.liuqi.splashskip';
const ABILITY: string = 'SkipVpnExtension';

@Entry
@Component
struct Index {
  @State vpnState: string = '未启动';
  @State notifyState: string = '未开启';
  /** 状态文件轮询：通知中心是系统 overlay，从通知栏停止不会触发 onPageShow */
  private stateTimer: number = -1;

  aboutToAppear(): void {
    this.refreshVpnState();
    this.refreshNotifyState();
    // 每 3 秒对齐一次跨进程真相源；文件约 100 字节，代价可忽略
    this.stateTimer = setInterval(() => {
      this.refreshVpnState();
    }, 3000);
  }

  /** 权限状态也要读真相，别让初始值「未开启」骗人（通知实际可能早已授权） */
  private refreshNotifyState(): void {
    notificationManager.isNotificationEnabled()
      .then((enabled: boolean) => {
        this.notifyState = enabled ? '已开启' : '未开启';
      })
      .catch((e: BusinessError) => {
        Log.error(`isNotificationEnabled failed: ${e.code}`);
      });
  }

  aboutToDisappear(): void {
    if (this.stateTimer >= 0) {
      clearInterval(this.stateTimer);
      this.stateTimer = -1;
    }
  }

  onPageShow(): void {
    this.refreshVpnState();
  }

  /**
   * 读共享状态文件（跨进程真相源）。
   * 杀掉 App 再打开、或扩展创建失败，都能显示真实状态而不是一律「未启动」。
   */
  private refreshVpnState(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const s = readVpnState(ctx.filesDir);
      if (s === null) {
        return;   // 从未启动过，保持初始「未启动」
      }
      if (s.running) {
        this.vpnState = '运行中（拦截广告域名，其余正常转发）';
      } else if (s.errCode !== 0) {
        this.vpnState = `异常：VPN 启动失败（${s.errCode}）`;
      } else {
        this.vpnState = '已停止';
      }
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`refreshVpnState failed: code=${err.code}`);
    }
  }

  private buildWant(): Want {
    return { bundleName: BUNDLE, abilityName: ABILITY };
  }

  private startVpn(): void {
    this.vpnState = '正在启动…';
    vpnExtension.startVpnExtensionAbility(this.buildWant()).then(() => {
      this.vpnState = '运行中（拦截广告域名，其余正常转发）';
      Log.info('startVpnExtensionAbility ok');
      // 扩展异步写状态文件，稍后按真相源校正（启动失败会写 errCode）
      setTimeout(() => {
        this.refreshVpnState();
      }, 800);
    }).catch((e: BusinessError) => {
      this.vpnState = `启动失败：${e.code}`;
      Log.error(`startVpnExtensionAbility failed: ${e.code} ${e.message}`);
    });
  }

  private stopVpn(): void {
    this.vpnState = '正在停止…';
    vpnExtension.stopVpnExtensionAbility(this.buildWant()).then(() => {
      this.vpnState = '已停止';
      Log.info('stopVpnExtensionAbility ok');
      setTimeout(() => {
        this.refreshVpnState();
      }, 500);
      // 补偿取消：扩展进程可能来不及取消就被回收，主进程兜一层
      notificationManager.cancel(1001).catch((err: BusinessError) => {
        // 1600007 = 通知不存在：扩展侧通常已取消成功，属正常情况
        if (err.code !== 1600007) {
          Log.error(`cancel notify failed: code=${err.code}`);
        }
      });
    }).catch((e: BusinessError) => {
      this.vpnState = `停止失败：${e.code}`;
      Log.error(`stopVpnExtensionAbility failed: ${e.code} ${e.message}`);
    });
  }

  private async requestNotify(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await notificationManager.requestEnableNotification(ctx);
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      this.notifyState = enabled ? '已开启' : '未开启';
      Log.info(`requestEnableNotification done, enabled=${enabled}`);
    } catch (e) {
      const err = e as BusinessError;
      this.notifyState = `申请失败：${err.code}`;
      Log.error(`requestEnableNotification failed: ${err.code} ${err.message}`);
    }
  }

  build() {
    Column() {
      Text('开屏广告拦截')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 6 })

      Text('本地 VPN + DNS 拦截 · PRD v0.3.0')
        .fontSize(13)
        .fontColor('#666666')
        .margin({ bottom: 18 })

      Text('运行状态')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 6 })

      Text(this.vpnState)
        .fontSize(14)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 18 })

      Button('启动拦截')
        .width('70%')
        .onClick(() => this.startVpn())
        .margin({ bottom: 10 })

      Button('停止拦截')
        .width('70%')
        .backgroundColor('#B03030')
        .onClick(() => this.stopVpn())
        .margin({ bottom: 20 })

      Divider().margin({ bottom: 16 })

      Button('查看诊断')
        .width('70%')
        .backgroundColor('#4A6FA5')
        .onClick(() => {
          router.pushUrl({ url: 'pages/Diagnostics' }).catch((err: BusinessError) => {
            Log.error(`push Diagnostics failed: ${err.code}`);
          });
        })
        .margin({ bottom: 18 })

      Row() {
        Text(`通知权限：${this.notifyState}`)
          .fontSize(13)
          .fontColor('#666666')
          .layoutWeight(1)
        Button('开启')
          .fontSize(12)
          .height(30)
          .onClick(() => this.requestNotify())
      }
      .width('80%')
      .margin({ bottom: 18 })

      Text('日志：hdc shell hilog -T SplashSkip -x')
        .fontSize(12)
        .fontColor('#2E6BE6')
        .margin({ bottom: 6 })

      Text('运行时会接管 DNS，点「停止拦截」或通知栏按钮立即恢复')
        .fontSize(12)
        .fontColor('#999999')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
