/**
 * 开屏跳过 · 桌面图标生成器（HarmonyOS 分层图标）
 *
 * 规范依据：华为《通用应用 UX 体验标准》2.1.4.3.1 +《配置分层图标》
 *   - 前景图 / 背景图各 1024×1024 PNG
 *   - 背景层不透明、纯色；前景层透明，主体居中且留在安全区内
 *   - 不自行裁圆角、不加内间距 / 投影 / 文字（系统统一加遮罩与视差）
 *
 * 运行（macOS 自带 swiftc，零第三方依赖）：
 *   swiftc -O generate_icon.swift -o /tmp/gen_icon && /tmp/gen_icon
 *
 * 产物：output/A|B|C/{foreground,background,merged}.png + preview.png + size_check.png
 *
 * ⚠️ 用矢量绘制而非 AI 位图：分层图标要求精确 alpha 通道与安全区，
 *    AI 生图自带的圆角 / 背景 / 阴影会被系统二次裁切，出现「双圆角」「白边」。
 */

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

let S: CGFloat = 1024
let OUT = "$HOME/WorkBuddy/harmony-splash-skip/design/icon/output"

// MARK: - 基础工具

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(red: CGFloat((hex >> 16) & 255) / 255,
          green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255,
          alpha: a)
}

func newCtx(_ side: Int) -> CGContext {
  CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// 转成「原点在左上、y 向下」的设计坐标系
func flip(_ c: CGContext, _ side: CGFloat) {
  c.translateBy(x: 0, y: side)
  c.scaleBy(x: 1, y: -1)
}

func writePNG(_ c: CGContext, _ path: String) {
  let img = c.makeImage()!
  let url = URL(fileURLWithPath: path) as CFURL
  let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img, nil)
  precondition(CGImageDestinationFinalize(dest), "写 PNG 失败：\(path)")
}

func fillRect(_ c: CGContext, _ rect: CGRect, _ color: CGColor) {
  c.setFillColor(color)
  c.fill(rect)
}

func tri(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
  let p = CGMutablePath()
  p.move(to: CGPoint(x: x, y: y))
  p.addLine(to: CGPoint(x: x + w, y: y + h / 2))
  p.addLine(to: CGPoint(x: x, y: y + h))
  p.closeSubpath()
  c.addPath(p)
}

/// 标准「skip / 快进」符号：两个右向三角 + 一条竖线
func skipPaths(_ cx: CGFloat, _ cy: CGFloat, _ scale: CGFloat = 1) -> CGPath {
  let w: CGFloat = 104 * scale
  let h: CGFloat = 172 * scale
  let gap: CGFloat = 12 * scale
  let barW: CGFloat = 34 * scale
  let total = w * 2 + gap + barW + 8 * scale
  let x0 = cx - total / 2
  let y0 = cy - h / 2
  let p = CGMutablePath()
  p.move(to: CGPoint(x: x0, y: y0))
  p.addLine(to: CGPoint(x: x0 + w, y: y0 + h / 2))
  p.addLine(to: CGPoint(x: x0, y: y0 + h))
  p.closeSubpath()
  p.move(to: CGPoint(x: x0 + w + gap, y: y0))
  p.addLine(to: CGPoint(x: x0 + w * 2 + gap, y: y0 + h / 2))
  p.addLine(to: CGPoint(x: x0 + w + gap, y: y0 + h))
  p.closeSubpath()
  let bx = x0 + w * 2 + gap + 8 * scale
  p.addRect(CGRect(x: bx, y: y0, width: barW, height: h))
  return p
}

// MARK: - 方案 A：盾内快进（推荐）
// 盾 = 拦截/防护，镂空的 skip 符号 = 跳过开屏。两层语义，小尺寸可辨。

func drawA(_ c: CGContext) {
  let cx = S / 2
  // 主体占画布约 62%：系统遮罩会把前景再缩约 0.8，装机实测 56% 时桌面留白偏多
  let w: CGFloat = 556
  let h: CGFloat = 640
  let top = (S - h) / 2
  let r: CGFloat = 110

  let shield = CGMutablePath()
  shield.move(to: CGPoint(x: cx - w / 2, y: top + r))
  shield.addQuadCurve(to: CGPoint(x: cx - w / 2 + r, y: top),
                      control: CGPoint(x: cx - w / 2, y: top))
  shield.addLine(to: CGPoint(x: cx + w / 2 - r, y: top))
  shield.addQuadCurve(to: CGPoint(x: cx + w / 2, y: top + r),
                      control: CGPoint(x: cx + w / 2, y: top))
  shield.addLine(to: CGPoint(x: cx + w / 2, y: top + h * 0.58))
  shield.addQuadCurve(to: CGPoint(x: cx, y: top + h),
                      control: CGPoint(x: cx + w / 2, y: top + h * 0.86))
  shield.addQuadCurve(to: CGPoint(x: cx - w / 2, y: top + h * 0.58),
                      control: CGPoint(x: cx - w / 2, y: top + h * 0.86))
  shield.closeSubpath()

  // 盾体：白 → 浅青的线性渐变
  c.saveGState()
  c.addPath(shield)
  c.clip()
  let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [rgb(0xFFFFFF), rgb(0x8FF0D2)] as CFArray,
                        locations: [0.0, 1.0])!
  c.drawLinearGradient(grad,
                       start: CGPoint(x: cx - w / 2, y: top),
                       end: CGPoint(x: cx + w / 2, y: top + h),
                       options: [])
  c.restoreGState()

  // 镂空出 skip 符号（擦成透明，叠到底色上）
  c.setBlendMode(.clear)
  c.setFillColor(rgb(0x000000))
  c.addPath(skipPaths(cx, top + h * 0.45, 1.12))
  c.fillPath()
  c.setBlendMode(.normal)
}

// MARK: - 方案 B：破环快进
// 开口圆环 = 打断广告加载循环，环内青色快进 = 直接进主界面。

func drawB(_ c: CGContext) {
  let cx = S / 2
  let cy = S / 2
  let radius: CGFloat = 262

  c.setStrokeColor(rgb(0xFFFFFF))
  c.setLineWidth(62)
  c.setLineCap(.round)
  // 右上留 62° 缺口（-40° → 298°）
  c.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
           startAngle: -40 * .pi / 180, endAngle: 298 * .pi / 180, clockwise: false)
  c.strokePath()

  // 环内快进：青绿渐变
  c.saveGState()
  c.setFillColor(rgb(0x4FE3C1))
  c.addPath(skipPaths(cx, cy, 0.92))
  c.fillPath()
  c.restoreGState()

  // 缺口端点一个强调圆点
  c.setFillColor(rgb(0x4FE3C1))
  let a: CGFloat = -40 * .pi / 180
  c.fillEllipse(in: CGRect(x: cx + radius * cos(a) - 30,
                           y: cy - radius * sin(a) - 30,
                           width: 60, height: 60))
}

// MARK: - 方案 C：切断开屏页
// 白色开屏卡片被一道斜缝切断，青色快进箭头从断口冲出。

func drawC(_ c: CGContext) {
  let cx = S / 2
  let cy = S / 2
  let w: CGFloat = 520
  let h: CGFloat = 576
  let card = CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                    cornerWidth: 92, cornerHeight: 92, transform: nil)

  c.setFillColor(rgb(0xFFFFFF))
  c.addPath(card)
  c.fillPath()

  // 45° 斜缝：擦成透明，把卡片切成两半
  c.setBlendMode(.clear)
  c.setStrokeColor(rgb(0x000000))
  c.setLineWidth(78)
  c.setLineCap(.round)
  c.move(to: CGPoint(x: cx - 430, y: cy + 330))
  c.addLine(to: CGPoint(x: cx + 430, y: cy - 330))
  c.strokePath()
  c.setBlendMode(.normal)

  // 断口右上方冲出的青色快进箭头
  c.saveGState()
  c.setFillColor(rgb(0x4FE3C1))
  c.addPath(skipPaths(cx + 26, cy - 12, 0.86))
  c.fillPath()
  c.restoreGState()
}

// MARK: - 生成三层产物

struct Scheme {
  let tag: String
  let title: String
  let bg: UInt32
  let draw: (CGContext) -> Void
}

let schemes: [Scheme] = [
  Scheme(tag: "A", title: "SHIELD  /  盾内快进", bg: 0x0E2A4C, draw: drawA),
  Scheme(tag: "B", title: "BREAK  /  破环快进", bg: 0x123A6B, draw: drawB),
  Scheme(tag: "C", title: "CUT  /  切断开屏页", bg: 0x0B2545, draw: drawC)
]

var mergedImages: [(String, CGImage)] = []

for s in schemes {
  let dir = OUT + "/" + s.tag
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

  // 背景层：纯色、不透明、无圆角
  let bg = newCtx(Int(S))
  fillRect(bg, CGRect(x: 0, y: 0, width: S, height: S), rgb(s.bg))
  writePNG(bg, dir + "/background.png")

  // 前景层：透明底，主体居中
  let fg = newCtx(Int(S))
  flip(fg, S)
  fg.setAllowsAntialiasing(true)
  fg.setShouldAntialias(true)
  fg.interpolationQuality = .high
  s.draw(fg)
  writePNG(fg, dir + "/foreground.png")

  // 单层合成图（给 startWindowIcon / 设置页 / 商店用，不裁圆角）
  let merged = newCtx(Int(S))
  merged.draw(bg.makeImage()!, in: CGRect(x: 0, y: 0, width: S, height: S))
  merged.draw(fg.makeImage()!, in: CGRect(x: 0, y: 0, width: S, height: S))
  writePNG(merged, dir + "/merged.png")
  mergedImages.append((s.tag, merged.makeImage()!))
  print("✓ \(s.tag) foreground / background / merged → \(dir)")
}

// MARK: - 对比预览（模拟桌面圆角遮罩）

func roundedIcon(_ c: CGContext, _ img: CGImage, _ rect: CGRect, _ radius: CGFloat) {
  c.saveGState()
  let p = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
  c.addPath(p)
  c.clip()
  c.draw(img, in: rect)
  c.restoreGState()
}

func label(_ c: CGContext, _ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: CGColor) {
  let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, size, nil)
  let attrs: CFDictionary = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: color
  ] as CFDictionary
  let str = CFAttributedStringCreate(nil, text as CFString, attrs)!
  let line = CTLineCreateWithAttributedString(str)
  c.saveGState()
  c.textMatrix = .identity
  c.textPosition = CGPoint(x: x, y: y)
  CTLineDraw(line, c)
  c.restoreGState()
}

do {
  let W = 1800, H = 760
  let pv = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  fillRect(pv, CGRect(x: 0, y: 0, width: W, height: H), rgb(0x0C121B))
  let side: CGFloat = 480
  let y: CGFloat = 200
  for (i, item) in mergedImages.enumerated() {
    let x: CGFloat = 90 + CGFloat(i) * 560
    roundedIcon(pv, item.1, CGRect(x: x, y: y, width: side, height: side), 106)
    label(pv, schemes[i].title, x, 150, 30, rgb(0xFFFFFF))
    label(pv, "方案 \(schemes[i].tag)", x, 105, 26, rgb(0x8FA6C0))
  }
  label(pv, "开屏跳过  ·  HarmonyOS 分层图标候选（系统圆角遮罩模拟）", 90, 700, 30, rgb(0x4FE3C1))
  label(pv, "foreground 1024px 透明  +  background 1024px 不透明  ·  主体位于中央安全区", 90, 40, 24, rgb(0x8FA6C0))
  writePNG(pv, OUT + "/preview.png")
  print("✓ preview.png")
}

// MARK: - 小尺寸可读性检验（48 / 64 / 96 / 128 vp 等效）

do {
  let W = 1000, H = 300
  let sc = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  fillRect(sc, CGRect(x: 0, y: 0, width: W, height: H), rgb(0x0C121B))
  let sizes: [CGFloat] = [128, 96, 64, 48]
  var x: CGFloat = 90
  for (i, sz) in sizes.enumerated() {
    let y: CGFloat = 110
    roundedIcon(sc, mergedImages[0].1, CGRect(x: x, y: y, width: sz, height: sz), sz * 0.22)
    label(sc, "\(Int(sz)) px", x, 70, 22, rgb(0x8FA6C0))
    x += sz + 110
    _ = i
  }
  label(sc, "方案 A 小尺寸可读性检验（桌面 / 通知 / 最近任务）", 90, 250, 26, rgb(0xFFFFFF))
  writePNG(sc, OUT + "/size_check.png")
  print("✓ size_check.png")
}

print("完成：\(OUT)")
