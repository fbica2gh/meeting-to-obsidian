// window_stream.swift — 常驻 SCStream 订阅指定窗口的视频帧，按间隔落盘 PNG
// 用法: window_stream <window_id> <output_dir> [interval_seconds]
// 窗口被遮挡/在后台也会持续输出帧（不走屏幕截图路径）

import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import VideoToolbox
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let outDir: String
    let interval: Double
    var lastSaved: Double = -1e9
    var lastHash: [UInt8] = []
    let lock = NSLock()
    let saveQueue = DispatchQueue(label: "window_stream.save")

    init(outDir: String, interval: Double) {
        self.outDir = outDir
        self.interval = interval
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        lock.lock()
        let shouldSave = pts - lastSaved >= interval
        if shouldSave { lastSaved = pts }
        lock.unlock()
        guard shouldSave else { return }

        // 直接从原始像素缓冲转 CGImage（不做手动内存拷贝，避免 stride 错位）
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        guard let cg = cg else { return }

        // 帧级去重：与上一保存帧做字节哈希比对，相同则跳过（画面静止时不产生冗余文件）
        var hash: [UInt8] = []
        if let data = cg.dataProvider?.data {
            let digest = Insecure.MD5.hash(data: data as Data)
            hash = Array(digest)
        }
        lock.lock()
        let dup = (hash == lastHash)
        if !dup { lastHash = hash }
        lock.unlock()
        if dup { return }

        saveQueue.async { [cg] in
            let fmt = DateFormatter()
            fmt.dateFormat = "HHmmss"
            let path = "\(self.outDir)/frame_\(fmt.string(from: Date())).png"
            guard let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            FileHandle.standardError.write("frame \(path)\n".data(using: .utf8)!)
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: window_stream <window_id> <output_dir> [interval]\n".data(using: .utf8)!)
    exit(1)
}
let windowID = CGWindowID(Int32(args[1]) ?? 0)
let outDir = args[2]
let interval = args.count > 3 ? Double(args[3]) ?? 15 : 15

// 主线程预热 CoreGraphics Services，避免回调线程首触 CGS 断言
_ = CGMainDisplayID()

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sema = DispatchSemaphore(value: 0)

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
            FileHandle.standardError.write("ERROR: 未找到窗口 \(windowID)\n".data(using: .utf8)!)
            exit(1)
        }
        FileHandle.standardError.write("stream start: [\(windowID)] frame=\(win.frame)\n".data(using: .utf8)!)

        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = Int(win.frame.width * scale)
        config.height = Int(win.frame.height * scale)
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 最高 2fps，省 GPU
        config.queueDepth = 3
        config.showsCursor = false

        let sink = FrameSink(outDir: outDir, interval: interval)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()

        signal(SIGTERM) { _ in sema.signal() }
        signal(SIGINT) { _ in sema.signal() }
        sema.wait()
        try? await stream.stopCapture()
        exit(0)
    } catch {
        FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

RunLoop.main.run()
