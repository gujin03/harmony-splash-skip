import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import util from '@ohos.util';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { RuleStore } from '../config/RuleStore';
import type { RulesFile } from '../config/RuleStore';
import {
  DomainRule,
  ACTION_BLOCK,
  MATCH_SUFFIX,
  MATCH_EXACT,
  MATCH_KEYWORD
} from '../core/DomainRules';

/**
 * 规则编辑页（FR-4.3 / FR-3.4）
 *
 * ⚠️ 真相源是 filesDir/rules.json，不是编译期常量；每次操作重新读文件再写回，
 *    避免覆盖扩展进程刚做的变更。保存后扩展 500ms 内热重载，不需重启 VPN。
 */

@Entry
@Component
struct Rules {
  @State tab: number = 0;                 // 0 = 黑名单，1 = 白名单
  @State items: Array<DomainRule> = [];
  @State msg: string = '';
  @State editIndex: number = -1;
  @State inputDomain: string = '';
  @State inputType: string = MATCH_SUFFIX;
  @State inputNote: string = '';
  @State testDomain: string = '';
  @State testResult: string = '';
  @State ioText: string = '';
  @State ioMsg: string = '';
  /** 系统保存／选择窗口是异步的，期间禁用按钮防重复拉起 */
  @State exporting: boolean = false;
  @State importing: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private store(): RuleStore {
    const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
    const s = new RuleStore(ctx.filesDir);
    s.init();
    return s;
  }

  /** ⚠️ 不能叫 key()：与 CustomComponent 基类的 key 属性冲突（ArkTS 10505001） */
  private listKey(): string {
    return this.tab === 0 ? 'black' : 'white';
  }

  private load(): void {
    try {
      const data: RulesFile | null = this.store().getSnapshot();
      if (data === null) {
        this.msg = '读取规则失败';
        return;
      }
      this.items = this.tab === 0 ? data.blacklist.slice(0) : data.whitelist.slice(0);
      this.msg = `共 ${this.items.length} 条 · 保存后下一次查询即生效（无需重启 VPN）`;
    } catch (e) {
      const err = e as BusinessError;
      this.msg = `读取失败：${err.code}`;
      Log.error(`Rules.load failed: ${err.code}`);
    }
  }

  private clearInput(): void {
    this.editIndex = -1;
    this.inputDomain = '';
    this.inputType = MATCH_SUFFIX;
    this.inputNote = '';
  }

  private switchTab(t: number): void {
    this.tab = t;
    this.clearInput();
    this.load();
  }

  private save(): void {
    const d: string = this.inputDomain.trim();
    if (d.length === 0) {
      this.msg = '请先输入域名';
      return;
    }
    let enabled: boolean = true;
    if (this.editIndex >= 0 && this.editIndex < this.items.length) {
      enabled = this.items[this.editIndex].enabled;
    }
    const r: DomainRule = {
      domain: d,
      matchType: this.inputType,
      enabled: enabled,
      note: this.inputNote.trim()
    };
    const s = this.store();
    const done: boolean = this.editIndex >= 0
      ? s.updateRule(this.listKey(), this.editIndex, r)
      : s.addRule(this.listKey(), r);
    this.msg = done ? '已保存，下一次查询生效' : '保存失败：同名规则已存在或索引越界';
    this.clearInput();
    this.load();
  }

  private edit(i: number): void {
    if (i < 0 || i >= this.items.length) {
      return;
    }
    const r: DomainRule = this.items[i];
    this.editIndex = i;
    this.inputDomain = r.domain;
    this.inputType = r.matchType;
    this.inputNote = r.note;
    this.msg = `正在编辑 #${i} ${r.domain}`;
  }

  private remove(i: number): void {
    this.store().deleteRule(this.listKey(), i);
    this.msg = `已删除 #${i}`;
    this.load();
  }

  private toggle(i: number): void {
    this.store().toggleRule(this.listKey(), i);
    this.load();
  }

  private test(): void {
    const d: string = this.testDomain.trim();
    if (d.length === 0) {
      this.testResult = '请输入域名';
      return;
    }
    const res = this.store().testDomain(d);
    if (res.action === ACTION_BLOCK) {
      this.testResult = `将被拦截（命中 ${res.reason}）`;
    } else {
      this.testResult = res.reason.length > 0
        ? `放行（${res.reason}）` : '放行（未命中任何规则）';
    }
  }

  /** 导出文件名里的时间戳，便于在文件管理器里区分多次导出 */
  private stamp(): string {
    const d = new Date();
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
  }

  private shortUri(uri: string): string {
    const i: number = uri.lastIndexOf('/');
    return i >= 0 ? uri.substring(i + 1) : uri;
  }

  /**
   * 调系统文件保存器（DocumentViewPicker.save）让用户指定目录并落盘。
   *
   * 导出内容与旧实现完全一致：RuleStore.exportText() 产出的 JSON 信封（含 schemaVersion + checksum）。
   * 三种结果都要有反馈：成功显示文件名、取消明确提示、失败显示错误码。
   */
  private async doExport(): Promise<void> {
    if (this.exporting) {
      return;
    }
    const text: string = this.store().exportText();
    if (text.length === 0) {
      this.ioMsg = '导出失败：规则内容为空';
      return;
    }
    this.exporting = true;
    this.ioMsg = '正在等待系统保存窗口…';
    try {
      const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(ctx);
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [`splashskip-rules-${this.stamp()}.json`];
      opt.fileSuffixChoices = ['.json'];
      opt.autoCreateEmptyFile = true;
      const uris: Array<string> = await docPicker.save(opt);
      // 用户取消：多数版本返回空数组；个别版本抛 13900042，见 catch
      if (uris === undefined || uris.length === 0) {
        this.ioMsg = '已取消导出（未生成文件）';
        return;
      }
      const uri: string = uris[0];
      const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      this.ioText = text;   // 同时留在文本框便于核对内容
      this.ioMsg = `已保存 ${text.length} 字符：${this.shortUri(uri)}`;
      Log.info(`export saved: ${uri}`);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 13900042) {
        this.ioMsg = '已取消导出（未生成文件）';
      } else {
        this.ioMsg = `导出失败：${err.code} ${err.message}`;
      }
      Log.error(`export failed: code=${err.code} msg=${err.message}`);
    } finally {
      this.exporting = false;
    }
  }

  /** 从 URI 读文本：先 open 再按 fd 读，避免依赖 readTextSync 对 file URI 的支持 */
  private readTextFromUri(uri: string): string {
    const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const st: fs.Stat = fs.statSync(file.fd);
      // 规则文件正常只有几 KB；超过 2 MB 直接判为异常，避免误选大文件吃内存
      if (st.size <= 0 || st.size > 2 * 1024 * 1024) {
        return '';
      }
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      const n: number = fs.readSync(file.fd, buf);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf, 0, n));
    } finally {
      fs.closeSync(file);
    }
  }

  /**
   * FR-3.4：从文件导入。
   * 系统文件选择器（DocumentViewPicker.select）→ 读取 → RuleStore.importText 的
   * 四关校验（format／schemaVersion／字段／checksum）→ 写盘并热更新。
   */
  private async doImportFromFile(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    this.ioMsg = '正在等待文件选择…';
    try {
      const ctx = this.getUIContext().getHostContext()! as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(ctx);
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.json'];
      const uris: Array<string> = await docPicker.select(opt);
      if (uris === undefined || uris.length === 0) {
        this.ioMsg = '已取消导入（未读取文件）';
        return;
      }
      const uri: string = uris[0];
      const text: string = this.readTextFromUri(uri);
      if (text.length === 0) {
        this.ioMsg = '导入失败：文件为空、超过 2MB 或无法读取';
        return;
      }
      this.ioText = text;
      const err: string = this.store().importText(text.trim());
      if (err.length === 0) {
        const data: RulesFile | null = this.store().getSnapshot();
        const b: number = data === null ? 0 : data.blacklist.length;
        const w: number = data === null ? 0 : data.whitelist.length;
        this.ioMsg = `导入成功：黑名单 ${b} 条 / 白名单 ${w} 条，下一次查询生效`;
        Log.info(`import from file ok: ${uri}`);
      } else {
        this.ioMsg = `导入失败：${err}`;
      }
      this.load();
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 13900042) {
        this.ioMsg = '已取消导入（未读取文件）';
      } else {
        this.ioMsg = `导入失败：${err.code} ${err.message}`;
      }
      Log.error(`import failed: code=${err.code} msg=${err.message}`);
    } finally {
      this.importing = false;
    }
  }

  /** 次要入口：把文本框里的 JSON 导入（便于从聊天记录等处粘贴） */
  private doImportText(): void {
    const text: string = this.ioText.trim();
    if (text.length === 0) {
      this.ioMsg = '文本框为空，请粘贴规则 JSON 或改用「从文件导入」';
      return;
    }
    const err: string = this.store().importText(text);
    this.ioMsg = err.length === 0 ? '导入成功，下一次查询生效' : `导入失败：${err}`;
    this.load();
  }

  @Builder
  typeButton(label: string, value: string) {
    Button(label)
      .fontSize(11)
      .height(30)
      .backgroundColor(this.inputType === value ? '#165DFF' : '#E8EDF5')
      .fontColor(this.inputType === value ? '#FFFFFF' : '#333333')
      .onClick(() => {
        this.inputType = value;
      })
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(13)
          .height(32)
          .onClick(() => this.getUIContext().getRouter().back())
        Text('规则管理')
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

      Row() {
        Button('黑名单')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(this.tab === 0 ? '#165DFF' : '#E8EDF5')
          .fontColor(this.tab === 0 ? '#FFFFFF' : '#333333')
          .onClick(() => this.switchTab(0))
        Button('白名单')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .margin({ left: 8 })
          .backgroundColor(this.tab === 1 ? '#165DFF' : '#E8EDF5')
          .fontColor(this.tab === 1 ? '#FFFFFF' : '#333333')
          .onClick(() => this.switchTab(1))
      }
      .width('100%')
      .margin({ bottom: 6 })

      Text(this.msg)
        .fontSize(11)
        .fontColor('#2E6BE6')
        .width('100%')
        .margin({ bottom: 8 })

      Scroll() {
        Column() {
          Text(this.editIndex >= 0 ? '编辑规则' : '新增规则')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')

          TextInput({ placeholder: '域名，如 ads.example.com', text: this.inputDomain })
            .height(38)
            .fontSize(12)
            .margin({ top: 6 })
            .onChange((v: string) => {
              this.inputDomain = v;
            })

          Row() {
            this.typeButton('后缀 suffix', MATCH_SUFFIX)
            this.typeButton('精确 exact', MATCH_EXACT)
            this.typeButton('关键字 keyword', MATCH_KEYWORD)
          }
          .width('100%')
          .margin({ top: 6, bottom: 6 })

          TextInput({ placeholder: '备注（可选）', text: this.inputNote })
            .height(38)
            .fontSize(12)
            .onChange((v: string) => {
              this.inputNote = v;
            })

          Row() {
            Button(this.editIndex >= 0 ? '保存修改' : '添加规则')
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .onClick(() => this.save())
            Button('取消编辑')
              .fontSize(12)
              .height(36)
              .margin({ left: 8 })
              .backgroundColor('#8A94A6')
              .onClick(() => this.clearInput())
          }
          .width('100%')
          .margin({ top: 8, bottom: 14 })

          Text('规则列表（点击右侧按钮操作）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ bottom: 6 })

          ForEach(this.items, (r: DomainRule, i: number) => {
            Row() {
              Column() {
                Text(r.domain)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .width('100%')
                Text(`${r.matchType} · ${r.enabled ? '启用' : '停用'} · ${r.note}`)
                  .fontSize(10)
                  .fontColor(r.enabled ? '#666666' : '#B03030')
                  .width('100%')
              }
              .layoutWeight(1)

              Button(r.enabled ? '停用' : '启用')
                .fontSize(10)
                .height(28)
                .onClick(() => this.toggle(i))
              Button('编辑')
                .fontSize(10)
                .height(28)
                .margin({ left: 4 })
                .backgroundColor('#4A6FA5')
                .onClick(() => this.edit(i))
              Button('删除')
                .fontSize(10)
                .height(28)
                .margin({ left: 4 })
                .backgroundColor('#B03030')
                .onClick(() => this.remove(i))
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .border({ width: { bottom: 1 }, color: '#EEEEEE' })
          }, (r: DomainRule, i: number) => `${i}-${r.domain}-${r.enabled}`)

          Text('域名测试（按当前规则判定）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 16, bottom: 6 })

          Row() {
            TextInput({ placeholder: '输入域名' })
              .layoutWeight(1)
              .height(36)
              .fontSize(12)
              .onChange((v: string) => {
                this.testDomain = v;
              })
            Button('测试')
              .fontSize(12)
              .height(36)
              .margin({ left: 8 })
              .onClick(() => this.test())
          }
          .width('100%')

          Text(this.testResult)
            .fontSize(12)
            .fontColor('#B03030')
            .width('100%')
            .margin({ top: 4 })

          Text('导出到文件 / 从文本导入（JSON，含 schemaVersion + checksum）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 16, bottom: 6 })

          TextArea({ placeholder: '导出会调起系统保存窗口；导入用「从文件导入」选择 .json，也可把 JSON 粘贴到这里后点下方「导入上方文本」', text: this.ioText })
            .height(110)
            .fontSize(10)
            .width('100%')
            .onChange((v: string) => {
              this.ioText = v;
            })

          Row() {
            Button(this.exporting ? '等待保存…' : '导出到文件')
              .fontSize(12)
              .height(36)
              .layoutWeight(1)
              .enabled(!this.exporting)
              .onClick(() => {
                this.doExport();
              })
            Button(this.importing ? '等待选择…' : '从文件导入')
              .fontSize(12)
              .height(36)
              .layoutWeight(1)
              .margin({ left: 8 })
              .backgroundColor('#4A6FA5')
              .enabled(!this.importing)
              .onClick(() => {
                this.doImportFromFile();
              })
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text('也可从剪贴板导入：把 JSON 粘贴到上方文本框')
              .fontSize(10)
              .fontColor('#888888')
              .layoutWeight(1)
            Button('导入上方文本')
              .fontSize(10)
              .height(26)
              .backgroundColor('#8A94A6')
              .onClick(() => this.doImportText())
          }
          .width('100%')
          .margin({ top: 6 })

          Text(this.ioMsg)
            .fontSize(11)
            .fontColor('#2E6BE6')
            .width('100%')
            .margin({ top: 4, bottom: 24 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
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
