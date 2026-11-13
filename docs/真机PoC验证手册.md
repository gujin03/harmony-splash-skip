# 真机 PoC 验证手册（PRD v0.3.0 §9.1）

> 方案：**本地 VPN + DNS 拦截**。本手册只覆盖 DNS 路线的 V1–V6。
> 原无障碍路线的 V1–V5 验证步骤已随代码一并移除，历史结论见 PRD 附录 F。

---

## 〇、前置条件

| 项 | 要求 |
|---|---|
| DevEco Studio | 26.0.1 或更高（包内含 API 26 SDK 与 hvigor） |
| 真机 | API 26（本机 KEE-AL00 / OpenHarmony 7.0.0.111） |
| 签名 | 已配好 `.sign/sign-config.json5`；`build-profile.json5` 只需 `"signingConfig": "default"` 引用 |
| 网络 | 手机正常联网；**注意与其它 VPN 应用互斥**（系统同时只允许一个） |

⚠️ **风险告知**：VPN 启动后手机 DNS 会指向 TUN。当前 PoC 在抓到第一条 DNS 查询后立即 `destroy()`，所以不会长时间断网。若改动逻辑后忘记销毁，手机会表现为「能连 Wi-Fi 但打不开网页」——此时在应用内停止 VPN 或直接卸载即可恢复。

---

## 一、编译与安装

```bash
cd ~/WorkBuddy/harmony-splash-skip
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export DEVECO_JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node

/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" shell aa start -a EntryAbility -b com.liuqi.splashskip
```

装机后先确认扩展声明正确：

```bash
"$HDC" shell bm dump -n com.liuqi.splashskip | grep -E 'extensionTypeName|extensionAbilityType'
# 期望：extensionTypeName: "vpn"
```

> ⚠️ `extensionAbilityType` 显示 `255`（UNSPECIFIED）属正常现象——**第三方扩展普遍如此**，不能作为「系统不认该扩展」的依据。判断标准只看 `extensionTypeName` 与功能是否真的生效。

抓日志：

```bash
"$HDC" shell hilog -T SplashSkip -x
```

---

## 二、V1–V3（已完成，结论留档）

| # | 待验证 | 结论 | 判据 |
|---|---|---|---|
| **V1** | `createVpnConnection` + `create` 能否建立 TUN 并取 fd | ✅ | 日志 `VPN created fd=32` |
| **V2** | `fs.read` 能否从 TUN 读到原始 IP 包 | ✅ | 读到 IPv4 40 B、IPv6 76–116 B |
| **V3** | 能否解析出 DNS 查询的 qname | ✅ | `VPN DNS(v4) #1 qname=weather-drcn.music.dbankcloud.cn n=78` |

**复验方法**：点应用内「启动 VPN」按钮 → 手机上随便打开一个需要联网的 App（或执行 `ping -4 -c 1 example.com`）→ 看日志是否出现 `DNS(v4)` 或 `DNS(v6)` 行。

**已确认的三个坑**（改代码时别踩回去）：

1. `fs.read` 的 `13900010` 是 EAGAIN，必须重试，不能 `break`；
2. 只配 IPv4 DNS 抓不到——必须同时下发 `fd00::2/64` + `fd00::1` 且 `isIPv6Accepted: true`；
3. IPv6 的 `nextHeader=0` 是 Hop-by-Hop，必须链式跳过 0/43/60/44 才能找到 UDP。

---

## 三、V4（P0 门槛）· 命中黑名单返回失败应答，App 是否降级

### 要做的实现

1. `SkipVpnExtension` 里把「抓到一条就销毁」改为**持续循环**；
2. 解析出 qname 后查本地黑名单（先硬编码 3 条穿山甲域名即可）；
3. 命中时，把原查询**原样构造成响应**并写回 TUN：
   - 保留原 Transaction ID 与 Question Section（原样拷贝）
   - `Flags` 置 `QR=1`；`RCODE=3` 为 NXDOMAIN
   - 或 `ANCOUNT=1` 并附一条 A 记录 `0.0.0.0`
4. 用 `fs.write(fd, responseBuf)` 写回。

### 两种应答都要试，因为结果可能不同

| 应答 | 预期 | 说明 |
|---|---|---|
| **NXDOMAIN** | SDK 认为域名不存在，快速失败 | 更「语义正确」，但部分 SDK 会重试 |
| **A = 0.0.0.0** | 解析成功但连接必失败 | 通常更快放弃；也可能触发 SDK 的 IP 兜底 |

### 验证步骤

```bash
# 1. 启动 VPN（应用内按钮）
# 2. 完全退出目标 App（强行停止，确保进程结束、避开 DNS 缓存）
# 3. 打开目标 App，记录：是否出广告 / 等待多久 / 是否进入主界面
# 4. 抓日志确认命中
"$HDC" shell hilog -T SplashSkip -x | grep -E 'BLOCK|HIT|qname'
# 5. 恢复：停 VPN → 再开 App 对比基线耗时
```

### 判据

- **通过**：目标 App 无广告且最终进入主界面（PRD §3.4 的 A 或 B 级）；
- **不通过**：广告照常出现 → 检查是否缓存命中、是否 DoH、是否 IP 直连（见 §六）；
- **半通过**：出现空白占位（C 级）→ 仍算成立，记录即可。

⚠️ **必须用「强行停止」而非「划掉」**：系统 DNS 缓存与 App 内缓存会让热启动不经过解析，看起来像「拦不住」。

---

## 四、V5（P0 门槛）· 未命中转发上游，App 功能是否正常

这一步比 V4 更关键：**只有拦截没有转发 = 全网络瘫痪**。

### 要做的实现

1. 未命中黑名单时，把原始 DNS 报文转发给**上游 DNS**（可用系统原 DNS，或硬编码 `223.5.5.5` / `119.29.29.29`）；
2. 用 `@ohos.net.socket` 建 UDP socket，**必须先 `connection.protect(socketFd)`**，否则转发出去的包会再次被 TUN 捕获，形成回环；
3. 收到上游响应后，通过 `fs.write(fd, ...)` 写回 TUN；
4. 加超时（建议 3 s），超时返回 SERVFAIL，避免 App 一直等。

### 验证步骤

1. 只把**一条**广告域名放进黑名单，其余全部转发；
2. 打开目标 App：广告消失、但登录/列表/图片**全部正常**；
3. 逐个验证：微信收发、支付宝打开、浏览器访问任意站点、应用商店下载；
4. 抓日志侧证：`FORWARD` 计数应远大于 `BLOCK` 计数。

### 判据

- **通过**：目标 App 功能完好 + 其它 App 全部正常 + 上游转发成功率 > 99%；
- **不通过**：任何 App 出现「网络异常」→ 立刻停 VPN，检查转发链路与白名单。

---

## 五、V6（P0 门槛）· `protect()` 是否可用、能否防回环

`VpnConnection.protect(socket)` 在 SDK 里未标 `@permission`，但**是否有运行时限制未验证**（PRD 附录 C 标 🔵）。

| 检查点 | 方法 | 期望 |
|---|---|---|
| 接口存在且可调用 | 编译期即知；运行时看是否抛异常 | 无异常 |
| 防回环是否生效 | 不调 `protect` 直接转发 → 观察 CPU 与日志 | 会看到同一查询被反复处理（回环） |
| 调 `protect` 后 | 同上 | 回环消失，`FORWARD` 计数与 App 请求数相当 |

**回环的典型症状**：CPU 飙高、日志里同一 qname 每秒重复十几次、手机发热、网络卡死。

---

## 六、拦不到时的排查顺序

按成本从低到高：

1. **DNS 缓存**：强行停止 App 再试；仍拦不住则考虑重启手机清系统缓存；
2. **DoH / DoT**：App 内置加密 DNS（443/853），53 端口根本不经过 TUN → 查日志有无该 App 的任何查询，若完全为 0 高度怀疑此因；
3. **IP 直连**：SDK 预置 IP 兜底，跳过域名解析 → 本方案边界（PRD R-5），不做 IP 封锁；
4. **域名漏配**：从日志的 `FORWARD` 列表里找可疑域名（含 `ad`／`sdk`／`log`／`pangolin`／`gdt` 等特征）补进黑名单；
5. **多路径聚合**：车来了这类聚合 SDK 会并行问十几个广告源，拦一个不够，需要把该 App 实际命中的域名**逐个**加入。

---

## 七、结果记录表（回填 PRD 附录 C）

| 项 | 记录 |
|---|---|
| 目标 App 包名 | |
| V4 应答类型（NXDOMAIN / 0.0.0.0） | |
| 是否出广告 | |
| 进入主界面耗时（秒） | |
| 效果分级（A/B/C/D） | |
| V5 转发成功率 | |
| V6 是否需 protect | |
| 发现的漏配域名 | |

---

## 七之二、多 App 分层覆盖率实测（2026-11-13 / 11-14）

| App | 包名 | 分级 | 关键数据 | 结论 |
|---|---|---|---|---|
| 车来了 | `com.ygkj.chelaile.standard.har` | **B** | 拦截命中聚合 SDK 域名，无广告进主界面（约 4 秒） | 计入 A+B 分母 |
| 平安好车主 | `com.pingan.oharm.carowner` | **E** | DNS 44／拦截 0／9 个域名属 `pingan.com.cn` | 一方广告，不计入分母 |
| 中国联通 | `com.sinovatech.unicom.ha` | **E** | 见下方 A/B/C 三轮对照 | 一方广告，精确子域拦截无效，不计入分母 |

**中国联通三轮对照**（每次均 `force-stop` 后冷启动，截屏连拍）：

| 轮次 | 配置 | DNS 判定 | 开屏画面 |
|---|---|---|---|
| A | 原规则库，VPN 开 | `dns=42 block=0 fwdOk=42`，转发全为 `10010.com` 业务域 | 广告完整播放（招联 eSIM） |
| B | 精确拦 `smartad`／`m1.ad`／`m1.img` 三条，VPN 开 | `BLOCK 26`（smartad 22／m1.img 4）、`FWD 20` | 广告完整播放（港澳国际流量包） |
| C | VPN 关（基线） | 不接管 | 广告完整播放（流量越用越便宜） |

⚠️ 三套不同素材说明是服务端轮换投放、不是缓存；拦掉广告子域后画面毫无变化，判定 **E 级**。三条规则因此留档为 `enabled: false`——开着只会让 SDK 重试并虚高命中率。详见 `ADR-001` 的 AD-7、PRD R-13。

## 七之三、自动化验证配方（不依赖人工点屏）

本轮中国联通验证全程由 hdc 完成，无需人工操作手机：

```bash
HDC=$HOME/Library/OpenHarmony/Sdk/23/toolchains/hdc; T=<device-id>

# 1. 工具 App 拉前台 → 自动点「启动拦截」（1100×2380 屏，按钮中心 550,1074）
"$HDC" -t $T shell aa start -a EntryAbility -b com.liuqi.splashskip
"$HDC" -t $T shell uitest uiInput click 550 1074

# 2. 冷启动目标 App（⛔ 必须 force-stop，划掉进程会因 DNS 缓存造成假阴性）
"$HDC" -t $T shell aa force-stop <bundle>
"$HDC" -t $T shell aa start -a EntryAbility -b <bundle>

# 3. 每 2 秒连拍 4–5 张（⛔ snapshot_display 只接受 .jpeg 后缀，传 .png 直接报错）
"$HDC" -t $T shell snapshot_display -f /data/local/tmp/s1.jpeg
"$HDC" -t $T file recv /data/local/tmp/s1.jpeg /tmp/s1.jpeg

# 4. 按 VPN 扩展进程 pid 过滤日志，避免混入上一轮会话
"$HDC" -t $T shell hilog -T SplashSkip -x > /tmp/hilog.txt

# 5. 停止：诊断页「返回」(140,240) → 主界面「停止拦截」(550,1218)
"$HDC" -t $T shell uitest uiInput click 140 240
"$HDC" -t $T shell uitest uiInput click 550 1218
```

⚠️ 坐标只在 1100×2380 的当前布局下实测有效，界面改动后需重新截屏定位。
⚠️ VPN 首次连接的系统授权框：本机此前已授权，本轮未复现；换设备仍需人工确认一次。
⚠️ `hilog -x` 会清空缓冲区，取数时一次抓全并按 pid 分离；诊断页是**会话累计**，换 App 前必须停止再启动以归零（R-11）。

---

## 八、常见错误码

| 码 / 现象 | 含义 | 处理 |
|---|---|---|
| `13900010` | EAGAIN，TUN 暂无数据 | 重试，不要退出循环 |
| `9568289` | 申请了受限权限（`system_basic`） | 移除该权限声明；这也是无障碍路线被否决的原因 |
| `00306042` | `targetSdkVersion` 格式不对 | 写 `"5.0.0(23)"` 或直接删掉该字段 |
| `11211117` | 资源打包冲突 | 检查 `resources/` 下有没有 `*.bak` 等多余文件 |
| `hilog CODE: -31` | `-x` 与 `-z` 参数冲突 | 只用 `-x` |
