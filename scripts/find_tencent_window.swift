#!/usr/bin/env swift
// find_tencent_window.swift — Print the Tencent Meeting window ID
//
// Usage: swift find_tencent_window.swift
// Output: window ID (or empty)

import CoreGraphics

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(0)
}

var best: (id: Int, area: Int) = (0, 0)
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    guard let bounds = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    if (owner.contains("Tencent") || owner.contains("WeMeet") || owner.contains("腾讯会议")),
       width > 200, height > 200 {
        // CGWindowList 从前到后排序：取第一个（最前、用户可见的）足够大的窗口，
        // 避免选中残留的全屏僵尸窗口
        best = (wid, width * height)
        break
    }
}
if best.id != 0 {
    print(best.id)
}
