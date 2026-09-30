import CoreGraphics
import ApplicationServices
print("postEvent:", CGPreflightPostEventAccess(), "axTrusted:", AXIsProcessTrusted())
if let e = CGEvent(source: nil) { print("cursor:", e.location) }
