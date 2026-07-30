//  SampleHandler.swift
//  BroadcastExtension — chunked screen recording with audio.
//  Captures the entire screen + app audio + microphone via ReplayKit,
//  writes compressed H.264/AAC in 8-second chunks to the App Group
//  shared container, and notifies the main app via Darwin notifications.

import ReplayKit
import AVFoundation

class SampleHandler: RPBroadcastSampleHandler {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var sessionId = ""
    private var chunkIndex = 0
    private var chunkStartTime: CMTime?
    private var frameCount = 0
    private var started = false
    private var stopped = false
    private var manifest: RecordingManifest?
    private var videoSize: (width: Int, height: Int)?
    private var audioFormatDesc: CMFormatDescription?

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        sessionId = UUID().uuidString
        chunkIndex = 0
        frameCount = 0
        stopped = false
        videoSize = nil
        audioFormatDesc = nil

        let dir = RecorderConstants.chunksDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        cleanChunksDirectory()

        manifest = RecordingManifest(sessionId: sessionId, startedAt: Date(), status: "recording", chunks: [])
        manifest?.save()

        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(sessionId, forKey: RecorderConstants.sessionIdKey)
        defaults?.set(false, forKey: RecorderConstants.stopRequestedKey)
        defaults?.set("recording", forKey: RecorderConstants.broadcastStatusKey)
        defaults?.synchronize()

        postNotification(RecorderConstants.broadcastStartedNotification)
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        guard !stopped else { return }
        stopped = true
        finishCurrentChunk()
        markStopped()
    }

    // MARK: - Frame processing

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard !stopped else { return }

        switch type {
        case .video:
            processVideo(sampleBuffer)
        case .audioApp:
            processAudio(sampleBuffer, input: appAudioInput)
        case .audioMic:
            processAudio(sampleBuffer, input: micAudioInput)
        @unknown default:
            break
        }
    }

    // MARK: - Video

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        frameCount += 1

        // Check stop signal every ~1 s
        if frameCount % RecorderConstants.frameRate == 0, shouldStop() {
            stopped = true
            finishCurrentChunk()
            markStopped()
            let error = NSError(domain: "com.satellica.recorder", code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "Recording session completed."])
            finishBroadcastWithError(error)
            return
        }

        // Check disk space every ~10 s
        if frameCount % (RecorderConstants.frameRate * 10) == 0, !hasSufficientDisk() {
            stopped = true
            finishCurrentChunk()
            markStopped()
            let error = NSError(domain: "com.satellica.recorder", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Insufficient disk space. Recording stopped."])
            finishBroadcastWithError(error)
            return
        }

        // Get video dimensions from first frame
        if videoSize == nil {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                videoSize = (width: Int(dims.width), height: Int(dims.height))
            }
            startNewChunk()
        }

        guard let writer = assetWriter, let input = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            chunkStartTime = pts
            started = true
        }

        // Rotate chunk when duration exceeded
        if let start = chunkStartTime,
           CMTimeGetSeconds(pts) - CMTimeGetSeconds(start) >= RecorderConstants.chunkDuration {
            rotateChunk(nextStartTime: pts)
        }

        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    // MARK: - Audio

    private func processAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let input, let writer = assetWriter,
              writer.status == .writing, started,
              input.isReadyForMoreMediaData else { return }

        // Capture audio format from the first audio buffer for chunk rotation
        if audioFormatDesc == nil {
            audioFormatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        }

        input.append(sampleBuffer)
    }

    // MARK: - Chunk management

    private func startNewChunk() {
        let fileName = String(format: "chunk_%04d.mp4", chunkIndex)
        let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)

        guard let writer = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4) else { return }

        // --- Video track ---
        let (srcW, srcH) = videoSize ?? (1170, 2532)
        let shortSide = min(srcW, srcH)
        let scale = min(1.0, 480.0 / Double(shortSide))
        let outW = Int((Double(srcW) * scale).rounded(.toNearestOrEven))
        let outH = Int((Double(srcH) * scale).rounded(.toNearestOrEven))

        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: RecorderConstants.videoBitRate,
            AVVideoExpectedSourceFrameRateKey: RecorderConstants.frameRate,
            AVVideoMaxKeyFrameIntervalKey: RecorderConstants.frameRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: videoCompression,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) { writer.add(vInput) }

        // --- App audio track (system/app sounds, web page audio) ---
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]

        let aAppInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aAppInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aAppInput) { writer.add(aAppInput) }

        // --- Mic audio track (user's voice) ---
        let aMicInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aMicInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aMicInput) { writer.add(aMicInput) }

        assetWriter = writer
        videoInput = vInput
        appAudioInput = aAppInput
        micAudioInput = aMicInput
        started = false

        manifest?.chunks.append(ChunkInfo(index: chunkIndex, fileName: fileName, status: .recording))
        manifest?.save()
    }

    private func finishCurrentChunk() {
        guard let writer = assetWriter, writer.status == .writing else {
            assetWriter = nil
            videoInput = nil
            appAudioInput = nil
            micAudioInput = nil
            return
        }
        videoInput?.markAsFinished()
        appAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        if let idx = manifest?.chunks.firstIndex(where: { $0.index == chunkIndex }) {
            manifest?.chunks[idx].status = .ready
            manifest?.save()
        }

        assetWriter = nil
        videoInput = nil
        appAudioInput = nil
        micAudioInput = nil
        postNotification(RecorderConstants.chunkReadyNotification)
    }

    private func rotateChunk(nextStartTime: CMTime) {
        finishCurrentChunk()
        chunkIndex += 1
        startNewChunk()

        if let writer = assetWriter {
            writer.startWriting()
            writer.startSession(atSourceTime: nextStartTime)
            chunkStartTime = nextStartTime
            started = true
        }
    }

    /// Mark recording as stopped in both UserDefaults (cross-process) and manifest.
    private func markStopped() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set("stopped", forKey: RecorderConstants.broadcastStatusKey)
        defaults?.synchronize()

        manifest?.status = "stopped"
        manifest?.save()

        postNotification(RecorderConstants.broadcastFinishedNotification)
    }

    // MARK: - Helpers

    private func shouldStop() -> Bool {
        UserDefaults(suiteName: RecorderConstants.appGroup)?.bool(forKey: RecorderConstants.stopRequestedKey) ?? false
    }

    private func hasSufficientDisk() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else { return true }
        return free > RecorderConstants.minFreeDisk
    }

    private func cleanChunksDirectory() {
        let dir = RecorderConstants.chunksDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    private func postNotification(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true)
    }
}
