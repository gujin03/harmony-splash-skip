# 开屏广告拦截 · HarmonyOS 真机工程

**本机自用**（个人侧载，不上架）。方案：**本地 VPN + DNS 拦截**——让开屏广告的资源请求失败，从而让 App 提前进入主界面；不识别按钮、不注入点击。

| 文档 | 位置 |
|---|---|
| 需求文档 | `~/WorkBuddy/常用空间/2026-11-10-鸿蒙开屏跳过工具需求文档.md`（PRD v0.3.0-7） |
| 架构决策 | `docs/ADR-001-DNS拦截架构决策.md` |
| 开发差距清单 | `docs/开发差距分析.md` |
| 真机验证手册 | `docs/真机PoC验证手册.md` |
| 图标设计与规范 | `design/icon/README.md` |
| 版本变更 | `CHANGELOG.md` |

> ⛔ 原「无障碍点击」路线已按 PRD **D9 整体移除**（代码已删，非停用）：`ohos.permission.ACCESSIBILITY_EXTENSION_ABILITY` 自 API 20 起为 `system_basic`，普通自签名应用申请即安装失败（`9568289`）。完整证据与仍有效的技术结论见 PRD 附录 F。

---

## 一、当前状态（2026-11-14）

| 项 | 状态 |
|---|---|
| V1–V6 真机验证 | ✅ 全过：建 TUN、v4/v6 解析、命中拦截、上游转发、`protect()` 防回环 |
| 分层桌面图标 | ✅ 华为 UX 2.1.4.3.1（前景／背景各 1024，方案 A「盾内快进」） |
| 通知栏「停止拦截」 | ✅ `WantAgent` → `EntryAbility` → `stopVpnExtensionAbility` |
| 首页真实 VPN 状态 | ✅ 跨进程共享 `vpn_state.json` ＋ 3 秒轮询，启动失败显示错误码 |
| 规则文件化与热更新 | ✅ `filesDir/rules.json`，改完下一次查询即生效，**不需重编译／装机／重启 VPN** |
| 「本次放行」误伤兜底 | ✅ 诊断页输入，`sessionAllow` 仅本次会话，停 VPN 即清空 |
| AAAA `::` 应答 | ✅ qtype=28 不再错误地回 A 记录 |
| 空闲降频 | ✅ 连续 EAGAIN 时 10 → 100ms 退避，有包立刻恢复 |
| 第二梯队 11 项 | ✅ 规则编辑 UI／TopN 一键加黑／效果分级面板／导入导出（导出走系统保存器，含 checksum）／异常通知／首次引导／VPN 冲突提示／DoH 标注／暂停 10 分钟／集成测试／CHANGELOG |
| 单元测试 | ✅ **226 项全过**（6 个测试文件，`bash test/run.sh`） |
| 多 App 覆盖率实测 | 🟡 车来了 B、平安好车主 E、中国联通 E；第三方 SDK 样本仍不足 3–5 款（分级面板已录入这三款，显示「样本不足 3 款暂不判定」） |

⚠️ **能力边界**（PRD R-12／R-13）：走系统 resolver 的解析与 HTTPDNS 可能不进 TUN；**一方自有广告**（素材与投放都在自有域，如平安好车主、中国联通）DNS 层无下手处，不计入 A+B 分母，不要硬拦业务主域。

---

## 二、编译与安装（命令行，真机已验证）

```bash
cd ~/WorkBuddy/harmony-splash-skip
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export DEVECO_JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node

/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

HDC=$HOME/Library/OpenHarmony/Sdk/23/toolchains/hdc
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" shell aa start -a EntryAbility -b com.liuqi.splashskip
```

> `hvigorw` / `ohpm` 不在 `PATH`，必须用绝对路径。签名配置在 `.sign/sign-config.json5`（优先级高于 `build-profile.json5`，⛔ 不入库）。
> 抓日志：`hdc shell hilog -T SplashSkip -x`；⚠️ `node --test` 传目录会静默跑 0 例，本机单测一律 `bash test/run.sh`。

## 三、运行机制（一句话链路）

```
Index「启动拦截」→ SkipVpnExtension.create(TUN)
  → readLoop 只读/解码/派发（非阻塞，写回串行队列）
  → RuleStore.decide(qname)：sessionAllow > 白名单 > 黑名单
      ├─ 命中：A=0.0.0.0 / AAAA=::（或 NXDOMAIN）写回 TUN
      └─ 未命中：UpstreamForwarder 转发 223.5.5.5（protect 防回环），超时 SERVFAIL
```

跨进程只有应用沙箱文件是共同真相源：

| 文件 | 写方 | 读方 | 用途 |
|---|---|---|---|
| `rules.json` | 主进程（诊断页放行）／扩展（种子、清空） | 扩展（500ms 节流热重载） | 规则热更新、本次放行 |
| `vpn_state.json` | 扩展 | 首页 | 真实运行状态、启动失败码 |
| `diag.json` | 扩展（2 秒节流） | 诊断页 | 计数、TopN、最近 20 条、收包分项、DoH 计数 |
| `grades.json` | 效果分级页 | 效果分级页 | A/B/C/D/E 人工分级与分层统计（R-11 折中） |
| `pause.json` | 首页（暂停按钮） | 首页轮询 | 暂停截止时间，到点自动恢复 VPN |
| `onboarded.json` | 首页引导弹层 | 首页 | 首次说明只显示一次 |

## 四、目录结构

```
entry/src/main/ets/
├── entryability/EntryAbility.ets    应用入口；处理通知栏停止意图（onCreate / onNewWant 两条路径）
├── pages/Index.ets                  主页：启停、暂停、首次引导、三页入口、真实状态轮询
├── pages/Diagnostics.ets            诊断页：统计 / TopN 加黑 / 最近查询 / 本次放行 / DoH 提示
├── pages/Rules.ets                  规则管理：增删改、启停、域名测试、导入导出
├── pages/Grades.ets                 效果分级：手动 App 标签、A/B/C/D/E 记录与分层统计
├── vpnextension/SkipVpnExtension.ets  VPN 主链路、通知动作按钮、异常通知、状态与快照落盘
├── core/DnsCodec.ets                纯函数：DNS 解析与应答构造（含 AAAA）
├── core/DomainRules.ets             纯函数：规则匹配、白名单优先、会话放行判定
├── core/DiagStats.ets               纯函数：计数、TopN、收包分项、DoH 计数
├── core/RuleSchema.ets              纯函数：导入导出、FNV-1a32 checksum、字段校验
├── core/GradeStats.ets              纯函数：分级聚合与 §10-1 分层口径
├── config/TargetApps.ets            编译期默认规则种子、上游与超时常量
├── config/RuleStore.ets             规则文件化、热重载、CRUD、本次放行
├── config/GradeStore.ets            分级记录持久化
├── common/VpnState.ets              跨进程 VPN 状态读写
├── common/PauseState.ets            暂停截止时间读写
├── common/OnboardState.ets          首次引导标记
├── common/Logger.ets                HiLog 封装
└── net/UpstreamForwarder.ets        上游 UDP 转发、事务 ID 重映射、protect
```

## 五、必须遵守的约束

- ⛔ **不要把 `*.bak` 放进 `resources/`**：资源打包器会当资源扫描，报 `module_desc conflict`（`11211117`）；备份放工程外，`.gitignore` 已排除。
- ⛔ **不要再接 2 分钟 `AUTO_STOP`**：与 PRD §10-3「连续 24 小时不自动断开」冲突，且扩展进程的 `setTimeout` 实测不触发。停止只走应用内按钮／通知栏按钮。
- ⛔ **`stopVpn()` 必须保持同步**：`onDestroy` 返回后进程随时被回收，任何 `await` 之后的收尾都可能不执行（曾导致状态文件写不成、首页显示假的「运行中」）。
- ⛔ **规则别改回编译期常量**：`TargetApps.ets` 只作首次种子；运行期以 `rules.json` 为准。
- ⛔ **别拦 `pingan.com.cn`／`10010.com` 这类业务主域**：一方广告拦不住，硬拦会破坏登录与话费查询（R-13）。
- ⚠️ `foreground/background` 各 1024×1024、背景不透明、不自带圆角；AppScope 与 entry 同名资源会编译覆盖，故 AppScope 一律加 `app_` 前缀。

## 六、后续工作

功能开发已收口（第一、第二梯队全部完成，见 `docs/开发差距分析.md`）。**剩余均为验证类待办**：
补 2–3 款第三方聚合 SDK App 把 A+B 分母做实；`0.0.0.0` vs NXDOMAIN 多次复验；
连续 24 小时稳定性、待机 1 小时耗电 < 1%、误拦回归；R-12 的 `isInternal`／`trustedApplications` 覆盖率探索。
另：异常通知与 VPN 冲突提示目前只有代码级 + 编译验证，尚未人工注入异常路径实测。
