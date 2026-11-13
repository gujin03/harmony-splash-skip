/**
 * 拦截配置（PRD v0.3.0 / D4 / FR-3 / FR-4）
 *
 * ⚠️ D4 / R-11：目标包名**不控制拦截范围**——DNS 层拿不到请求方包名，
 *   域名规则全局生效。TARGET_BUNDLES 仅用于诊断页归集。
 */

import { DomainRule, MATCH_SUFFIX, MATCH_EXACT } from '../core/DomainRules';

/** 观测目标应用（仅用于统计与诊断展示，PRD D4） */
export const TARGET_BUNDLES: Array<string> = [
  'com.ygkj.chelaile.standard.har'   // 车来了：Mac 代理侧端到端已验证
];

/**
 * 黑名单（PRD 附录 D）。MVP 阶段硬编码，先覆盖车来了实测命中的域名。
 * ⚠️ CDN 类（pglstatp-toutiao.com）可能与正常素材共用，默认关闭，
 *    需逐 App 实测后再决定是否开启（PRD §4.4 难点）。
 */
export const BLACKLIST: Array<DomainRule> = [
  // ---------- 穿山甲（字节）----------
  { domain: 'pangolin-sdk-toutiao.com', matchType: MATCH_SUFFIX, enabled: true, note: '穿山甲 API（实测 api-access.* 9 次）' },
  { domain: 'pangolin-sdk-toutiao1.com', matchType: MATCH_SUFFIX, enabled: true, note: '穿山甲备用（实测 api-access.*1 2 次）' },
  { domain: 'pangolin-sdk-toutiao-b.com', matchType: MATCH_SUFFIX, enabled: true, note: '穿山甲日志（实测 log-api.*）' },
  { domain: 'zijieapi.com', matchType: MATCH_SUFFIX, enabled: true, note: '字节 SDK（实测 log./mon./log-klink.）' },
  { domain: 'p3-be-pack-sign.pglstatp-toutiao.com', matchType: MATCH_EXACT, enabled: true, note: '穿山甲素材包签名，纯广告元数据（诊断 topForwarded 2 次）' },
  // ---------- 广点通（腾讯）----------
  { domain: 'gdt.qq.com', matchType: MATCH_SUFFIX, enabled: true, note: '广点通（实测 mi.21 次 / win. / v2.）' },
  { domain: 'sdk.e.qq.com', matchType: MATCH_EXACT, enabled: true, note: '广点通 SDK 入口（与 gdt.qq.com 同 IP 段 157.255.x）；⛔ 不可放宽为 e.qq.com，腾讯大量业务共用' },
  // ---------- 聚合广告 ----------
  { domain: 'sogaha.cn', matchType: MATCH_SUFFIX, enabled: true, note: '聚合广告 SDK（实测 ctrace.15 次 / adx.7 次）' },
  // ---------- 待实测确认（默认关，避免误伤业务）----------
  { domain: 'ssp.yg84.com', matchType: MATCH_EXACT, enabled: false, note: '疑似广告 SSP（华为云 openresty、空响应体）；仅命名与响应形态为证，多跑几次再定' },
  { domain: 'sf3-fe-tos.pglstatp-toutiao.com', matchType: MATCH_EXACT, enabled: false, note: '穿山甲素材 CDN（Mac 代理侧抓到）；拦后可能只剩空白占位，需与 D 级对比' },
  { domain: 'pglstatp-toutiao.com', matchType: MATCH_SUFFIX, enabled: false, note: '穿山甲 CDN 全域兜底；可能与正常素材共用，非必要不开' }
];

/** 白名单：优先级高于黑名单（FR-3.3） */
export const WHITELIST: Array<DomainRule> = [
  // 支付 / 银行：永久放行（FR-3.3）
  { domain: 'alipay.com', matchType: MATCH_SUFFIX, enabled: true, note: '支付类，永久放行' },
  { domain: 'unionpay.com', matchType: MATCH_SUFFIX, enabled: true, note: '支付类，永久放行' },
  { domain: 'icbc.com.cn', matchType: MATCH_SUFFIX, enabled: true, note: '银行，永久放行' },
  { domain: 'cmbchina.com', matchType: MATCH_SUFFIX, enabled: true, note: '银行，永久放行' },
  // 观测到但判定不拦（诊断页 topForwarded）——留在这里防以后加宽泛后缀时误伤
  { domain: 'api.chelaile.net.cn', matchType: MATCH_EXACT, enabled: true, note: '车来了主 API' },
  { domain: 'atrace.chelaile.net.cn', matchType: MATCH_EXACT, enabled: true, note: '车来了埋点（拦了可能影响数据上报/功能）' },
  { domain: 'logs.chelaile.net.cn', matchType: MATCH_EXACT, enabled: true, note: '车来了日志' },
  { domain: 'pro.bugly.qq.com', matchType: MATCH_EXACT, enabled: true, note: '腾讯 Bugly 崩溃上报，拦了影响问题定位' },
  { domain: 'apmplus.volces.com', matchType: MATCH_EXACT, enabled: true, note: '字节 APM 性能监控' }
];

/**
 * 命中黑名单时的应答方式（PRD 未决项 1，由 V4 实测选择）：
 *   'nxdomain' → RCODE=3，语义「域名不存在」
 *   'zero'     → A 记录 0.0.0.0，语义「解析成功但连不上」
 */
export const RESPONSE_MODE_NXDOMAIN: string = 'nxdomain';
export const RESPONSE_MODE_ZERO: string = 'zero';
export const RESPONSE_MODE: string = RESPONSE_MODE_ZERO;   // 对比实验：改回 NXDOMAIN 可切回

/** 上游 DNS（PRD 未决项 2）：先用阿里 DNS，实测可换系统原 DNS */
export const UPSTREAM_DNS: string = '223.5.5.5';

/** 上游查询超时（ms），超时返回 SERVFAIL（AD-5） */
export const UPSTREAM_TIMEOUT_MS: number = 3000;

/** 同时在途的转发任务上限，超限直接 SERVFAIL，防内存膨胀（AD-5） */
export const MAX_INFLIGHT: number = 64;

/**
 * PoC 运行上限（ms）：到时自动销毁 VPN，避免长时间接管流量。
 * MVP 阶段应改为手动开关（PRD FR-6）。
 */
export const AUTO_STOP_MS: number = 120000;
