#!/usr/bin/env swift
// window_capture.swift — 使用 ScreenCaptureKit 捕获后台窗口
// 参考 Humla 的 sidecar 模式
//
// 用法:
//   window_capture.swift <window_id> <output_path> [width] [height]
//
// 编译:
//   swiftc -O window_capture.swift -o window_capture
//
// 注意: 需要屏幕录制权限（TCC），首次运行会弹出权限请求

import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 解析参数
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: window_capture <window_id> <output_path> [width] [height]\n".data(using: .utf8)!)
    exit(1)
}

let windowID = CGWindowID(Int32(args[1]) ?? 0)
let outputPath = args[2]
// 宽高可选：不传则按窗口原生像素分辨率输出（Retina 下为 2x，清晰度最高）
let outputWidth = args.count > 3 ? Int(args[3]) ?? 0 : 0
let outputHeight = args.count > 4 ? Int(args[4]) ?? 0 : 0

// 检查窗口是否有效
let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] ?? []
guard let windowInfo = windowList.first else {
    FileHandle.standardError.write("ERROR: 窗口不存在: \(windowID)\n".data(using: .utf8)!)
    exit(1)
}

let windowTitle = windowInfo[kCGWindowName as String] as? String ?? "unknown"
let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "unknown"
print("捕获窗口: [\(windowID)] \(ownerName) - \(windowTitle)")

// 使用 ScreenCaptureKit 捕获
Task {
    do {
        // 获取可共享内容（关键：onScreenWindowsOnly: false 允许后台窗口）
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false  // 允许后台窗口
        )
        
        // 查找目标窗口
        guard let targetWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            FileHandle.standardError.write("ERROR: 在 ScreenCaptureKit 中未找到窗口: \(windowID)\n".data(using: .utf8)!)
            exit(1)
        }
        
        print("窗口帧: \(targetWindow.frame)")
        
        // 创建内容过滤器
        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        
        // 捕获截图（macOS 14+ SCScreenshotManager）
        if #available(macOS 14.0, *) {
            let config = SCStreamConfiguration()
            config.captureResolution = .best
            if outputWidth > 0 && outputHeight > 0 {
                config.width = outputWidth
                config.height = outputHeight
            } else {
                // 默认：窗口原生像素分辨率（点数 × 屏幕缩放系数，Retina 为 2x）
                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                config.width = Int(targetWindow.frame.width * scale)
                config.height = Int(targetWindow.frame.height * scale)
            }
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            
            // 保存为 PNG
            let outputURL = URL(fileURLWithPath: outputPath)
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                FileHandle.standardError.write("ERROR: 无法创建图片目标\n".data(using: .utf8)!)
                exit(1)
            }
            
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                FileHandle.standardError.write("ERROR: 无法保存图片\n".data(using: .utf8)!)
                exit(1)
            }
            
            print("OK: \(outputPath)")
        } else {
            // macOS 13 回退：使用 SCStream 单帧捕获
            FileHandle.standardError.write("ERROR: 需要 macOS 14+ 支持 SCScreenshotManager\n".data(using: .utf8)!)
            exit(1)
        }
        
    } catch {
        FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    
    exit(0)
}

// 保持运行直到异步任务完成
RunLoop.main.run()
