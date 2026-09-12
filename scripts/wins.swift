import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "Pulse" {
    print(w["kCGWindowNumber"] ?? "", w["kCGWindowLayer"] ?? "", w["kCGWindowIsOnscreen"] ?? "off", w["kCGWindowBounds"] ?? "", w["kCGWindowAlpha"] ?? "")
}
