import Foundation
import CoreGraphics

@main
enum SelectionVerification {
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ name: String, _ actual: CGRect?, _ expected: CGRect?) {
            checks += 1
            let passed: Bool
            if let actual, let expected {
                passed = abs(actual.minX - expected.minX) < 0.001
                    && abs(actual.minY - expected.minY) < 0.001
                    && abs(actual.width - expected.width) < 0.001
                    && abs(actual.height - expected.height) < 0.001
            } else {
                passed = actual == nil && expected == nil
            }
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL") \(name)\(passed ? "" : ": actual=\(String(describing: actual)), expected=\(String(describing: expected))")")
        }

        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        check("主屏窗口从左上转换到左下", SelectionGeometry.windowRect(
            CGRect(x: 100, y: 100, width: 800, height: 500), primaryTop: 900, screenFrame: main),
            CGRect(x: 100, y: 300, width: 800, height: 500))
        let secondary = CGRect(x: -1280, y: -200, width: 1280, height: 1024)
        check("负原点副屏窗口转换为本地坐标", SelectionGeometry.windowRect(
            CGRect(x: -1200, y: 100, width: 500, height: 400), primaryTop: 900, screenFrame: secondary),
            CGRect(x: 80, y: 600, width: 500, height: 400))
        let crossing = CGRect(x: -100, y: 200, width: 300, height: 400)
        check("跨屏窗口裁到主屏", SelectionGeometry.windowRect(crossing, primaryTop: 900, screenFrame: main),
              CGRect(x: 0, y: 300, width: 200, height: 400))
        check("跨屏窗口裁到副屏", SelectionGeometry.windowRect(crossing, primaryTop: 900, screenFrame: secondary),
              CGRect(x: 1180, y: 500, width: 100, height: 400))
        check("窗口不足16点不成为选区", SelectionGeometry.windowRect(
            CGRect(x: 1430, y: 200, width: 100, height: 400), primaryTop: 900, screenFrame: main), nil)
        check("屏外窗口不成为选区", SelectionGeometry.windowRect(
            CGRect(x: 2000, y: 200, width: 100, height: 400), primaryTop: 900, screenFrame: main), nil)

        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let selection = CGRect(x: 100, y: 80, width: 80, height: 60)
        check("移动保持尺寸", SelectionGeometry.move(selection, by: CGSize(width: 20, height: 10), within: bounds),
              CGRect(x: 120, y: 90, width: 80, height: 60))
        check("移动限制到左下边缘", SelectionGeometry.move(selection, by: CGSize(width: -1000, height: -1000), within: bounds),
              CGRect(x: 10, y: 20, width: 80, height: 60))
        check("移动限制到右上边缘", SelectionGeometry.move(selection, by: CGSize(width: 1000, height: 1000), within: bounds),
              CGRect(x: 230, y: 160, width: 80, height: 60))

        let outward: [(SelectionHandle, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: -500, y: 500), CGRect(x: 10, y: 80, width: 170, height: 140)),
            (.top, CGPoint(x: -500, y: 500), CGRect(x: 100, y: 80, width: 80, height: 140)),
            (.topRight, CGPoint(x: 500, y: 500), CGRect(x: 100, y: 80, width: 210, height: 140)),
            (.right, CGPoint(x: 500, y: -500), CGRect(x: 100, y: 80, width: 210, height: 60)),
            (.bottomRight, CGPoint(x: 500, y: -500), CGRect(x: 100, y: 20, width: 210, height: 120)),
            (.bottom, CGPoint(x: 500, y: -500), CGRect(x: 100, y: 20, width: 80, height: 120)),
            (.bottomLeft, CGPoint(x: -500, y: -500), CGRect(x: 10, y: 20, width: 170, height: 120)),
            (.left, CGPoint(x: -500, y: 500), CGRect(x: 10, y: 80, width: 170, height: 60))
        ]
        for (handle, point, expected) in outward {
            check("\(handle)缩放固定对边并裁屏", SelectionGeometry.resize(selection, handle: handle, to: point, within: bounds), expected)
        }
        let inward: [(SelectionHandle, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 500, y: -500), CGRect(x: 164, y: 80, width: 16, height: 16)),
            (.top, CGPoint(x: 500, y: -500), CGRect(x: 100, y: 80, width: 80, height: 16)),
            (.topRight, CGPoint(x: -500, y: -500), CGRect(x: 100, y: 80, width: 16, height: 16)),
            (.right, CGPoint(x: -500, y: 500), CGRect(x: 100, y: 80, width: 16, height: 60)),
            (.bottomRight, CGPoint(x: -500, y: 500), CGRect(x: 100, y: 124, width: 16, height: 16)),
            (.bottom, CGPoint(x: -500, y: 500), CGRect(x: 100, y: 124, width: 80, height: 16)),
            (.bottomLeft, CGPoint(x: 500, y: 500), CGRect(x: 164, y: 124, width: 16, height: 16)),
            (.left, CGPoint(x: 500, y: -500), CGRect(x: 164, y: 80, width: 16, height: 60))
        ]
        for (handle, point, expected) in inward {
            check("\(handle)反向拖动不翻转且最小16点", SelectionGeometry.resize(selection, handle: handle, to: point, within: bounds), expected)
        }
        check("自定义最小尺寸", SelectionGeometry.resize(selection, handle: .right,
            to: CGPoint(x: 105, y: 100), within: bounds, minimumSize: 24),
            CGRect(x: 100, y: 80, width: 24, height: 60))
        let handlePoints: [(SelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: 100, y: 140)), (.top, CGPoint(x: 140, y: 140)),
            (.topRight, CGPoint(x: 180, y: 140)), (.right, CGPoint(x: 180, y: 110)),
            (.bottomRight, CGPoint(x: 180, y: 80)), (.bottom, CGPoint(x: 140, y: 80)),
            (.bottomLeft, CGPoint(x: 100, y: 80)), (.left, CGPoint(x: 100, y: 110))
        ]
        for (handle, expected) in handlePoints {
            check("\(handle)控制点位置", CGRect(origin: handle.point(in: selection), size: .zero),
                  CGRect(origin: expected, size: .zero))
        }

        check("Retina顶部选区使用图像左上像素", SelectionGeometry.pixelRect(
            CGRect(x: 100, y: 700, width: 400, height: 200), in: main, imageSize: CGSize(width: 2880, height: 1800)),
            CGRect(x: 200, y: 0, width: 800, height: 400))
        check("像素裁切裁屏幕边界", SelectionGeometry.pixelRect(
            CGRect(x: -10, y: 800, width: 110, height: 200), in: main, imageSize: CGSize(width: 2880, height: 1800)),
            CGRect(x: 0, y: 0, width: 200, height: 200))
        check("独立使用真实图像横纵比例", SelectionGeometry.pixelRect(
            CGRect(x: 110, y: 120, width: 50, height: 40), in: bounds, imageSize: CGSize(width: 900, height: 400)),
            CGRect(x: 300, y: 120, width: 150, height: 80))
        check("分数像素向外取整", SelectionGeometry.pixelRect(
            CGRect(x: 0.25, y: 0.25, width: 10, height: 10), in: main, imageSize: CGSize(width: 2880, height: 1800)),
            CGRect(x: 0, y: 1779, width: 21, height: 21))
        check("屏外选区返回空像素矩形", SelectionGeometry.pixelRect(
            CGRect(x: 2000, y: 100, width: 10, height: 10), in: main, imageSize: CGSize(width: 2880, height: 1800)), .zero)

        let toolbar = CGSize(width: 120, height: 40)
        check("工具栏默认放在选区下方", SelectionGeometry.toolbarFrame(selection: selection, size: toolbar, within: bounds),
              CGRect(x: 80, y: 28, width: 120, height: 40))
        check("底部空间不足时放到上方", SelectionGeometry.toolbarFrame(
            selection: CGRect(x: 100, y: 20, width: 80, height: 60), size: toolbar, within: bounds),
            CGRect(x: 80, y: 92, width: 120, height: 40))
        check("上下无空间时在屏内贴底", SelectionGeometry.toolbarFrame(selection: bounds, size: toolbar, within: bounds),
              CGRect(x: 100, y: 20, width: 120, height: 40))
        check("工具栏左边裁边", SelectionGeometry.toolbarFrame(
            selection: CGRect(x: 10, y: 80, width: 16, height: 60), size: toolbar, within: bounds),
            CGRect(x: 10, y: 28, width: 120, height: 40))
        check("工具栏右边裁边", SelectionGeometry.toolbarFrame(
            selection: CGRect(x: 294, y: 80, width: 16, height: 60), size: toolbar, within: bounds),
            CGRect(x: 190, y: 28, width: 120, height: 40))
        check("未选区时工具栏屏幕底部居中", SelectionGeometry.toolbarFrame(selection: nil, size: toolbar, within: bounds),
              CGRect(x: 100, y: 32, width: 120, height: 40))
        check("工具栏过大时保持屏幕内", SelectionGeometry.toolbarFrame(
            selection: bounds, size: CGSize(width: 500, height: 500), within: bounds), bounds)

        print("选区几何验证：\(checks) 个场景，\(failures) 项失败。无需屏幕或输入权限。")
        exit(failures == 0 ? 0 : 1)
    }
}
