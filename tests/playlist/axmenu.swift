// usage: axmenu <menu> <item>
// Presses a menu item of the IINA build under test through the accessibility API, without
// activating it. Only the copy at /Users/asher/Projects/Deployment/IINA/IINA.app is touched.
import AppKit
let target = "/Users/asher/Projects/Deployment/IINA/IINA.app"
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: axmenu <menu> <item>"); exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina")
  .first(where: { $0.bundleURL?.path == target }) else { print("not running"); exit(3) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func children(_ e: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
  return (v as? [AXUIElement]) ?? []
}
func title(_ e: AXUIElement) -> String {
  var v: CFTypeRef?
  AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &v)
  return (v as? String) ?? ""
}
var bar: CFTypeRef?
guard AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &bar) == .success else { print("no menu bar"); exit(4) }
guard let menu = children(bar as! AXUIElement).first(where: { title($0) == args[1] }),
      let list = children(menu).first,
      let item = children(list).first(where: { title($0) == args[2] }) else { print("no item"); exit(5) }
exit(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? 0 : 6)
