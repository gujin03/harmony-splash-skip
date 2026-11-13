# ADR-001 · DNS 拦截架构决策（PRD v0.3.0）

| 项 | 内容 |
|---|---|
| 状态 | 已定稿（2026-11-13） |
| 范围 | MVP 阶段的架构骨架与不可测边界划分；不含 V4/V5/V6 的策略细节 |
| 依据 | PRD v0.3.0 §4.3 四级闭环、§9.1 V1–V6、附录 D 规则 schema |
| 不在本文件 | 应答策略（NXDOMAIN vs `0.0.0.0`）、上游选择、超时参数 —— 依赖 V4/V5/V6 实测 |

> **为什么只有 5 条**：只记录「一旦代码铺开再改就伤筋动骨」的决策。其余实现细节等实测固化后写进代码注释，不单独出文档。

---

## AD-1 · 并发模型：读循环只做「读 → 解码 → 派发」

**决策**：`readLoop` 内**不允许出现任何等待网络响应的 `await`**。循环职责限定为：从 TUN 读包 → 解析出 `DnsQuery` → 交给处理器 → 继续读下一包。上游转发、应答构造、回写分别在独立异步任务中完成，回写走队列串行化。

**理由**：当前 `SkipVpnExtension.readLoop` 是单循环串行（`await fs.read` → 解析 → 处理）。一旦在循环内做「转发并等上游响应」，单条查询几十到几百毫秒的 RTT 会让**整个收包循环停摆**，手机每秒数十条 DNS 查询必然丢包与超时。这不是性能优化，是正确性问题。

**约束**：
- `readLoop` 内所有分支必须是非阻塞的；
- 回写 TUN 必须串行（多个并发 `fs.write` 到同一 fd 的顺序不可依赖），用队列 + 单消费者；
- 需要限流：同时在途的转发任务数设上限（建议 64），超出直接返回 SERVFAIL，避免内存膨胀。

**后果**：多一层派发与队列，代码量增加约 80–120 行；换来的是高并发下不丢包。

---

## AD-2 · DNS 编解码边界：Question 段原字节拷贝，不重新编码

**决策**：构造应答时，**Question 段从原始报文按字节整段拷走**（`dnsOffset+12` 到 `questionEnd`），只改 Header 的 flags 与计数、追加 Answer 段。`parseDnsQuery` 必须同时返回 Question 段的结束偏移。

**理由**：现在的 `parseQname` 只返回字符串，丢了位置信息。自己重编码 QNAME 要处理大小写保留、压缩指针、转义字符，容易出错且难验证；原样拷贝零风险。

**约束**：
- `parseDnsQuery` 返回结构必须含 `dnsOffset` 与 `questionEnd`；
- 解析 QNAME 需支持压缩指针（`0xC0`），并设最大跳数（建议 8）防环；
- 解析失败一律返回 `null`，由调用方决定丢弃（不得抛异常穿透到读循环）。

**后果**：应答构造变成「头部改写 + 字节拼接」，可完全纯函数化，能被单元测试覆盖。

---

## AD-3 · 可测性分层：编解码与规则匹配必须是纯函数

**决策**：`core/DnsCodec`、`rules/DomainRules` 只做 `Uint8Array` / `string` 进出，**不 import 任何 `@ohos.*`、不碰 fd、不打日志、不持有状态**。测试用本机 node 直接跑同一份源码。

**理由**：这是本项目最大的痛点——改一行就要编译装机看 hilog，排查精度低且慢。纯函数可以在 Mac 上秒级验证。

**实现方式（已实测可行）**：Node 24.14.1 的 type stripping 默认开启，把 `.ets` 复制成 `.ts` 即可直接运行；`import './X.ts'` 可用（`.js` 不行）。因此核心模块必须**自包含、零本地 import**，测试侧才带扩展名。

**约束**：
- 核心模块内禁用 ArkTS 需要代码生成的特性（`enum`、`namespace`、参数属性、装饰器）——否则无法被 node strip；
- 日志、计时、TUN I/O 只能出现在 `SkipVpnExtension` 或独立的「适配层」，不得渗入核心模块；
- `.test-build/` 为生成目录，不入库。

**后果**：核心逻辑可在本机回归测试；只有真实网络行为（V4/V5/V6）需要装机。

---

## AD-4 · 规则匹配：数组 + 后缀比较，不上 Trie

**决策**：域名规则用扁平数组，`matchType` 支持 `suffix` / `exact` / `keyword` 三种；每次查询遍历匹配。白名单先于黑名单判定。

**理由**：规则量级是几十到几百条，遍历成本微秒级，Trie 带来的收益抵不上实现与调试成本。域名长度短，比较开销可忽略。

**约束**：
- `suffix` 语义必须是「等于该值，或以 `.` + 该值结尾」，避免 `evil-pangolin-sdk-toutiao.com.attacker.net` 这类误命中；
- 匹配前统一小写、去掉末尾的点；
- 白名单命中即放行，**优先级高于黑名单**（PRD FR-3.3）。

**后果**：`DomainRules.ets` 约 60 行，无复杂数据结构。

---

## AD-5 · 错误语义：定义清楚，不靠默认行为

| 情形 | 处理 | 理由 |
|---|---|---|
| 上游超时 / 无响应 | 返回 **SERVFAIL**（RCODE=2） | 让 App 快速失败并重试，而不是挂住 |
| 解码失败（非法报文 / 非 UDP 53） | **静默丢弃**，不写回任何内容 | 写回错误响应可能被误当有效应答 |
| 命中黑名单 | 返回 NXDOMAIN 或 `0.0.0.0`（**由 V4 实测决定**） | 需对比哪种让 SDK 更快放弃 |
| 在途任务超上限 | 立即 SERVFAIL | 防内存膨胀，优于排队等死 |
| `fs.write` 失败 | 记录计数，不影响读循环；连续失败 N 次则停止 VPN 并通知 | 避免无声失效 |
| VPN 连接被系统销毁 | `onDestroy` → 清 timer / 队列 / socket，置状态为「已停止」 | 不允许残留半开状态 |
| 端口不是 53 的 UDP | 不处理（当前不接管非 DNS 流量） | 方案边界，见 PRD §3.3 |

---

## 关键接口（实现以此为准）

```typescript
/** 解析结果；解析失败返回 null */
export interface DnsQuery {
  ipVersion: number;      // 4 | 6
  transId: number;        // DNS 事务 ID
  qname: string;          // 已转小写、无末尾点
  qtype: number;          // 1=1 A | 28=AAAA
  qclass: number;         // 1=IN
  dnsOffset: number;      // DNS 报文在包内的起点
  questionEnd: number;    // Question 段结束位置（不含）
  udpOffset: number;      // UDP 头偏移
  ipHeaderLen: number;    // IPv4 为 IHL，IPv6 为 40
}

export function parseDnsQuery(packet: Uint8Array): DnsQuery | null;

/** 只产出 DNS 层字节，不含 IP/UDP 头 */
export function buildNxDomain(raw: Uint8Array, q: DnsQuery): Uint8Array;
export function buildAddressResponse(raw: Uint8Array, q: DnsQuery, ipv4: number[]): Uint8Array;
export function buildServFail(raw: Uint8Array, q: DnsQuery): Uint8Array;

/** 交换源/目的地址与端口，重算校验和，产出可直接写回 TUN 的完整 IP 包 */
export function buildResponsePacket(raw: Uint8Array, q: DnsQuery, dnsPayload: Uint8Array): Uint8Array;
```

---

## 未决项（等 V4/V5/V6）

| # | 待定 | 影响 |
|---|---|---|
| 1 | 应答用 NXDOMAIN 还是 `0.0.0.0` | 决定默认 `behavior.response`，两者都已实现，由实测选一个 |
| 2 | 上游 DNS 选择（系统原 DNS / 硬编码 `223.5.5.5`） | 决定 `UpstreamForwarder` 的初始化方式 |
| 3 | `protect()` 是否可用 | **若不可用，转发路线整体作废**，需退到 PRD §9.5 方案 B |
| 4 | 是否需要 TCP 53 兜底（大响应/截断） | 绝大多数 DNS 走 UDP，暂不做 |
