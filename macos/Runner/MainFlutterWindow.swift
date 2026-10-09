import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 最小窗口尺寸（规格 §3.2 建议 480×360）。
    // 游戏规则运行在固定的 800×600 逻辑画布上，窗口缩小只是等比缩小显示，
    // 因此即使不加这条限制也不会出错；设置下限是为了保证可玩性 ——
    // 窗口过小时 HUD 与舰队会小到难以辨认。
    self.contentMinSize = NSSize(width: 480, height: 360)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
