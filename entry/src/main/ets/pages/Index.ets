import vpnExtension from '@ohos.net.vpnExtension';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

/**
 * PoC 主界面（PRD v0.3.0 §9.1）。
 *
 * 方案：本地 VPN + DNS 拦截。当前处于「观察模式」——
 * 只从 TUN 读包并解析出一条 DNS 查询就销毁，不拦截、不转发，
 * 用于验证 V1（建 TUN）/ V2（读原始包）/ V3（解析 DNS）。
 *
 * ⚠️ 无障碍点击路线已按 PRD D9 整体移除（API 20+ 被 system_basic 锁死）。
 */
@Entry
@Component
struct Index {
  @State vpnState: string = '未启动';

  private startVpn(): void {
    this.vpnState = '正在启动…';
    vpnExtension.startVpnExtensionAbility({
      bundleName: 'com.liuqi.splashskip',
      abilityName: 'SkipVpnExtension'
    }).then(() => {
      this.vpnState = '已启动（抓到 1 条 DNS 后自动停止）';
      Log.info('startVpnExtensionAbility ok');
    }).catch((e: BusinessError) => {
      this.vpnState = `启动失败：${e.code}`;
      Log.error(`startVpnExtensionAbility failed: ${e.code} ${e.message}`);
    });
  }

  build() {
    Column() {
      Text('开屏广告拦截 · PoC')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 8 })

      Text('PRD v0.3.0 §9.1 · 本地 VPN + DNS 拦截')
        .fontSize(14)
        .fontColor('#666666')
        .margin({ bottom: 20 })

      Text('已完成验证')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })

      Text('V1 建立 TUN 并取得 fd\nV2 从 TUN 读到原始 IP 包\nV3 解析出 DNS 查询域名')
        .fontSize(14)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 10 })

      Text('当前为观察模式：只抓 1 条 DNS 就停，不拦截、不转发')
        .fontSize(13)
        .fontColor('#B26A00')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 22 })

      Divider().margin({ bottom: 18 })

      Button('启动 VPN（抓 1 条 DNS 后自动恢复）')
        .onClick(() => this.startVpn())
        .margin({ bottom: 10 })

      Text(this.vpnState)
        .fontSize(13)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 22 })

      Divider().margin({ bottom: 18 })

      Text('下一步（MVP，待实现）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })

      Text('V4 命中黑名单返回 NXDOMAIN\nV5 未命中转发上游并回写\nV6 protect(socket) 防回环')
        .fontSize(13)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })

      Text('hdc shell hilog -T SplashSkip -x')
        .fontSize(13)
        .fontColor('#2E6BE6')
        .margin({ bottom: 4 })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
