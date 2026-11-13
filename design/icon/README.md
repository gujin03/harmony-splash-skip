# 桌面图标设计资产（HarmonyOS 分层图标）

## 为什么改

原 `app_icon.png`／`icon.png` 是 DevEco 模板留下的 **128×128 纯色蓝块**（`#2E6BE6`，整图仅 257 字节、无图形），桌面显示就是一块蓝，等于没有图标。同时它也不符合华为《通用应用 UX 体验标准》**2.1.4.3.1 应用图标**的强制要求。

## 规范要点

| 项 | 要求 |
|---|---|
| 结构 | 必须分**前景图 + 背景图**两层，通过 `layered_image.json` 组合 |
| 尺寸 | 两层各 **1024×1024 px** |
| 背景层 | 铺满画布、**不允许任何透明像素**，建议纯色；不放文字与关键图形 |
| 前景层 | 透明底，主体居中并留在**中央安全区**（本设计主体约占画布 62%，系统遮罩还会再缩约 0.8） |
| 禁止 | ⛔ 自己裁圆角、⛔ 资源内加内间距、⛔ 自带投影／描边／白边、⛔ 放文字（系统统一加遮罩与视差，二次裁切会出现「双圆角」） |
| 小尺寸 | 需在 48 px 下仍可辨（桌面／通知／最近任务），见 `output/size_check.png` |

⚠️ **配置优先级**：带 `entity.system.home` + home action 的 UIAbility，其 `module.json5` 的 `icon` **优先于** `app.json5`；桌面图标由 HAP 内的 `module.json5` 决定。
⚠️ **同名覆盖**：编译时 AppScope 与 entry 的资源会合并，同名文件互相覆盖。故 AppScope 一律加 `app_` 前缀（`app_foreground` / `app_background` / `app_layered_image`），entry 用不带前缀的名字。
⚠️ `startWindowIcon` 保持引用**单层合成图** `icon.png`（启动窗口不叠分层遮罩）。

## 文件布局

```
AppScope/resources/base/media/
  app_foreground.png          前景（透明）
  app_background.png          背景（不透明纯色）
  app_layered_image.json      分层索引 → app.json5 的 icon
  app_icon.png                单层合成图（备用／设置页）
entry/src/main/resources/base/media/
  foreground.png              前景（透明）
  background.png              背景（不透明纯色）
  layered_image.json          分层索引 → module.json5 的 icon（桌面实际使用）
  icon.png                    单层合成图 → startWindowIcon
```

## 三套候选

| 方案 | 概念 | 形态 | 评价 |
|---|---|---|---|
| **A（已采用）** | 盾内快进 | 浅青渐变盾牌，镂空出标准 skip 符号 | 拦截 + 跳过双重语义，48 px 仍清晰，最稳 |
| B | 破环快进 | 开口白环 + 青色快进箭头 | 更动感，语义略抽象 |
| C | 切断开屏页 | 白色卡片被斜缝切断，箭头从断口冲出 | 最有设计感，但箭头与斜缝重叠，小尺寸易糊 |

预览：`output/preview.png`；小尺寸检验：`output/size_check.png`。

## 再生成 / 换方案

矢量真相源是 `generate_icon.swift`（macOS 自带 swiftc，零第三方依赖）：

```bash
cd ~/WorkBuddy/harmony-splash-skip/design/icon
swiftc -O generate_icon.swift -o /tmp/gen_icon && /tmp/gen_icon
```

想换成 B 或 C，把 `output/<方案>/` 里的 `foreground.png`／`background.png`／`merged.png`
分别复制到上述 6 个资源位置（保持目标文件名不变），重新 `assembleHap` 装机即可。
调主体大小改 `drawA()` 里的 `w` / `h` 与 `skipPaths(...)` 的 scale。

> 为什么用矢量脚本而不是 AI 生图：分层图标要求精确 alpha 通道、纯色不透明背景和固定安全区，
> AI 位图自带的圆角／阴影／背景会被系统二次裁切，属规范明确禁止的做法。
