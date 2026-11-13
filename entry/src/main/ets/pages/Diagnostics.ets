import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { RuleStore } from '../config/RuleStore';
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
  @State topBlocked: DomainCount[] = [];
  @State topForwarded: DomainCount[] = [];
  @State recent: string[] = [];
  @State msg: string = '';
  /** 场景提示（PRD R-13）：拦截 0 次时提示可能为自有广告，避免误判工具失效 */
  @State hintText: string = '';
  /** FR-8.3：本次放行域名输入与回显 */
  @State allowInput: string = '';
  @State allowMsg: string = '';
  /** FR-5.4：TopN 一键加黑回显 */
  @State topMsg: string = '';

  aboutToAppear(): void {
    this.load();
  }

  /**
   * FR-8.3 / §10-5：误伤兜底。
   * 写进 rules.json 的 sessionAllow，扩展下一次查询即生效（RuleStore 热重载），
   * 不需重启 VPN、不需重新编译装机；停 VPN 时由扩展清空。
   */
  private addAllow(): void {
    const host: string = this.allowInput.trim();
    if (host.length === 0) {
      this.allowMsg = '请先输入域名';
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
      const store = new RuleStore(ctx.filesDir);
      store.init();
      store.addSessionAllow(host);
      this.allowMsg = `已放行 ${host}（仅本次会话，停 VPN 后清除）`;
      this.allowInput = '';
    } catch (e) {
      const err = e as BusinessError;
      this.allowMsg = `放行失败：${err.code}`;
      Log.error(`addSessionAllow failed: ${err.code}`);
    }
  }

  private load(): void {
    try {
      const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
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
      // 旧快照可能没有新增字段，用 truthy 兜底避免显示 undefined
      const reads: number = snap.reads ? snap.reads : 0;
      const v4: number = snap.v4 ? snap.v4 : 0;
      const v6: number = snap.v6 ? snap.v6 : 0;
      const dohLike: number = snap.dohLike ? snap.dohLike : 0;
      this.summary = `DNS 查询 ${snap.dns} · 拦截 ${snap.block} · 转发 ${snap.fwdOk} · 失败 ${snap.fwdFail}` +
        `\n收包 ${reads}（v4 ${v4} / v6 ${v6}）· 疑似加密 DNS ${dohLike}` +
        `\n过载 ${snap.overload} · 回写 ${snap.written} · 写错 ${snap.writeErr}`;
      this.rateText = `拦截占比 ${rate}%（共 ${total} 条已判定）`;
      this.msg = `快照时间：${this.fmtTime(snap.updatedAt)}`;

      this.hintText = this.buildHint(snap);
      this.topBlocked = snap.topBlocked;
      this.topForwarded = snap.topForwarded;
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
      return '本次会话尚未捕获到任何 DNS 查询。若目标 App 确实在联网，可能走了系统 resolver 或加密 DNS（DoT／DoH／HTTPDNS），53 端口流量没进 TUN（R-12 / FR-8.1）。';
    }
    const dohLike: number = snap.dohLike ? snap.dohLike : 0;
    if (dohLike > 0) {
      return `检测到 ${dohLike} 个疑似加密 DNS 包（UDP 853／443）。该 App 可能使用 DoT／DoH 或 QUIC，部分广告请求不走 53 端口，DNS 拦截覆盖不到（FR-8.1 / R-12）。`;
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

  /** FR-5.4：把「转发 Top10」里的一条直接加进黑名单，扩展下一次查询即生效 */
  private addBlackFromTop(host: string): void {
    const h: string = host.trim();
    if (h.length === 0 || h === '（暂无）') {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
      const store = new RuleStore(ctx.filesDir);
      store.init();
      const done: boolean = store.addBlacklistDomain(h, '诊断页 TopN 一键加黑');
      this.topMsg = done
        ? `已加入黑名单：${h}（下一次查询生效，无需重启 VPN）`
        : `规则已存在：${h}`;
    } catch (e) {
      const err = e as BusinessError;
      this.topMsg = `加黑失败：${err.code}`;
      Log.error(`addBlackFromTop failed: ${err.code}`);
    }
  }

  private fmtTime(t: number): string {
    if (!t) {
      return '—';
    }
    const d = new Date(t);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }

  private fmtTopLine(c: DomainCount): string {
    return `${c.count}  ${c.domain}`;
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

  /** 可点击的 TopN 列表；canAdd=true 时每行带「加黑」按钮（直接拿原始 domain，不反解字符串） */
  @Builder
  topList(items: DomainCount[], color: string, canAdd: boolean) {
    if (items.length === 0) {
      Text('（暂无）')
        .fontSize(12)
        .fontColor(color)
        .width('100%')
        .margin({ bottom: 3 })
    } else {
      ForEach(items, (item: DomainCount) => {
        Row() {
          Text(this.fmtTopLine(item))
            .fontSize(12)
            .fontColor(color)
            .layoutWeight(1)
          if (canAdd) {
            Button('加黑')
              .fontSize(10)
              .height(26)
              .backgroundColor('#B03030')
              .onClick(() => this.addBlackFromTop(item.domain))
          }
        }
        .width('100%')
        .margin({ bottom: 3 })
      }, (item: DomainCount, idx: number) => `${idx}-${item.domain}-${item.count}`)
    }
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
          .onClick(() => this.getUIContext().getRouter().back())
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

          Row() {
            TextInput({ placeholder: '误拦域名，本次放行' })
              .layoutWeight(1)
              .height(38)
              .fontSize(12)
              .onChange((v: string) => {
                this.allowInput = v;
              })
            Button('放行')
              .fontSize(12)
              .height(38)
              .margin({ left: 8 })
              .onClick(() => this.addAllow())
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.allowMsg.length > 0) {
            Text(this.allowMsg)
              .fontSize(11)
              .fontColor('#2E6BE6')
              .width('100%')
              .margin({ top: 4 })
          }

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
          this.topList(this.topBlocked, '#B03030', false)

          this.sectionTitle('转发 Top10（未命中，可一键加黑）')
          this.topList(this.topForwarded, '#666666', true)

          if (this.topMsg.length > 0) {
            Text(this.topMsg)
              .fontSize(11)
              .fontColor('#2E6BE6')
              .width('100%')
              .margin({ top: 4 })
          }

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
