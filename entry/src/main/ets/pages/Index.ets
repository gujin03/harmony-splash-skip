import vpnExtension from '@ohos.net.vpnExtension';
import notificationManager from '@ohos.notificationManager';
import common from '@ohos.app.ability.common';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { readVpnState } from '../common/VpnState';
import { startPause, clearPause, readPause } from '../common/PauseState';
import { isOnboarded, markOnboarded } from '../common/OnboardState';

/**
 * 主界面（PRD v0.3.0 / FR-6 / FR-7 / FR-8.2）
 *
 *  - 启动／停止拦截；通知栏常驻通知也带停止按钮（意图由 EntryAbility 处理）
 *  - FR-7.1 状态读扩展写下的共享 vpn_state.json，3 秒轮询对齐真相源
 *  - FR-7.2/7.3 首次启动说明（接管 DNS／可随时关闭／不上传／VPN 互斥）
 *  - FR-8.2 暂停 10 分钟：截止时间写文件，到点由轮询自动恢复
 *  - 规则管理、效果分级两个入口
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
  @State pauseText: string = '';
  @State guideMsg: string = '';
  @State showOnboard: boolean = false;
  /** 状态文件轮询：通知中心是系统 overlay，从通知栏停止不会触发 onPageShow */
  private stateTimer: number = -1;

  aboutToAppear(): void {
    this.refreshVpnState();
    this.refreshNotifyState();
    const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
    this.showOnboard = !isOnboarded(ctx.filesDir);
    // 每 3 秒对齐跨进程真相源与暂停截止时间；文件都很小，代价可忽略
    this.stateTimer = setInterval(() => {
      this.refreshVpnState();
      this.checkPause();
    }, 3000);
  }

  aboutToDisappear(): void {
    if (this.stateTimer >= 0) {
      clearInterval(this.stateTimer);
      this.stateTimer = -1;
    }
  }

  onPageShow(): void {
    this.refreshVpnState();
    this.checkPause();
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext()! as common.UIAbilityContext;
  }

  /** 读共享状态文件；杀掉 App 再打开、或扩展创建失败，都显示真实状态 */
  private refreshVpnState(): void {
    try {
      const s = readVpnState(this.ctx().filesDir);
      if (s === null) {
        return;
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

  private refreshNotifyState(): void {
    notificationManager.isNotificationEnabled()
      .then((enabled: boolean) => {
        this.notifyState = enabled ? '已开启' : '未开启';
      })
      .catch((e: BusinessError) => {
        Log.error(`isNotificationEnabled failed: ${e.code}`);
      });
  }

  /** FR-8.2：到点自动恢复；即使 App 中途被杀，下次打开也会按截止时间补恢复 */
  private checkPause(): void {
    const p = readPause(this.ctx().filesDir);
    if (p === null || p.until <= 0) {
      if (this.pauseText.indexOf('暂停') >= 0) {
        this.pauseText = '';
      }
      return;
    }
    const now: number = Date.now();
    if (now >= p.until) {
      clearPause(this.ctx().filesDir);
      this.pauseText = '暂停结束，正在自动恢复拦截…';
      this.guideMsg = '';
      this.startVpn();
      return;
    }
    const left: number = Math.ceil((p.until - now) / 60000);
    this.pauseText = `已暂停，剩余约 ${left} 分钟（保持应用在前台会自动恢复）`;
  }

  private buildWant(): Want {
    return { bundleName: BUNDLE, abilityName: ABILITY };
  }

  private startVpn(): void {
    clearPause(this.ctx().filesDir);
    this.pauseText = '';
    this.guideMsg = '';
    this.vpnState = '正在启动…';
    vpnExtension.startVpnExtensionAbility(this.buildWant()).then(() => {
      this.vpnState = '运行中（拦截广告域名，其余正常转发）';
      Log.info('startVpnExtensionAbility ok');
      setTimeout(() => {
        this.refreshVpnState();
      }, 800);
    }).catch((e: BusinessError) => {
      // FR-7.3：系统同时只允许一个 VPN，启动失败时给出可操作提示
      this.vpnState = `启动失败：${e.code}`;
      this.guideMsg = `启动失败（${e.code}）：系统同时只允许一个 VPN，请检查是否有其它 VPN 正在运行；也可能是上次连接尚未释放，稍后重试。`;
      Log.error(`startVpnExtensionAbility failed: ${e.code} ${e.message}`);
    });
  }

  private stopVpn(): void {
    clearPause(this.ctx().filesDir);
    this.pauseText = '';
    this.vpnState = '正在停止…';
    vpnExtension.stopVpnExtensionAbility(this.buildWant()).then(() => {
      this.vpnState = '已停止';
      Log.info('stopVpnExtensionAbility ok');
      setTimeout(() => {
        this.refreshVpnState();
      }, 500);
      notificationManager.cancel(1001).catch((err: BusinessError) => {
        if (err.code !== 1600007) {
          Log.error(`cancel notify failed: code=${err.code}`);
        }
      });
    }).catch((e: BusinessError) => {
      this.vpnState = `停止失败：${e.code}`;
      Log.error(`stopVpnExtensionAbility failed: ${e.code} ${e.message}`);
    });
  }

  private pauseTenMinutes(): void {
    startPause(this.ctx().filesDir, 10, Date.now());
    vpnExtension.stopVpnExtensionAbility(this.buildWant()).catch((e: BusinessError) => {
      Log.info(`pause stop (may not be running): ${e.code}`);
    });
    this.vpnState = '已暂停';
    this.guideMsg = '';
    this.checkPause();
    Log.info('pause 10 minutes');
  }

  private async requestNotify(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
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

  private goPage(url: string): void {
    this.getUIContext().getRouter().pushUrl({ url: url }).catch((err: BusinessError) => {
      Log.error(`push ${url} failed: ${err.code}`);
    });
  }

  build() {
    Stack() {
      Column() {
        Text('开屏广告拦截')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 6 })

        Text('本地 VPN + DNS 拦截 · PRD v0.3.0')
          .fontSize(13)
          .fontColor('#666666')
          .margin({ bottom: 16 })

        Text('运行状态')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 6 })

        Text(this.vpnState)
          .fontSize(14)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 6 })

        if (this.pauseText.length > 0) {
          Text(this.pauseText)
            .fontSize(12)
            .fontColor('#B03030')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 6 })
        }

        if (this.guideMsg.length > 0) {
          Text(this.guideMsg)
            .fontSize(11)
            .fontColor('#8A5A00')
            .width('100%')
            .padding(8)
            .backgroundColor('#FFF7E6')
            .border({ width: 1, color: '#FFD591' })
            .borderRadius(6)
            .margin({ bottom: 8 })
        }

        Button('启动拦截')
          .width('70%')
          .onClick(() => this.startVpn())
          .margin({ bottom: 10 })

        Button('停止拦截')
          .width('70%')
          .backgroundColor('#B03030')
          .onClick(() => this.stopVpn())
          .margin({ bottom: 10 })

        Button('暂停 10 分钟（临时看广告／领奖励）')
          .width('70%')
          .fontSize(13)
          .backgroundColor('#8A6A20')
          .onClick(() => this.pauseTenMinutes())
          .margin({ bottom: 16 })

        Divider().margin({ bottom: 12 })

        Row() {
          Button('查看诊断')
            .fontSize(11)
            .height(34)
            .layoutWeight(1)
            .backgroundColor('#4A6FA5')
            .onClick(() => this.goPage('pages/Diagnostics'))
          Button('规则管理')
            .fontSize(11)
            .height(34)
            .layoutWeight(1)
            .margin({ left: 6 })
            .backgroundColor('#4A6FA5')
            .onClick(() => this.goPage('pages/Rules'))
          Button('效果分级')
            .fontSize(11)
            .height(34)
            .layoutWeight(1)
            .margin({ left: 6 })
            .backgroundColor('#4A6FA5')
            .onClick(() => this.goPage('pages/Grades'))
        }
        .width('90%')
        .margin({ bottom: 14 })

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
        .margin({ bottom: 14 })

        Text('日志：hdc shell hilog -T SplashSkip -x')
          .fontSize(12)
          .fontColor('#2E6BE6')
          .margin({ bottom: 6 })

        Text('运行时接管 DNS，点「停止拦截」或通知栏按钮立即恢复')
          .fontSize(12)
          .fontColor('#999999')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding(20)
      .justifyContent(FlexAlign.Center)

      // FR-7.2 / FR-7.3：首次启动说明，只显示一次
      if (this.showOnboard) {
        Column() {
          Text('开始前请了解')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 12 })

          Text('· 本工具通过本地 VPN 接管 DNS，只在本机比对域名，不解密 HTTPS、不采集内容、不上传任何数据。')
            .fontSize(13)
            .width('100%')
            .margin({ bottom: 8 })
          Text('· 系统同时只允许一个 VPN。若已有其它 VPN 在运行，本工具会启动失败；请先关闭对方。')
            .fontSize(13)
            .width('100%')
            .margin({ bottom: 8 })
          Text('· 随时可点应用内「停止拦截」，或展开通知栏点「停止拦截」，网络立即恢复。')
            .fontSize(13)
            .width('100%')
            .margin({ bottom: 8 })
          Text('· 一方自有广告（素材与投放都在 App 自有域）无法用 DNS 拦掉，属于方案边界。')
            .fontSize(13)
            .width('100%')
            .margin({ bottom: 16 })

          Button('我知道了')
            .width('100%')
            .height(40)
            .onClick(() => {
              markOnboarded(this.ctx().filesDir);
              this.showOnboard = false;
            })
        }
        .width('88%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .border({ width: 1, color: '#DDDDDD' })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.showOnboard ? '#66000000' : '#FFFFFF')
  }
}
