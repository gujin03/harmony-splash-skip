import fs from '@ohos.file.fs';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import type { DiagSnapshot, DiagRecord, DomainCount } from '../core/DiagStats';

/**
 * 诊断页（PRD FR-5）
 *
 * 数据来源：VPN 扩展进程节流写入的 `filesDir/diag.json`（跨进程只能走文件）。
 * 展示：计数与命中率、拦截 TopN、转发 TopN（用于发现漏拦）、最近 20 条查询。
 */

const DIAG_FILE: string = '/diag.json';

@Entry
@Component
struct Diagnostics {
  @State summary: string = '（尚未读取）';
  @State rateText: string = '';
  @State topBlocked: string[] = [];
  @State topForwarded: string[] = [];
  @State recent: string[] = [];
  @State msg: string = '';
  /** 场景提示（PRD R-13）：拦截 0 次时提示可能为自有广告，避免误判工具失效 */
  @State hintText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path: string = ctx.filesDir + DIAG_FILE;
      if (!fs.accessSync(path)) {
        this.msg = '暂无诊断快照：请先启动拦截并让应用产生一次 DNS 查询';
        this.summary = '（无数据）';
        return;
      }
      const text: string = fs.readTextSync(path);
      const snap = JSON.parse(text) as DiagSnapshot;
      const total: number = snap.block + snap.fwdOk + snap.fwdFail;
      const rate: number = total > 0 ? Math.round(snap.block * 100 / total) : 0;
      this.summary = `DNS 查询 ${snap.dns} · 拦截 ${snap.block} · 转发 ${snap.fwdOk} · 失败 ${snap.fwdFail}` +
        `\n过载 ${snap.overload} · 回写 ${snap.written} · 写错 ${snap.writeErr}`;
      this.rateText = `拦截占比 ${rate}%（共 ${total} 条已判定）`;
      this.msg = `快照时间：${this.fmtTime(snap.updatedAt)}`;

      this.hintText = this.buildHint(snap);
      this.topBlocked = this.fmtTop(snap.topBlocked);
      this.topForwarded = this.fmtTop(snap.topForwarded);
      this.recent = this.fmtRecent(snap.recent);
    } catch (e) {
      const err = e as BusinessError;
      this.msg = `读取失败：${err.code} ${err.message}`;
      Log.error(`read diag failed: ${err.code} ${err.message}`);
    }
  }

  /**
   * 场景提示（PRD R-13 / §3.4 E 级）。
   *
   * ⚠️ 快照是**会话累计**，不是按 App 分开——R-11 已确认 DNS 层拿不到请求方包名。
   * 所以这里只能说「本次会话」，不能说「该应用」。换 App 测试前应先停止再启动拦截以重置统计。
   */
  private buildHint(snap: DiagSnapshot): string {
    if (snap.dns === 0) {
      return '';
    }
    const judged: number = snap.block + snap.fwdOk + snap.fwdFail;
    if (judged === 0) {
      return '';
    }
    if (snap.block === 0) {
      return '本次会话未拦截到任何广告域名。三种可能：① 该应用用自有广告投放（素材和接口都在自有域，如平安好车主），DNS 方案覆盖不到（R-13）；② 广告素材已缓存；③ 规则没覆盖——先看下面「转发 Top10」有没有明显是广告的域名。\n换 App 测试请先停止拦截再启动，统计才会归零。';
    }
    const rate: number = Math.round(snap.block * 100 / judged);
    if (rate < 10) {
      return `拦截占比只有 ${rate}%，大部分查询是正常业务或被白名单放行。若该应用确有开屏广告，检查「转发 Top10」里是否有漏拦的广告域名。`;
    }
    return '';
  }

  private fmtTime(t: number): string {
    if (!t) {
      return '—';
    }
    const d = new Date(t);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }

  private fmtTop(list: DomainCount[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(`${list[i].count}  ${list[i].domain}`);
    }
    return out.length > 0 ? out : ['（暂无）'];
  }

  private fmtRecent(list: DiagRecord[]): string[] {
    const out: string[] = [];
    // 最新的放最前
    for (let i = list.length - 1; i >= 0; i--) {
      const r = list[i];
      const tag = r.a === 'block' ? '拦' : (r.a === 'fwd' ? '转' : '败');
      out.push(`${this.fmtTime(r.t)}  [${tag}] v${r.v}  ${r.q}  ${r.m}`);
    }
    return out.length > 0 ? out : ['（暂无）'];
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ top: 16, bottom: 6 })
  }

  @Builder
  lineList(items: string[], color: string) {
    ForEach(items, (item: string) => {
      Text(item)
        .fontSize(12)
        .fontColor(color)
        .width('100%')
        .margin({ bottom: 3 })
    }, (item: string, idx: number) => `${idx}-${item}`)
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(13)
          .height(32)
          .onClick(() => router.back())
        Blank()
        Button('刷新')
          .fontSize(13)
          .height(32)
          .onClick(() => this.load())
      }
      .width('100%')
      .margin({ bottom: 8 })

      Text('诊断')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .width('100%')

      Text(this.msg)
        .fontSize(11)
        .fontColor('#999999')
        .width('100%')
        .margin({ top: 4, bottom: 8 })

      Scroll() {
        Column() {
          Text(this.summary)
            .fontSize(13)
            .width('100%')

          Text(this.rateText)
            .fontSize(13)
            .fontColor('#2E6BE6')
            .width('100%')
            .margin({ top: 4 })

          if (this.hintText.length > 0) {
            Row() {
              Text(this.hintText)
                .fontSize(12)
                .fontColor('#8A5A00')
                .lineHeight(18)
                .width('100%')
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#FFF7E6')
            .border({ width: 1, color: '#FFD591' })
            .borderRadius(6)
            .margin({ top: 10 })
          }

          this.sectionTitle('拦截 Top10（命中规则）')
          this.lineList(this.topBlocked, '#B03030')

          this.sectionTitle('转发 Top10（未命中，可用于补规则）')
          this.lineList(this.topForwarded, '#666666')

          this.sectionTitle('最近 20 条查询')
          this.lineList(this.recent, '#333333')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding(20)
  }
}
