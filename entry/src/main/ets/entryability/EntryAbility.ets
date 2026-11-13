import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import vpnExtension from '@ohos.net.vpnExtension';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

const BUNDLE_NAME: string = 'com.liuqi.splashskip';
const VPN_ABILITY: string = 'SkipVpnExtension';

/**
 * 应用入口。
 *
 * 除 loadContent 外还处理通知栏「停止拦截」按钮带来的 stop_vpn 意图（FR-6.1）：
 * WantAgent 拉起本 Ability 并带 parameters.action='stop_vpn'，这里直接停扩展，
 * 用户不必再回到应用点一次按钮。冷启动走 onCreate，App 已在后台则走 onNewWant，
 * ⚠️ 两条路径都必须覆盖，否则热启动下按钮会「点了没反应」。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    this.handleStopIntent(want);
  }

  onNewWant(want: Want): void {
    this.handleStopIntent(want);
  }

  private handleStopIntent(want: Want): void {
    const params = want.parameters;
    if (params === undefined || params['action'] !== 'stop_vpn') {
      return;
    }
    Log.info('notification stop button tapped');
    vpnExtension.stopVpnExtensionAbility({ bundleName: BUNDLE_NAME, abilityName: VPN_ABILITY })
      .then(() => {
        Log.info('stop from notification ok');
      })
      .catch((e: BusinessError) => {
        Log.error(`stop from notification failed: code=${e.code} msg=${e.message}`);
      });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Log.error(`loadContent failed code=${err.code} msg=${err.message}`);
        return;
      }
      Log.info('loadContent ok');
    });
  }
}
