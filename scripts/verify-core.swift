import AppKit
import Foundation
import CoreGraphics
import ImageIO

/// Runs without XCTest/SwiftPM so the prototype can be verified with Command Line Tools.
@main
enum CoreVerification {
    private static var failures = 0
    private static var scenarios = 0

    static func main() {
        verify("AppKit 区域转换为屏幕左上坐标") {
            let region = CaptureRegion(rect: CGRect(x: 100, y: 200, width: 400, height: 300),
                                       displayID: 1, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       scale: 2, targetPID: nil)
            equal(region.sourceRect, CGRect(x: 100, y: 400, width: 400, height: 300), "主屏幕 sourceRect")
        }
        verify("负坐标副屏使用自身坐标原点") {
            let region = CaptureRegion(rect: CGRect(x: -1300, y: 200, width: 400, height: 300),
                                       displayID: 2, screenFrame: CGRect(x: -1440, y: 100, width: 1440, height: 900),
                                       scale: 1, targetPID: nil)
            equal(region.sourceRect, CGRect(x: 140, y: 500, width: 400, height: 300), "副屏幕 sourceRect")
        }
        let targetWindow = window(number: 1111, owner: 101, bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
        verify("按系统实际命中的窗口号识别目标进程") {
            let overlay = window(number: 2222, owner: 202, bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
            equal(ScrollEventRouting.owner(ofWindow: 1111, windows: [overlay, targetWindow]),
                  101, "不把矩形前层窗口误认为输入目标")
        }
        verify("浮窗覆盖选区中心时阻止向底层应用滚动") {
            let overlay = window(number: 2222, owner: 202, bounds: CGRect(x: 300, y: 200, width: 380, height: 500))
            let owner = ScrollEventRouting.owner(ofWindow: 2222, windows: [overlay, targetWindow])
            equal(owner, 202, "最前窗口优先")
            require(owner != 101, "被遮挡的目标不能收到自动滚动")
        }
        verify("无命中或窗口元数据缺失时拒绝投递") {
            equal(ScrollEventRouting.owner(ofWindow: 0, windows: [targetWindow]), nil, "无输入目标")
            equal(ScrollEventRouting.owner(ofWindow: 9999, windows: [targetWindow]), nil, "无法确认所有者")
        }
        verify("左侧扩展屏使用全局负坐标检查滚动目标") {
            let secondary = window(number: 3333, owner: 303, bounds: CGRect(x: -1440, y: -100, width: 1440, height: 900))
            equal(ScrollEventRouting.owner(ofWindow: 3333, windows: [targetWindow, secondary]), 303, "扩展屏窗口")
        }
        verify("预览应用对象的 PID 为 -1 时保留原始窗口进程号") {
            equal(ScrollEventRouting.captureTargetPID(windowOwnerPID: 54645, fallbackApplicationPID: -1),
                  54645, "不把有效窗口目标替换为 AppKit 的不可用 PID")
        }
        verify("无窗口进程号时仅允许有效应用 PID 回退") {
            equal(ScrollEventRouting.captureTargetPID(windowOwnerPID: nil, fallbackApplicationPID: 101),
                  101, "有效回退")
            equal(ScrollEventRouting.captureTargetPID(windowOwnerPID: nil, fallbackApplicationPID: -1),
                  nil, "无效回退")
        }
        let anchor = CGPoint(x: 600, y: 400)
        verify("鼠标停在滚动锚点时可以继续自动滚动") {
            require(!ScrollEventRouting.mouseMovedFromAnchor(current: anchor, anchor: anchor), "稳定鼠标不应暂停")
        }
        verify("Retina 舍入误差不会误暂停") {
            require(!ScrollEventRouting.mouseMovedFromAnchor(current: CGPoint(x: 601, y: 399), anchor: anchor),
                    "小于三点的舍入误差应允许")
        }
        verify("鼠标移向控制按钮时必须暂停，不能拉回锚点") {
            require(ScrollEventRouting.mouseMovedFromAnchor(current: CGPoint(x: 620, y: 400), anchor: anchor),
                    "用户移动鼠标应让出控制")
        }
        verify("鼠标跨屏或向负坐标移动时必须暂停") {
            require(ScrollEventRouting.mouseMovedFromAnchor(current: CGPoint(x: -700, y: 400), anchor: anchor),
                    "跨屏移动应让出控制")
        }
        verify("向下两次滚动输出完整且逐像素正确") {
            let stitcher = ScrollStitcher()
            equal(stitcher.append(image(top: 0)), .started(height: 90), "首帧")
            equal(stitcher.append(image(top: 27)), .appended(rows: 27, height: 117), "第一段")
            equal(stitcher.append(image(top: 58)), .appended(rows: 31, height: 148), "第二段")
            equalImage(stitcher.image(), image(height: 148, top: 0))
        }
        verify("向上两次滚动添加上方内容且图像方向正确") {
            let stitcher = ScrollStitcher(direction: .up)
            equal(stitcher.append(image(top: 100)), .started(height: 90), "首帧")
            equal(stitcher.append(image(top: 73)), .appended(rows: 27, height: 117), "第一段")
            equal(stitcher.append(image(top: 42)), .appended(rows: 31, height: 148), "第二段")
            equalImage(stitcher.image(), image(height: 148, top: 42))
        }
        verify("重复帧不增长") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            equal(stitcher.append(image(top: 0)), .duplicate, "重复帧")
            equal(stitcher.height, 90, "重复后高度")
        }
        verify("横向偏移暂停、保留结果、回正可继续") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            if case .paused(let message) = stitcher.append(image(top: 25, horizontal: 8)) {
                require(message.contains("左右偏移"), "必须解释横向偏移原因")
            } else {
                fail("横向偏移必须拒绝拼接")
            }
            equal(stitcher.height, 90, "拒绝后原结果高度")
            equal(stitcher.append(image(top: 25)), .appended(rows: 25, height: 115), "回正后继续")
        }
        verify("无关联内容暂停且不污染已有图像") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            if case .paused = stitcher.append(image(top: 35, seed: 728)) {} else {
                fail("无关联内容必须拒绝拼接")
            }
            equalImage(stitcher.image(), image(top: 0))
        }
        verify("反向回访中的横漂仍拒绝且保持文档位置") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            _ = stitcher.append(image(top: 58))
            if case .paused(let message) = stitcher.append(image(top: 27, horizontal: 8)) {
                require(message.contains("左右偏移"), "反向横漂必须明确拒绝")
            } else { fail("反向回访横漂不得污染结果") }
            equal(stitcher.lastOrigin, 58, "反向横漂拒绝保留位置")
            equalImage(stitcher.image(), image(height: 148, top: 0))
            equal(stitcher.append(image(top: 27)), .revisited(height: 148), "回正后反向恢复")
        }
        verify("长图预算按设备内存缩放并保留安全边界") {
            let mib = 1024 * 1024
            for (gib, expected) in [(0, 128), (4, 128), (8, 256), (16, 512), (64, 512)] {
                let limits = ScrollStitcher.Limits(physicalMemory: UInt64(gib) * 1024 * 1024 * 1024)
                equal(limits.maximumWorkingBytes, expected * mib, "设备内存预算")
                equal(limits.maximumHeight, 60_000, "原像素高度保护")
            }
            equal(ScrollStitcher.Limits.maximumInputBytes, 32 * mib, "单帧预算不随长图增长")
        }
        verify("高度上限保留已有可导出结果") {
            var limits = ScrollStitcher.Limits()
            limits.maximumHeight = 110
            let stitcher = ScrollStitcher(limits: limits)
            _ = stitcher.append(image(top: 0))
            if case .limitReached(.height) = stitcher.append(image(top: 30)) {} else {
                fail("达到高度上限必须停止增长")
            }
            equalImage(stitcher.image(), image(top: 0))
        }
        verify("双向来回只扩展未覆盖行，文档位置与最终像素精确") {
            let stitcher = ScrollStitcher()
            let positions = [0, 27, 58, 27, 0, -24, 15, 70]
            let updates: [ScrollStitcher.Update] = [.started(height: 90), .appended(rows: 27, height: 117),
                .appended(rows: 31, height: 148), .revisited(height: 148), .revisited(height: 148),
                .appended(rows: 24, height: 172), .revisited(height: 172), .appended(rows: 12, height: 184)]
            for (position, update) in zip(positions, updates) {
                equal(stitcher.append(image(top: position)), update, "位置 \(position)")
                equal(stitcher.lastOrigin, position, "上一帧文档位置")
            }
            equal(stitcher.minOrigin, -24, "覆盖上界")
            equal(stitcher.maxOrigin, 160, "覆盖下界")
            equalImage(stitcher.image(), image(height: 184, top: -24))
        }
        verify("兼容向上初始化但允许向下扩展与反向回访") {
            let stitcher = ScrollStitcher(direction: .up)
            equal(stitcher.append(image(top: 100)), .started(height: 90), "首帧")
            equal(stitcher.append(image(top: 73)), .appended(rows: 27, height: 117), "向上")
            equal(stitcher.append(image(top: 100)), .revisited(height: 117), "向下回访")
            equal(stitcher.append(image(top: 130)), .appended(rows: 30, height: 147), "向下越界")
            equal(stitcher.append(image(top: 100)), .revisited(height: 147), "再次向上回访")
            equalImage(stitcher.image(), image(height: 147, top: 73))
        }
        verify("回访与静止重复分开，往返不会重复增长") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            _ = stitcher.append(image(top: 30))
            for _ in 0..<4 {
                equal(stitcher.append(image(top: 0)), .revisited(height: 120), "回到已覆盖上端")
                equal(stitcher.append(image(top: 30)), .revisited(height: 120), "回到已覆盖下端")
            }
            equal(stitcher.append(image(top: 30)), .duplicate, "真正静止")
            equalImage(stitcher.image(), image(height: 120, top: 0))
        }
        verify("回访与已有覆盖区不一致时拒绝且保留定位") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            _ = stitcher.append(image(top: 27))
            _ = stitcher.append(image(top: 58))
            let changed = replacingTopRows(in: image(top: 0), count: 25)
            if case .paused(let message) = stitcher.append(changed) {
                require(message.contains("已拼接"), "必须解释与已有覆盖内容冲突")
            } else { fail("局部前帧吻合但覆盖内容已变化必须拒绝") }
            equal(stitcher.lastOrigin, 58, "拒绝不更新上一帧位置")
            equal(stitcher.minOrigin, 0, "拒绝不改变覆盖上界")
            equalImage(stitcher.image(), image(height: 148, top: 0))
            equal(stitcher.append(image(top: 27)), .revisited(height: 148), "回到有效位置可继续")
        }
        verify("快速无重叠跳转拒绝后仍可反向回访") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0))
            _ = stitcher.append(image(top: 58))
            if case .paused = stitcher.append(image(top: 160)) {} else { fail("过快跳转必须暂停") }
            equal(stitcher.lastOrigin, 58, "跳转拒绝保留位置")
            equalImage(stitcher.image(), image(height: 148, top: 0))
            equal(stitcher.append(image(top: 0)), .revisited(height: 148), "反向回访恢复")
        }
        verify("重复纹理双向匹配有歧义时不猜位置") {
            let stitcher = ScrollStitcher()
            _ = stitcher.append(image(top: 0, period: 12))
            if case .paused(let message) = stitcher.append(image(top: 5, period: 12)) {
                require(message.contains("重复"), "必须解释重复纹理歧义")
            } else { fail("重复纹理必须拒绝猜测位移") }
            equal(stitcher.lastOrigin, 0, "歧义不改变位置")
            equalImage(stitcher.image(), image(top: 0, period: 12))
        }
        verify("向上扩展的高度和内存上限保留原结果") {
            for limitedByMemory in [false, true] {
                var limits = ScrollStitcher.Limits()
                if limitedByMemory { limits.maximumWorkingBytes = 190_000 }
                else { limits.maximumHeight = 110 }
                let stitcher = ScrollStitcher(limits: limits)
                _ = stitcher.append(image(top: 0))
                if case .limitReached = stitcher.append(image(top: -30)) {} else { fail("向上增长越界必须停止") }
                equal(stitcher.lastOrigin, 0, "越界保留上一帧")
                equal(stitcher.minOrigin, 0, "越界保留覆盖上界")
                equalImage(stitcher.image(), image(top: 0))
                equal(stitcher.append(image(top: -5)), .appended(rows: 5, height: 95), "较小向上步幅可继续")
                equalImage(stitcher.image(), image(height: 95, top: -5))
            }
        }
        verify("编号重复文本的真实滚动不被误判为歧义，反向回访保留结果") {
            guard let before = fixture("scroll-numbered-before.png"),
                  let after = fixture("scroll-numbered-after.png") else { return }
            let stitcher = ScrollStitcher()
            equal(stitcher.append(before), .started(height: 564), "真实首帧")
            equal(stitcher.append(after), .appended(rows: 168, height: 732), "真实向下 168 像素")
            equal(stitcher.lastOrigin, 168, "正确行号定位")
            // Overlap is retained from the first frame; only the new bottom rows are added.
            var expected = decodedPixels(before)
            expected.append(decodedPixels(after).suffix(168 * after.width * 4))
            require(stitcher.image().map { decodedPixels($0) == expected } == true,
                    "必须保留首帧并精确拼入新增底部，不能错接重复行")
            equal(stitcher.append(before), .revisited(height: 732), "反向回访")
            equal(stitcher.lastOrigin, 0, "回到原始行号")
            require(stitcher.image().map { decodedPixels($0) == expected } == true, "回访不得污染结果")
        }
        verify("编号重复文本向上扩展时识别真实位移") {
            guard let before = fixture("scroll-numbered-before.png"),
                  let after = fixture("scroll-numbered-after.png") else { return }
            let stitcher = ScrollStitcher()
            _ = stitcher.append(after)
            equal(stitcher.append(before), .appended(rows: 168, height: 732), "向上 168 像素")
            equal(stitcher.minOrigin, -168, "上方边界")
        }
        print("\n验证结果：\(scenarios) 个场景，\(failures) 项失败。")
        exit(failures == 0 ? 0 : 1)
    }

    private static func verify(_ name: String, _ body: () -> Void) {
        scenarios += 1
        let previousFailures = failures
        body()
        print("\(previousFailures == failures ? "PASS" : "FAIL") \(name)")
    }

    private static func fixture(_ name: String) -> CGImage? {
        let directory = CommandLine.arguments.dropFirst().first ?? "scripts/fixtures"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fail("无法读取回归素材：\(url.path)")
            return nil
        }
        return image
    }

    private static func decodedPixels(_ image: CGImage) -> Data {
        var pixels = Data(count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private static func window(number: Int, owner: pid_t, bounds: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: number,
         kCGWindowOwnerPID as String: owner,
         kCGWindowBounds as String: bounds.dictionaryRepresentation,
         kCGWindowAlpha as String: 1.0]
    }

    private static func fail(_ message: String) {
        failures += 1
        print("  失败：\(message)")
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual != expected { fail("\(message)：期待 \(expected)，实际 \(actual)") }
    }

    private static func equalImage(_ actual: CGImage?, _ expected: CGImage) {
        guard let actual else { return fail("结果图像为空") }
        equal(actual.width, expected.width, "结果宽度")
        equal(actual.height, expected.height, "结果高度")
        guard let actualData = actual.dataProvider?.data,
              let expectedData = expected.dataProvider?.data else { return fail("无法读取图像像素") }
        require(actualData as Data == expectedData as Data, "结果像素与完整原始内容不一致")
    }

    private static func image(width: Int = 96, height: Int = 90, top: Int,
                              horizontal: Int = 0, seed: UInt32 = 19, period: Int? = nil) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = period.map { ((y + top) % $0 + $0) % $0 } ?? (y + top)
                var value = UInt32(truncatingIfNeeded: x + horizontal) &* 747_796_405 ^
                    UInt32(truncatingIfNeeded: row) &* 2_891_336_453 ^ seed
                value = (value ^ (value >> 16)) &* 2_246_822_519
                let index = (y * width + x) * 4
                bytes[index] = UInt8(truncatingIfNeeded: value)
                bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func replacingTopRows(in source: CGImage, count: Int) -> CGImage {
        var bytes = source.dataProvider!.data! as Data
        let replacement = image(width: source.width, height: source.height, top: 0, seed: 728).dataProvider!.data! as Data
        let changedBytes = min(count, source.height) * source.width * 4
        bytes.replaceSubrange(0..<changedBytes, with: replacement.prefix(changedBytes))
        return CGImage(width: source.width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
