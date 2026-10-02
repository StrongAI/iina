// usage: keys <step>...
// Posts key presses to the frontmost app through the HID event tap, as the keyboard does. A step is
// <keycode>, <keycode>:cmd for the key with Command held, or delay:<seconds>. Posting needs the
// Accessibility permission, which processes started over ssh on Glebs-Mac-Mini hold; Apple events to
// System Events from such a process wait for a consent prompt instead.
import Foundation
import CoreGraphics
let src = CGEventSource(stateID: .hidSystemState)
for step in CommandLine.arguments.dropFirst() {
  if step.hasPrefix("delay:"), let s = Double(step.dropFirst(6)) { usleep(useconds_t(s * 1_000_000)); continue }
  let parts = step.split(separator: ":")
  guard let code = CGKeyCode(parts[0]) else { print("bad step \(step)"); exit(2) }
  let flags: CGEventFlags = parts.count > 1 && parts[1] == "cmd" ? .maskCommand : []
  for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { print("no event"); exit(3) }
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(20_000)
  }
}
