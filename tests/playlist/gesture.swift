import CoreGraphics
import Foundation
// usage: gesture x y step...
// steps: wheel:<delta>:<count>:<intervalMs>     notches of a mouse wheel (no phase, not continuous)
//        begin:<delta>                          fingers start moving on the trackpad
//        move:<delta>:<count>:<intervalMs>      fingers keep moving
//        end                                    fingers lift
//        momentum:<delta>:<count>:<intervalMs>  momentum after the fingers lift
//        sleep:<ms>
// The delta is horizontal.
let a = CommandLine.arguments
let pt = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(200_000)
func post(_ d: Int32, continuous: Bool, phase: Int64, momentum: Int64) {
  let e = CGEvent(scrollWheelEvent2Source: src, units: continuous ? .pixel : .line, wheelCount: 2, wheel1: 0, wheel2: d, wheel3: 0)!
  e.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
  e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
  e.location = pt
  e.post(tap: .cghidEventTap)
}
for step in a.dropFirst(3) {
  let p = step.split(separator: ":").map(String.init)
  func n(_ i: Int) -> Int32 { Int32(p[i])! }
  switch p[0] {
  case "wheel":
    for _ in 0..<n(2) { post(n(1), continuous: false, phase: 0, momentum: 0); usleep(UInt32(n(3)) * 1000) }
  case "begin":
    post(n(1), continuous: true, phase: 1, momentum: 0)
  case "move":
    for _ in 0..<n(2) { post(n(1), continuous: true, phase: 2, momentum: 0); usleep(UInt32(n(3)) * 1000) }
  case "end":
    post(0, continuous: true, phase: 4, momentum: 0)
  case "momentum":
    post(n(1), continuous: true, phase: 0, momentum: 1); usleep(UInt32(n(3)) * 1000)
    for _ in 0..<n(2) { post(n(1), continuous: true, phase: 0, momentum: 2); usleep(UInt32(n(3)) * 1000) }
    post(0, continuous: true, phase: 0, momentum: 3)
  case "sleep":
    usleep(UInt32(n(1)) * 1000)
  default:
    fatalError("unknown step \(step)")
  }
}
