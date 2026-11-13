/**
 * 规则初始化决策（F-2 修复核心，纯函数、可单测）
 *
 * 决定启动时（或 rules.json 损坏恢复时）的规则加载策略：
 *  - 'seed'   ：文件不存在 → 写入内置默认规则
 *  - 'load'   ：文件存在且可读 → 以文件为准
 *  - 'reseed' ：文件存在但读不出来（半写／损坏／权限异常）→ 回退内置默认并写回
 *
 * ⛔ 关键不变式：损坏场景必须返回 'reseed'，**绝不能静默保留空规则**。
 *    否则 VPN 照常运行却一条都不拦，且无任何提示——这正是 F-2 修复要杜绝的回归。
 *
 * 本模块不依赖任何 @ohos.*，可直接在 Node 下跑单测（见 test/rule-init.test.ts）。
 */

export type InitAction = 'seed' | 'load' | 'reseed';

/**
 * @param fileExists 规则文件是否存在
 * @param readable   文件是否能被成功解析为 RulesFile（false 表示半写/损坏/权限异常）
 */
export function decideInit(fileExists: boolean, readable: boolean): InitAction {
  if (!fileExists) {
    return 'seed';
  }
  if (!readable) {
    return 'reseed';
  }
  return 'load';
}
