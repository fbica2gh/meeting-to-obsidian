#!/usr/bin/env swift
// system_audio_capture.swift — Capture system audio via ScreenCaptureKit
//
// Bypasses microphone-permission and BlackHole loopback issues by using the
// same Screen Recording permission already granted for window capture.
//
// Usage:
//   system_audio_capture <output.wav>
//
// Output: 16kHz mono 16-bit PCM WAV
// Stop: SIGINT/SIGTERM (Ctrl+C or kill)

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let audioFile: AVAudioFile
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init(path: String) throws {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000,
                                     channels: 1,
                                     interleaved: true)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioFile = try AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                    settings: settings,
                                    commonFormat: .pcmFormatInt16,
                                    interleaved: true)
    }

    private var callbackCount = 0

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        callbackCount += 1
        if callbackCount <= 3 {
            let valid = sampleBuffer.isValid
            let samples = CMSampleBufferGetNumSamples(sampleBuffer)
            FileHandle.standardError.write("[dbg] audio cb #\(callbackCount) valid=\(valid) samples=\(samples)\n".data(using: .utf8)!)
        }
        guard sampleBuffer.isValid else { return }
        guard let input = Self.toPCM(sampleBuffer) else {
            if callbackCount <= 3 { FileHandle.standardError.write("[dbg] toPCM failed\n".data(using: .utf8)!) }
            return
        }
        writeToFile(input)
        if callbackCount == 5 {
            FileHandle.standardError.write("[dbg] wrote 5 buffers\n".data(using: .utf8)!)
        }
    }

    static func toPCM(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        guard let fmt = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0 else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buf
    }

    private func writeToFile(_ input: AVAudioPCMBuffer) {
        if converter == nil || converter!.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let conv = converter else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var consumed = false
        conv.convert(to: out, error: &err) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if err == nil, out.frameLength > 0 {
            try? audioFile.write(from: out)
        }
    }
}

final class VideoStreamOutput: NSObject, SCStreamOutput {
    var count = 0
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        count += 1
        if count <= 3 {
            FileHandle.standardError.write("[dbg] video cb #\(count)\n".data(using: .utf8)!)
        }
    }
}

// ── Main ─────────────────────────────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Usage: system_audio_capture <output.wav>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = args[1]

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

var stream: SCStream?
var audioOutputKeep: AudioStreamOutput?
var videoOutputKeep: VideoStreamOutput?
let sem = DispatchSemaphore(value: 0)

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            FileHandle.standardError.write("ERROR: no display found\n".data(using: .utf8)!)
            exit(1)
        }
        FileHandle.standardError.write("[dbg] displays=\(content.displays.count) windows=\(content.windows.count)\n".data(using: .utf8)!)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = false
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps

        let output = try AudioStreamOutput(path: outputPath)
        let videoOutput = VideoStreamOutput()
        // Keep strong references so the outputs are not deallocated
        audioOutputKeep = output
        videoOutputKeep = videoOutput
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.capture"))
        try s.addStreamOutput(videoOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "video.capture"))
        try await s.startCapture()
        stream = s
        print("OK: recording system audio -> \(outputPath)")
        sem.signal()
    } catch {
        FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

sem.wait()
RunLoop.main.run()
