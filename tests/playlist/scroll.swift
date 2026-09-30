import CoreGraphics
import Foundation
// usage: scroll x y delta phaseCount momentumCount intervalMs
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!, delta = Int32(a[3])!
let phaseCount = Int(a[4])!, momentumCount = Int(a[5])!, interval = UInt32(a[6])! * 1000
let src = CGEventSource(stateID: .hidSystemState)
let pt = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(200_000)
func post(_ d: Int32, phase: Int64, momentum: Int64) {
  let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: d, wheel3: 0)!
  e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
  e.location = pt
  e.post(tap: .cghidEventTap)
  usleep(interval)
}
post(delta, phase: 1, momentum: 0)
for _ in 0..<phaseCount { post(delta, phase: 2, momentum: 0) }
post(0, phase: 4, momentum: 0)
if momentumCount > 0 {
  post(delta, phase: 0, momentum: 1)
  for _ in 0..<momentumCount { post(delta, phase: 0, momentum: 2) }
  post(0, phase: 0, momentum: 3)
}
