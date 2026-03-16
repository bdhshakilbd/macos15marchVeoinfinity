import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    
    // Set a proper large window size for desktop use
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    let windowWidth: CGFloat = min(1400, screenFrame.width * 0.85)
    let windowHeight: CGFloat = min(900, screenFrame.height * 0.85)
    let windowX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
    let windowY = screenFrame.origin.y + (screenFrame.height - windowHeight) / 2
    let newFrame = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
    
    self.contentViewController = flutterViewController
    self.setFrame(newFrame, display: true)
    self.minSize = NSSize(width: 800, height: 600)
    
    // Set delegate so we can handle window close
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
  
  // When user clicks the red X close button, terminate the app
  func windowWillClose(_ notification: Notification) {
    NSApplication.shared.terminate(self)
  }
}
