# 开屏广告拦截工具 · 真机 PoC 工程

对应需求文档：`~/WorkBuddy/常用空间/2026-11-10-鸿蒙开屏跳过工具需求文档.md`（**PRD v0.3.0**）**§9.1 极简验证版**。

**方案：本地 VPN + DNS 拦截**——不识别按钮、不注入点击，而是让开屏广告的资源请求失败，从而让 App 提前进入主界面。

> ⚠️ 原「无障碍点击」路线已按 PRD **D9 整体移除**（代码已删，非停用）。原因：`ohos.permission.ACCESSIBILITY_EXTENSION_ABILITY` 自 **API 20** 起为 `system_basic`，普通自签名应用申请即安装失败（`code:9568289`），且设置内不存在第三方服务入口。完整证据与仍有效的技术结论见 PRD **附录 F**。

---

## 一、当前进度

| 验证项 | 结论 |
|---|---|
| **V1** 建立 TUN 并取得 fd | ✅ `VPN created fd=32` |
| **V2** 从 TUN 读到原始 IP 包 | ✅ IPv4 40 B、IPv6 76–116 B |
| **V3** 解析出 DNS 查询域名 | ✅ `qname=weather-drcn.music.dbankcloud.cn n=78`，v4/v6 双通 |
| **V4** 命中黑名单返回 NXDOMAIN，App 是否降级 | ⏳ 待实现（P0 门槛） |
| **V5** 未命中转发上游并回写，App 功能正常 | ⏳ 待实现（P0 门槛） |
| **V6** `protect(socket)` 是否可用、能否防回环 | ⏳ 待实现（P0 门槛） |

**端到端效果已先行验证**（Mac 代理侧，不改 App）：阻断穿山甲域名后，车来了直接进主界面、没有广告，只多等约 4 秒——对应 PRD §3.4 的 **B 级（超时后进入）**。那 4 秒是聚合 SDK 逐个等超时的总耗时（`All ad groups exhausted`、`costTime=4001`）。

---

## 二、本机环境（2026-11-13 实测）

| 项 | 实测结果 |
|---|---|
| DevEco Studio | ✅ **26.0.1**（DS-261.23567.138.36.2601290），`/Applications/DevEco-Studio.app` |
| SDK | ✅ 包内 API **26**（26.0.1.120 Beta1） |
| node / ohpm / hvigor | ✅ 包内 `tools/node` v24.14.1、`tools/ohpm` 26.0.1.220、`tools/hvigor` 6.26.20 |
| `hdc` | ✅ `sdk/default/openharmony/toolchains/hdc` |
| 真机 | ✅ KEE-AL00 / OpenHarmony 7.0.0.111 / **API 26**，USB 已连 |

> `hvigorw`、`ohpm` **都不在 `PATH`**，必须用绝对路径（见下）。

---

## 三、目录结构

```
harmony-splash-skip/
├── AppScope/                              # 应用级配置（bundleName com.liuqi.splashskip）
├── build-profile.json5 / hvigorfile.ts / oh-package.json5
├── hvigor/hvigor-config.json5             # modelVersion 5.0.0
├── docs/
│   └── 真机PoC验证手册.md                  # ⭐ 先读这个
└── entry/src/main/
    ├── module.json5                       # 声明 vpn ExtensionAbility + INTERNET 权限
    ├── resources/base/profile/
    │   └── main_pages.json
    └── ets/
        ├── entryability/EntryAbility.ets
        ├── pages/Index.ets                # PoC 状态页 + 启动按钮
        ├── common/Logger.ets              # HiLog tag = SplashSkip
        ├── config/TargetApps.ets          # 观测目标包名（仅统计用）+ PoC 开关
        └── vpnextension/
            └── SkipVpnExtension.ets       # 收包主循环：TUN → IP/UDP/DNS → 抓到即销毁
```

> ⛔ **不要把 `*.bak` 放进 `resources/`**：资源打包器会把它当资源扫描，报
> `Resource 'module_desc' conflict`（`Error Code: 11211117`）。备份一律放工程外。

---

## 四、编译与安装（命令行，已验证可用）

```bash
cd ~/WorkBuddy/harmony-splash-skip

export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export DEVECO_JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node

/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`（约 78 K）

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" shell aa start -a EntryAbility -b com.liuqi.splashskip
"$HDC" shell hilog -T SplashSkip -x          # 抓日志
```

> ⚠️ `hilog -x` 与 `-z` 不能同时用（会报 `CODE: -31`）。

---

## 五、签名配置（重要）

DevEco 26 把签名材料放在 **`.sign/sign-config.json5`**，构建时**优先级高于** `build-profile.json5` 里的 `signingConfigs`：

```
A configuration with the same name 'default' exists in sign-config.json5.
The configuration in sign-config.json5 takes precedence.
```

因此本仓库的 `build-profile.json5` **不含 `signingConfigs`**（已剥离），只保留 product 里的 `"signingConfig": "default"` 引用——这样仓库里不出现证书路径与密码密文，而本机构建仍能签出签名包（实测 `SignHap` 执行、`hap-sign-tool verify-app success`）。

`.sign/` 与 `*.p12 / *.cer / *.p7b / *.csr` 已在 `.gitignore` 中排除。

> ⚠️ `targetSdkVersion` 不要写成 `"23"`：格式要求 `"5.0.0(23)"`，否则报 `00306042`。IDE 有时会写入空字符串，直接删掉该字段最稳。

---

## 六、已踩的四个坑

| # | 现象 | 原因 | 修法 |
|---|---|---|---|
| 1 | 第二次 `fs.read` 报 `13900010` | TUN 非阻塞（EAGAIN），首版当致命错误 `break` 了 | 当「暂时没数据」重试，用 `reads/v4/v6/dns` 计数区分「真无流量」与「解析失败」 |
| 2 | 只配 IPv4 DNS `10.0.0.1` 抓不到任何查询 | 手机 Wi-Fi 有 IPv6，系统优先用 IPv6 DNS，查询根本不进 TUN | 同时下发 `fd00::2/64` + `fd00::1`，并置 `isIPv6Accepted: true` |
| 3 | IPv6 包解析不到 UDP | `nextHeader=0` 是 **Hop-by-Hop 扩展头**，UDP 在扩展头之后 | 链式解析 0/43/60/44 直到协议号 17，设最大跳数上限 |
| 4 | 资源打包报 `module_desc conflict` | `string.json.before-d9.bak` 放在 `resources/` 下被当资源扫描 | 备份移出工程；`.gitignore` 已排除 `*.bak` |

---

## 七、下一步

1. 读 `docs/真机PoC验证手册.md`，按 V4 → V5 → V6 顺序推进（三项都是 P0 门槛）；
2. V4 先比对两种应答：**NXDOMAIN** vs **A 记录 `0.0.0.0`**，看哪种让广告 SDK 更快放弃；
3. V5 必须实现上游转发，否则「只拦广告、不拦其它」不成立，方案不可用；
4. 三项全过后进入 PRD §9.2 MVP（黑名单 + 白名单 + 通知栏 + 诊断页）；
5. 结果回填 PRD 附录 C 与 §9.1。
