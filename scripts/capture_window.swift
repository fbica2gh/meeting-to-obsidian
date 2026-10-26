import ScreenCaptureKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var outputURL: URL
    private var frameCount = 0
    
    init(outputPath: String) {
        self.outputURL = URL(fileURLWithPath: outputPath)
        super.init()
    }
    
    func start() async throws {
        let content = try await SCShareableContent.current
        
        guard let window = content.windows.first(where: {
            ($0.owningApplication?.applicationName ?? "").contains("Tencent") ||
            ($0.title ?? "").contains("腾讯")
        }) else {
            print("Window not found")
            return
        }
        
        print("Found window: \(window.title ?? "Unknown")")
        
        let filter = SCContentFilter(desktopIndependentWindow: window)
        
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 5
        
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        
        try await stream?.startCapture()
        print("Capture started")
    }
    
    func stop() {
        Task {
            try? await stream?.stopCapture()
        }
        print("Capture stopped. Frames: \(frameCount)")
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        frameCount += 1
        
        if frameCount % 30 == 0 {
            saveFrame(pixelBuffer: pixelBuffer)
        }
    }
    
    private func saveFrame(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        let url = outputURL.appendingPathComponent("frame_\(String(format: "%04d", frameCount / 30)).jpg")
        
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        
        print("Saved: \(url.path)")
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: capture_window <output_dir>")
    exit(1)
}

let outputDir = args[1]
let capture = WindowCapture(outputPath: outputDir)

Task {
    do {
        try await capture.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3600))
    } catch {
        print("Error: \(error)")
    }
}

signal(SIGINT) { _ in
    capture.stop()
    exit(0)
}

RunLoop.main.run()
