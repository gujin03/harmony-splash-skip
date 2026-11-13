/**
 * 硬编码配置（PRD v0.3.0 / D4）。
 *
 * ⚠️ v0.3.0 变更：方案已从「无障碍点击」转向「本地 VPN + DNS 拦截」。
 *   本文件原有的 SKIP_TEXT_PATTERN / GUIDE_WORDS / DRY_RUN /
 *   BYPASS_TARGET_FILTER / OBSERVE_ALL_EVENTS / ENABLE_REGION_GUARD /
 *   REGION_RATIO / SESSION_GUARD_MS / MAX_WALK_* 等常量，
 *   全部随无障碍代码一并移除（PRD D9：直接移除，非保留停用）。
 *
 * ⚠️ D4 / R-11：目标包名**不控制拦截范围**——DNS 层拿不到请求方包名，
 *   域名规则全局生效。此列表仅用于诊断页的归集与展示。
 */

/** 观测目标应用（仅用于统计与诊断展示，PRD D4） */
export const TARGET_BUNDLES: Array<string> = [
  // 车来了：端到端已验证（阻断穿山甲后直接进主界面，等待约 4 秒）
  'com.ygkj.chelaile.standard.har'
];

/**
 * PoC 阶段：抓到第一条 DNS 查询即销毁 VPN，避免长时间接管用户流量。
 * MVP 阶段应改为 false，并实现「命中拦截 NXDOMAIN / 未命中转发上游」的完整闭环
 * （PRD §9.1 的 V4–V6 三项必过门槛）。
 */
export const AUTO_STOP_AFTER_FIRST_DNS: boolean = true;
