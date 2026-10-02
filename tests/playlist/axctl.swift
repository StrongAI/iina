// usage: axctl <app> list
//        axctl <app> slide <fraction>
//        axctl <app> center
// Lists the buttons and sliders in the windows of the IINA copy at <app>, or clicks the play slider
// (the widest slider) at <fraction> of its width as a user would and prints the value it then holds.
// The pointer is first moved over the player window so that the on-screen controls are shown; hidden
// controls are not in the accessibility tree. Tables, lists and scroll areas are not searched.
// center prints the center of the player window in screen coordinates as "x y", the point the scroll
// tests post their events at.
import AppKit
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: axctl <app> list | slide <fraction> | center"); exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina")
  .first(where: { $0.bundleURL?.path == args[1] }) else { print("not running"); exit(3) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(ax, 1.0)
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func text(_ e: AXUIElement, _ name: String) -> String {
  let v = attr(e, name)
  return (v as? String) ?? (v as? NSNumber)?.stringValue ?? "-"
}
func point(_ e: AXUIElement) -> CGPoint {
  var p = CGPoint.zero
  if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
  return p
}
func size(_ e: AXUIElement) -> CGSize {
  var s = CGSize.zero
  if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
  return s
}
let skipped: Set<String> = [kAXTableRole, kAXOutlineRole, kAXListRole, kAXScrollAreaRole, kAXMenuBarRole]
func controls(_ e: AXUIElement, _ out: inout [AXUIElement], _ depth: Int) {
  guard depth < 12 else { return }
  let role = text(e, kAXRoleAttribute)
  if role == kAXSliderRole || role == kAXButtonRole { out.append(e); return }
  if skipped.contains(role) { return }
  for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { controls(c, &out, depth + 1) }
}
func scan() -> [AXUIElement] {
  var found: [AXUIElement] = []
  for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { controls(w, &found, 0) }
  return found
}
func post(_ type: CGEventType, _ p: CGPoint) {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
switch args[2] {
case "list":
  for c in scan() {
    print(text(c, kAXRoleAttribute), "value=\(text(c, kAXValueAttribute))", "max=\(text(c, kAXMaxValueAttribute))",
          "x=\(Int(point(c).x)) y=\(Int(point(c).y)) width=\(Int(size(c).width))")
  }
case "slide":
  guard args.count == 4, let fraction = Double(args[3]) else { print("bad arguments"); exit(2) }
  guard let window = (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first else { print("no window"); exit(4) }
  let wp = point(window), ws = size(window)
  for dx in [0.4, 0.5, 0.6] {
    post(.mouseMoved, CGPoint(x: wp.x + ws.width * dx, y: wp.y + ws.height * 0.5)); usleep(100_000)
  }
  usleep(400_000)
  guard let slider = scan().filter({ text($0, kAXRoleAttribute) == kAXSliderRole })
    .max(by: { size($0).width < size($1).width }) else { print("no slider"); exit(5) }
  let p = point(slider), s = size(slider)
  let target = CGPoint(x: p.x + s.width * fraction, y: p.y + s.height / 2)
  post(.mouseMoved, target); usleep(50_000)
  post(.leftMouseDown, target); usleep(50_000)
  post(.leftMouseUp, target); usleep(300_000)
  print("slider value=\(text(slider, kAXValueAttribute)) max=\(text(slider, kAXMaxValueAttribute))")
case "center":
  guard let window = (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first else { print("no window"); exit(4) }
  let wp = point(window), ws = size(window)
  print(Int(wp.x + ws.width / 2), Int(wp.y + ws.height / 2))
default:
  print("unknown command"); exit(2)
}
