import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { GradeStore } from '../config/GradeStore';
import {
  GRADE_A,
  GRADE_B,
  GRADE_C,
  GRADE_D,
  GRADE_E,
  gradeLabel
} from '../core/GradeStats';

/**
 * 效果分级面板（FR-5.2 / §10-1）
 *
 * ⚠️ R-11：DNS 层拿不到请求方包名，「按 App 自动归集」在架构上做不到。
 *    按 docs/开发差距分析.md 的决策，改为**手动选择本次测试的 App 标签 + 人工判定分级**，
 *    记录落 grades.json，聚合由纯函数 core/GradeStats 完成（E 级不计入分母）。
 */

interface AppOption {
  app: string;
  bundle: string;
}

const APP_OPTIONS: Array<AppOption> = [
  { app: '车来了', bundle: 'com.ygkj.chelaile.standard.har' },
  { app: '平安好车主', bundle: 'com.pingan.oharm.carowner' },
  { app: '中国联通', bundle: 'com.sinovatech.unicom.ha' }
];

const GRADES: Array<string> = [GRADE_A, GRADE_B, GRADE_C, GRADE_D, GRADE_E];

@Entry
@Component
struct Grades {
  @State selectedApp: string = APP_OPTIONS[0].app;
  @State selectedBundle: string = APP_OPTIONS[0].bundle;
  @State selectedGrade: string = GRADE_B;
  @State customApp: string = '';
  @State customBundle: string = '';
  @State note: string = '';
  @State rows: Array<string> = [];
  @State statText: string = '';
  @State msg: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private store(): GradeStore {
    const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
    return new GradeStore(ctx.filesDir);
  }

  private load(): void {
    try {
      const s = this.store();
      const latest = s.latest();
      const out: Array<string> = [];
      for (const r of latest) {
        out.push(`${r.app}   ${r.grade}   ${gradeLabel(r.grade)}`);
      }
      this.rows = out.length > 0 ? out : ['（暂无记录）'];
      const st = s.stats();
      const verdict: string = st.enoughSamples
        ? (st.passAb && st.passD ? '✅ 达到 §10-1 门槛' : '⚠️ 未同时达到 A+B ≥ 60% 且 D ≤ 20%')
        : '样本不足 3 款，暂不判定达标';
      this.statText = `第三方层样本 ${st.denominator} · A+B ${st.ab} · C ${st.c} · D ${st.d} · E（不计入）${st.e}\n` +
        `A+B 占比 ${st.abRate}% · D 占比 ${st.dRate}%\n${verdict}`;
    } catch (e) {
      const err = e as BusinessError;
      this.msg = `读取失败：${err.code}`;
      Log.error(`Grades.load failed: ${err.code}`);
    }
  }

  private pick(o: AppOption): void {
    this.selectedApp = o.app;
    this.selectedBundle = o.bundle;
    this.customApp = '';
    this.customBundle = '';
  }

  private save(): void {
    let app: string = this.selectedApp;
    let bundle: string = this.selectedBundle;
    if (this.customApp.trim().length > 0) {
      app = this.customApp.trim();
      const b: string = this.customBundle.trim();
      bundle = b.length > 0 ? b : 'custom.' + app;
    }
    this.store().add(app, bundle, this.selectedGrade, this.note.trim(), Date.now());
    this.msg = `已记录 ${app} → ${this.selectedGrade}`;
    this.load();
  }

  @Builder
  gradeButton(g: string) {
    Button(g)
      .fontSize(13)
      .height(36)
      .layoutWeight(1)
      .backgroundColor(this.selectedGrade === g ? '#165DFF' : '#E8EDF5')
      .fontColor(this.selectedGrade === g ? '#FFFFFF' : '#333333')
      .onClick(() => {
        this.selectedGrade = g;
      })
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(13)
          .height(32)
          .onClick(() => this.getUIContext().getRouter().back())
        Text('效果分级')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Button('刷新')
          .fontSize(13)
          .height(32)
          .onClick(() => this.load())
      }
      .width('100%')
      .margin({ bottom: 8 })

      Text('⚠️ DNS 层拿不到请求方包名（R-11），无法自动按 App 归集。请手动选择本次测试的 App 并判定分级；E 级（一方自有广告）不计入 A+B 分母。')
        .fontSize(11)
        .fontColor('#8A5A00')
        .width('100%')
        .padding(10)
        .backgroundColor('#FFF7E6')
        .border({ width: 1, color: '#FFD591' })
        .borderRadius(6)
        .margin({ bottom: 10 })

      Scroll() {
        Column() {
          Text('统计（§10-1 分层验收）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Text(this.statText)
            .fontSize(12)
            .width('100%')
            .margin({ top: 4, bottom: 12 })

          Text('选择应用')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')

          ForEach(APP_OPTIONS, (o: AppOption) => {
            Button(o.app)
              .fontSize(12)
              .height(34)
              .width('100%')
              .margin({ top: 6 })
              .backgroundColor(this.selectedApp === o.app && this.customApp.length === 0 ? '#165DFF' : '#E8EDF5')
              .fontColor(this.selectedApp === o.app && this.customApp.length === 0 ? '#FFFFFF' : '#333333')
              .onClick(() => this.pick(o))
          }, (o: AppOption) => o.bundle)

          TextInput({ placeholder: '或自定义应用名' })
            .height(36)
            .fontSize(12)
            .margin({ top: 8 })
            .onChange((v: string) => {
              this.customApp = v;
            })
          TextInput({ placeholder: '自定义包名（可选，默认 custom.应用名）' })
            .height(36)
            .fontSize(12)
            .margin({ top: 6 })
            .onChange((v: string) => {
              this.customBundle = v;
            })

          Text('判定分级')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 14, bottom: 6 })

          Row() {
            ForEach(GRADES, (g: string) => {
              this.gradeButton(g)
            }, (g: string) => g)
          }
          .width('100%')

          Text(gradeLabel(this.selectedGrade))
            .fontSize(12)
            .fontColor('#666666')
            .width('100%')
            .margin({ top: 6 })

          TextInput({ placeholder: '备注（可选），如「等待约 4 秒」' })
            .height(36)
            .fontSize(12)
            .margin({ top: 8 })
            .onChange((v: string) => {
              this.note = v;
            })

          Button('保存本次分级')
            .fontSize(13)
            .height(38)
            .width('100%')
            .margin({ top: 8 })
            .onClick(() => this.save())

          Text(this.msg)
            .fontSize(11)
            .fontColor('#2E6BE6')
            .width('100%')
            .margin({ top: 4 })

          Text('各 App 最新分级')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 16, bottom: 6 })

          ForEach(this.rows, (r: string) => {
            Text(r)
              .fontSize(12)
              .width('100%')
              .margin({ bottom: 4 })
          }, (r: string, i: number) => `${i}-${r}`)
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
    .padding(16)
  }
}
