//  SampleHandler.swift
//  BroadcastExtension — chunked screen recording.
//  Non-blocking chunk rotation. Timer + frozen frame fill ensures continuous
//  video even when the screen is completely static.
//  All shared state is serialized on a single private queue.

import ReplayKit
import AVFoundation
import CoreVideo
import CryptoKit
import CoreImage
import ImageIO

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    private struct ValidatedChunk {
        let fileSize: Int64
        let duration: TimeInterval
        let sha256: String
    }

    /// Serial queue that serializes ALL access to shared recording state.
    /// processVideo dispatches here, timer runs here, finishWriting completes here.
    private let queue = DispatchQueue(label: "com.satellica.recorder.processing")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionId = ""
    private var activeChunkDuration = RecorderConstants.chunkDuration
    private var chunkIndex = 0
    private var chunkStartTime: CMTime?
    private var frameCount = 0
    private var started = false
    private var stopped = false
    private var manifest: RecordingManifest?
    private var videoSize: (width: Int, height: Int)?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let outputColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Last frame data for frozen-frame fill
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastOrientation: CGImagePropertyOrientation = .up
    private var lastWrittenPTS: CMTime?
    private var timelineAnchorPTS: CMTime?
    private var timelineAnchorHostTime: CMTime?
    private var lastRealFrameHostTime: CMTime?

    private var chunkTimer: DispatchSourceTimer?
    private var timerTickCount = 0
    private var pendingWriters: [(writer: AVAssetWriter, chunkIndex: Int)] = []

    /// DispatchGroup to wait for pending async finishWriting calls
    private let pendingGroup = DispatchGroup()

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        var rejectionError: NSError?
        queue.sync {
            guard RecorderConstants.isAppGroupContainerAvailable else {
                rejectionError = NSError(
                    domain: "com.satellica.recorder",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Shared recording storage is unavailable."]
                )
                return
            }
            if let unfinished = RecordingManifest.load(), unfinished.status != "completed" {
                RecorderLog.write("extension", "broadcast_start_rejected_unfinished_recording", [
                    "recordingId": unfinished.sessionId,
                    "status": unfinished.status,
                    "chunkCount": unfinished.chunks.count
                ])
                rejectionError = NSError(
                    domain: "com.satellica.recorder",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "A previous recording is still being verified or uploaded."]
                )
                return
            }

            guard var uploadContext = NativeUploadContextStore.load(),
                  uploadContext.chunkSeconds.isFinite,
                  uploadContext.chunkSeconds > 0,
                  uploadContext.maxChunkBytes > 0 else {
                rejectionError = NSError(
                    domain: "com.satellica.recorder",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Recording upload configuration is missing."]
                )
                return
            }
            let startedAt = Date()
            uploadContext.startedAtDeviceEpochMs = Int64((startedAt.timeIntervalSince1970 * 1_000).rounded())
            guard NativeUploadContextStore.save(uploadContext),
                  NativeUploadContextStore.load()?.startedAtDeviceEpochMs == uploadContext.startedAtDeviceEpochMs else {
                rejectionError = NSError(
                    domain: "com.satellica.recorder",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Recording start information could not be saved."]
                )
                return
            }
            sessionId = uploadContext.recordingId
            activeChunkDuration = uploadContext.chunkSeconds
            chunkIndex = 0
            frameCount = 0
            stopped = false
            videoSize = nil
            pixelBufferAdaptor = nil
            lastPixelBuffer = nil
            lastOrientation = .up
            lastWrittenPTS = nil
            timelineAnchorPTS = nil
            timelineAnchorHostTime = nil
            lastRealFrameHostTime = nil
            pendingWriters = []
            timerTickCount = 0
            stopChunkTimer()

            var dir = RecorderConstants.chunksDirectory
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? dir.setResourceValues(resourceValues)
            cleanChunksDirectory()
            ChunkMetadataStore.clear()

            let initialManifest = RecordingManifest(
                sessionId: sessionId,
                startedAt: startedAt,
                status: "recording",
                chunks: []
            )
            guard initialManifest.save(),
                  RecordingManifest.load()?.sessionId == sessionId else {
                rejectionError = NSError(
                    domain: "com.satellica.recorder",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Recording state could not be saved."]
                )
                return
            }
            manifest = initialManifest
            RecorderLog.write("extension", "broadcast_started", [
                "recordingId": sessionId,
                "startedAtDeviceEpochMs": uploadContext.startedAtDeviceEpochMs ?? 0,
                "chunkSeconds": activeChunkDuration,
                "hasUploadContext": true
            ])

            let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
            defaults?.set(sessionId, forKey: RecorderConstants.sessionIdKey)
            defaults?.set(false, forKey: RecorderConstants.stopRequestedKey)
            defaults?.set("recording", forKey: RecorderConstants.broadcastStatusKey)
            defaults?.set(
                Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
                forKey: RecorderConstants.broadcastHeartbeatMsKey
            )
            defaults?.synchronize()
        }

        if let rejectionError {
            postNotification(RecorderConstants.broadcastFailedNotification)
            finishBroadcastWithError(rejectionError)
            return
        }

        postNotification(RecorderConstants.broadcastStartedNotification)
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        let shouldFinalize = queue.sync { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            markInterrupted(reason: "systemBroadcastFinished")
            stopChunkTimer()
            finishCurrentChunkSync()
            return true
        }
        guard shouldFinalize else { return }
        _ = pendingGroup.wait(timeout: .now() + 5)
        queue.sync { markStopped() }
    }

    // MARK: - Frame processing

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        // ReplayKit only guarantees this buffer until the callback returns.
        // Synchronous processing also provides bounded backpressure: frames can
        // never accumulate without limit inside the extension process.
        queue.sync { [weak self] in
            self?.processVideo(sampleBuffer)
        }
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        // Already on `queue`
        guard !stopped else { return }

        frameCount += 1

        if frameCount % RecorderConstants.frameRate == 0, shouldStop() {
            stopped = true
            stopChunkTimer()
            finishCurrentChunkSync()
            _ = pendingGroup.wait(timeout: .now() + 5)
            markStopped()
            let error = NSError(domain: "com.satellica.recorder", code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "Recording session completed."])
            finishBroadcastWithError(error)
            return
        }

        if frameCount % (RecorderConstants.frameRate * 10) == 0, !hasSufficientDisk() {
            stopped = true
            markInterrupted(reason: "insufficientDisk")
            stopChunkTimer()
            finishCurrentChunkSync()
            _ = pendingGroup.wait(timeout: .now() + 5)
            markStopped()
            let error = NSError(domain: "com.satellica.recorder", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Insufficient disk space."])
            finishBroadcastWithError(error)
            return
        }

        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = videoOrientation(from: sampleBuffer)
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = currentHostTime()

        if timelineAnchorPTS == nil {
            timelineAnchorPTS = sourcePTS
            timelineAnchorHostTime = hostTime
        }

        // First frame: establish one output canvas for the entire recording.
        // Later orientation and resolution changes are rendered into this canvas.
        if videoSize == nil {
            let extent = CIImage(cvPixelBuffer: sourcePixelBuffer).oriented(orientation).extent
            videoSize = (width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
            RecorderLog.write("extension", "first_video_frame", [
                "recordingId": sessionId,
                "width": Int(extent.width.rounded()),
                "height": Int(extent.height.rounded()),
                "orientation": orientation.rawValue
            ])
            guard startNewChunk(at: sourcePTS) else {
                abortRecordingAfterWriterFailure(reason: "initialWriterStartFailed")
                return
            }
            startChunkTimer()
        }

        guard let writer = assetWriter else { return }

        guard writer.status == .writing else { return }

        // A real frame arrived, even if the writer is temporarily busy.
        lastRealFrameHostTime = hostTime

        // Refresh periodically, and immediately when ReplayKit changes the
        // source format/orientation so a frozen frame never uses stale geometry.
        let sourceFormatChanged = lastPixelBuffer.map {
            CVPixelBufferGetWidth($0) != CVPixelBufferGetWidth(sourcePixelBuffer) ||
            CVPixelBufferGetHeight($0) != CVPixelBufferGetHeight(sourcePixelBuffer) ||
            CVPixelBufferGetPixelFormatType($0) != CVPixelBufferGetPixelFormatType(sourcePixelBuffer)
        } ?? true
        if frameCount == 1 || frameCount % 15 == 0 ||
            orientation != lastOrientation || sourceFormatChanged {
            saveLastPixelBuffer(from: sampleBuffer, orientation: orientation)
        }

        let normalizedPTS = normalizedPresentationTime(
            for: sampleBuffer,
            hostTime: hostTime
        )
        appendVideoFrame(sourcePixelBuffer, orientation: orientation, at: normalizedPTS)
    }

    // MARK: - Frozen frame support

    private func saveLastPixelBuffer(
        from sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        guard let srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(srcBuffer)
        let height = CVPixelBufferGetHeight(srcBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(srcBuffer)

        let dst: CVPixelBuffer
        if let existing = lastPixelBuffer,
           CVPixelBufferGetWidth(existing) == width,
           CVPixelBufferGetHeight(existing) == height,
           CVPixelBufferGetPixelFormatType(existing) == pixelFormat {
            dst = existing
        } else {
            var newBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &newBuffer)
            guard let created = newBuffer else { return }
            dst = created
            lastPixelBuffer = dst
        }

        CVPixelBufferLockBaseAddress(srcBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        let planes = CVPixelBufferGetPlaneCount(srcBuffer)
        if planes > 0 {
            for plane in 0..<planes {
                if let s = CVPixelBufferGetBaseAddressOfPlane(srcBuffer, plane),
                   let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) {
                    let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(srcBuffer, plane)
                    let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                    let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)
                    let rows = min(
                        CVPixelBufferGetHeightOfPlane(srcBuffer, plane),
                        CVPixelBufferGetHeightOfPlane(dst, plane)
                    )
                    for row in 0..<rows {
                        memcpy(
                            d.advanced(by: row * destinationBytesPerRow),
                            s.advanced(by: row * sourceBytesPerRow),
                            rowBytes
                        )
                    }
                }
            }
        } else {
            if let s = CVPixelBufferGetBaseAddress(srcBuffer),
               let d = CVPixelBufferGetBaseAddress(dst) {
                let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(srcBuffer)
                let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(dst)
                let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)
                for row in 0..<height {
                    memcpy(
                        d.advanced(by: row * destinationBytesPerRow),
                        s.advanced(by: row * sourceBytesPerRow),
                        rowBytes
                    )
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(srcBuffer, .readOnly)
        lastOrientation = orientation
    }

    private func writeFrozenFrame() {
        // Already on `queue`
        guard let writer = assetWriter, writer.status == .writing, started,
              let pixelBuffer = lastPixelBuffer,
              let targetPTS = timelinePresentationTime(at: currentHostTime()) else { return }

        appendVideoFrame(pixelBuffer, orientation: lastOrientation, at: targetPTS)
    }

    /// Keep ReplayKit's capture timestamp when it is current, but never let a
    /// resumed real frame fall behind the monotonic recording timeline.
    private func normalizedPresentationTime(
        for sampleBuffer: CMSampleBuffer,
        hostTime: CMTime
    ) -> CMTime {
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let wallClockPTS = timelinePresentationTime(at: hostTime) ?? sourcePTS
        var candidate = CMTimeCompare(sourcePTS, wallClockPTS) >= 0 ? sourcePTS : wallClockPTS

        guard let previousPTS = lastWrittenPTS,
              CMTimeCompare(candidate, previousPTS) <= 0 else { return candidate }

        let sourceDuration = CMSampleBufferGetDuration(sampleBuffer)
        let frameDuration: CMTime
        if sourceDuration.isNumeric, CMTimeCompare(sourceDuration, .zero) > 0 {
            frameDuration = sourceDuration
        } else {
            frameDuration = CMTime(value: 1, timescale: CMTimeScale(RecorderConstants.frameRate))
        }
        candidate = CMTimeAdd(previousPTS, frameDuration)
        return candidate
    }

    private func currentHostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func timelinePresentationTime(at hostTime: CMTime) -> CMTime? {
        guard let anchorPTS = timelineAnchorPTS,
              let anchorHostTime = timelineAnchorHostTime else { return nil }
        let elapsed = CMTimeSubtract(hostTime, anchorHostTime)
        guard elapsed.isNumeric, CMTimeCompare(elapsed, .zero) >= 0 else { return anchorPTS }
        return CMTimeAdd(anchorPTS, elapsed)
    }

    /// Single write path for real and synthetic frames. Every source frame is
    /// oriented and aspect-fitted into the recording's fixed output canvas.
    private func appendVideoFrame(
        _ sourcePixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        at pts: CMTime
    ) {
        let frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(RecorderConstants.frameRate)
        )

        // A delayed timer may cross several boundaries at once. Close every
        // elapsed 8-second chunk and seed the next chunk at its exact start so
        // no chunk is skipped or begins with a timeline gap.
        while let start = chunkStartTime {
            let boundary = CMTimeAdd(
                start,
                CMTimeMakeWithSeconds(activeChunkDuration, preferredTimescale: 600)
            )
            guard CMTimeCompare(pts, boundary) > 0 else { break }

            let tailPTS = CMTimeSubtract(boundary, frameDuration)
            if lastWrittenPTS.map({ CMTimeCompare($0, tailPTS) < 0 }) ?? true {
                _ = appendRenderedFrame(
                    sourcePixelBuffer,
                    orientation: orientation,
                    at: tailPTS
                )
            }

            rotateChunk(nextStartTime: boundary)
            guard assetWriter?.status == .writing else { return }
            guard appendRenderedFrame(
                sourcePixelBuffer,
                orientation: orientation,
                at: boundary
            ) else { return }
        }

        if let previousPTS = lastWrittenPTS,
           CMTimeCompare(pts, previousPTS) <= 0 { return }
        _ = appendRenderedFrame(sourcePixelBuffer, orientation: orientation, at: pts)
    }

    @discardableResult
    private func appendRenderedFrame(
        _ sourcePixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        at pts: CMTime
    ) -> Bool {
        guard let writer = assetWriter, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool else { return false }

        var outputPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &outputPixelBuffer
        ) == kCVReturnSuccess, let outputPixelBuffer else { return false }

        render(
            sourcePixelBuffer,
            orientation: orientation,
            into: outputPixelBuffer
        )

        if adaptor.append(outputPixelBuffer, withPresentationTime: pts) {
            lastWrittenPTS = pts
            return true
        } else {
            print("[SampleHandler] frame append failed: \(writer.error?.localizedDescription ?? "unknown")")
            return false
        }
    }

    private func render(
        _ sourcePixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        into outputPixelBuffer: CVPixelBuffer
    ) {
        let outputRect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(outputPixelBuffer),
            height: CVPixelBufferGetHeight(outputPixelBuffer)
        )
        let oriented = CIImage(cvPixelBuffer: sourcePixelBuffer).oriented(orientation)
        let normalized = oriented.transformed(
            by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
        )
        guard normalized.extent.width > 0, normalized.extent.height > 0 else { return }
        let scale = min(
            outputRect.width / normalized.extent.width,
            outputRect.height / normalized.extent.height
        )
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(
            by: CGAffineTransform(
                translationX: (outputRect.width - scaled.extent.width) / 2,
                y: (outputRect.height - scaled.extent.height) / 2
            )
        )
        let background = CIImage(color: .black).cropped(to: outputRect)
        ciContext.render(
            centered.composited(over: background),
            to: outputPixelBuffer,
            bounds: outputRect,
            colorSpace: outputColorSpace
        )
    }

    private func videoOrientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber else { return .up }
        return CGImagePropertyOrientation(rawValue: value.uint32Value) ?? .up
    }

    // MARK: - Chunk timer

    private func startChunkTimer() {
        stopChunkTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)  // runs on the same serial queue
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.timerTick()
        }
        timer.resume()
        chunkTimer = timer
    }

    private func stopChunkTimer() {
        chunkTimer?.cancel()
        chunkTimer = nil
    }

    private func timerTick() {
        // Already on `queue`
        guard !stopped, started else { return }
        timerTickCount += 1
        if timerTickCount % 5 == 0 {
            updateBroadcastHeartbeat()
        }

        // Check stop signal
        if shouldStop() {
            stopped = true
            stopChunkTimer()
            finishCurrentChunkSync()
            _ = pendingGroup.wait(timeout: .now() + 5)
            markStopped()
            let error = NSError(domain: "com.satellica.recorder", code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "Recording session completed."])
            finishBroadcastWithError(error)
            return
        }

        // Disk checks cannot depend on ReplayKit delivering real frames: when
        // the screen is static, only this timer continues to advance.
        if timerTickCount % 10 == 0, !hasSufficientDisk() {
            stopped = true
            markInterrupted(reason: "insufficientDisk")
            stopChunkTimer()
            finishCurrentChunkSync()
            _ = pendingGroup.wait(timeout: .now() + 5)
            markStopped()
            let error = NSError(
                domain: "com.satellica.recorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Insufficient disk space."]
            )
            finishBroadcastWithError(error)
            return
        }

        // Only write frozen frames if no real frame arrived recently (> 0.8s)
        let now = currentHostTime()
        let elapsedSec = lastRealFrameHostTime.map {
            CMTimeGetSeconds(CMTimeSubtract(now, $0))
        } ?? .infinity

        if elapsedSec > 0.8, lastPixelBuffer != nil {
            writeFrozenFrame()
        }
    }

    // MARK: - Chunk management

    @discardableResult
    private func startNewChunk(at startTime: CMTime) -> Bool {
        let fileName = String(format: "chunk_%04d.mp4", chunkIndex)
        let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(fileName)
        // Keep the media type as the final path extension. AVURLAsset uses the
        // extension as a format hint and cannot reliably open `*.mp4.part`.
        let partialURL = RecorderConstants.chunksDirectory
            .appendingPathComponent(String(format: "chunk_%04d.part.mp4", chunkIndex))
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: partialURL)

        // A chunk is never visible to the uploader until finishWriting succeeds
        // and the temporary file is atomically moved to its final .mp4 name.
        guard let writer = try? AVAssetWriter(outputURL: partialURL, fileType: .mp4) else {
            RecorderLog.write("extension", "chunk_writer_create_failed", [
                "recordingId": sessionId,
                "index": chunkIndex
            ])
            return false
        }

        let (srcW, srcH) = videoSize ?? (1170, 2532)
        let shortSide = min(srcW, srcH)
        let scale = min(1.0, 480.0 / Double(shortSide))
        // H.264 dimensions must be even. Keep one fixed canvas for all chunks.
        let outW = max(2, Int((Double(srcW) * scale).rounded()) / 2 * 2)
        let outH = max(2, Int((Double(srcH) * scale).rounded()) / 2 * 2)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: RecorderConstants.videoBitRate,
            AVVideoExpectedSourceFrameRateKey: RecorderConstants.frameRate,
            AVVideoMaxKeyFrameIntervalKey: RecorderConstants.frameRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else {
            print("[SampleHandler] cannot add video input")
            RecorderLog.write("extension", "chunk_writer_input_failed", [
                "recordingId": sessionId,
                "index": chunkIndex
            ])
            return false
        }
        writer.add(vInput)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        assetWriter = writer
        videoInput = vInput
        pixelBufferAdaptor = adaptor
        chunkStartTime = startTime
        guard writer.startWriting() else {
            RecorderLog.write("extension", "chunk_writer_start_failed", [
                "recordingId": sessionId,
                "index": chunkIndex,
                "error": writer.error?.localizedDescription ?? "unknown"
            ])
            assetWriter = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            return false
        }
        writer.startSession(atSourceTime: startTime)
        started = true

        let startOffsetMs: Int64
        if let anchorPTS = timelineAnchorPTS {
            let seconds = max(0, CMTimeGetSeconds(CMTimeSubtract(startTime, anchorPTS)))
            startOffsetMs = Int64((seconds * 1_000).rounded())
        } else {
            startOffsetMs = 0
        }
        let openedChunk = ChunkInfo(
            index: chunkIndex,
            fileName: fileName,
            status: .recording,
            startOffsetMs: startOffsetMs
        )
        manifest?.chunks.append(openedChunk)
        let journalSaved = ChunkMetadataStore.save(sessionId: sessionId, chunk: openedChunk)
        let manifestSaved = RecordingManifestStore.upsertChunk(sessionId: sessionId, chunk: openedChunk)
        if !journalSaved || !manifestSaved {
            RecorderLog.write("extension", "chunk_open_persist_incomplete", [
                "recordingId": sessionId,
                "index": chunkIndex,
                "journalSaved": journalSaved,
                "manifestSaved": manifestSaved
            ])
        }
        RecorderLog.write("extension", "chunk_opened", [
            "recordingId": sessionId,
            "index": chunkIndex,
            "startOffsetMs": startOffsetMs,
            "fileName": fileName
        ])
        return true
    }

    private func rotateChunk(nextStartTime: CMTime) {
        // Already on `queue`
        if let writer = assetWriter, writer.status == .writing {
            writer.endSession(atSourceTime: nextStartTime)
            videoInput?.markAsFinished()

            let idx = chunkIndex
            pendingWriters.append((writer: writer, chunkIndex: idx))
            pendingGroup.enter()
            let group = pendingGroup
            let chunkSnapshot = manifest?.chunks.first(where: { $0.index == idx })

            writer.finishWriting { [self] in
                Task {
                    // Finalization does not touch encoder state, so it can
                    // complete while the serial queue waits during a stop.
                    await publishFinishedChunk(
                        writer: writer,
                        index: idx,
                        chunkSnapshot: chunkSnapshot
                    )
                    group.leave()
                    self.queue.async {
                        self.pendingWriters.removeAll { $0.chunkIndex == idx }
                    }
                }
            }
        }

        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        chunkIndex += 1
        if !startNewChunk(at: nextStartTime) {
            abortRecordingAfterWriterFailure(reason: "rotatedWriterStartFailed")
        }
    }

    private func abortRecordingAfterWriterFailure(reason: String) {
        guard !stopped else { return }
        stopped = true
        stopChunkTimer()
        assetWriter?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        markInterrupted(reason: reason)
        markStopped()
        RecorderLog.write("extension", "broadcast_aborted_writer_failure", [
            "recordingId": sessionId,
            "reason": reason,
            "completedChunkCount": manifest?.chunks.count ?? 0
        ])
        let error = NSError(
            domain: "com.satellica.recorder",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "The video encoder stopped unexpectedly."]
        )
        finishBroadcastWithError(error)
    }

    private func finishCurrentChunkSync() {
        // Already on `queue`
        let finalPTS = timelinePresentationTime(at: currentHostTime())
        if started, let pixelBuffer = lastPixelBuffer, let finalPTS {
            appendVideoFrame(pixelBuffer, orientation: lastOrientation, at: finalPTS)
        }

        guard let writer = assetWriter, writer.status == .writing else {
            assetWriter = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            return
        }

        if let finalPTS, let start = chunkStartTime,
           CMTimeCompare(finalPTS, start) > 0 {
            writer.endSession(atSourceTime: finalPTS)
        }
        videoInput?.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        let publishSemaphore = DispatchSemaphore(value: 0)
        let currentIndex = chunkIndex
        let chunkSnapshot = manifest?.chunks.first(where: { $0.index == currentIndex })
        Task { [self] in
            await publishFinishedChunk(
                writer: writer,
                index: currentIndex,
                chunkSnapshot: chunkSnapshot
            )
            publishSemaphore.signal()
        }
        _ = publishSemaphore.wait(timeout: .now() + 5)

        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
    }

    private func publishFinishedChunk(
        writer: AVAssetWriter,
        index: Int,
        chunkSnapshot: ChunkInfo?
    ) async {
        let partialURL = writer.outputURL
        let finalURL = RecorderConstants.chunksDirectory
            .appendingPathComponent(String(format: "chunk_%04d.mp4", index))

        if let validation = await validateCompletedChunk(writer: writer, at: partialURL) {
            do {
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            } catch {
                print("[SampleHandler] failed to publish chunk \(index): \(error.localizedDescription)")
                _ = await persistChunkStatus(
                    fallback: chunkSnapshot,
                    index: index,
                    status: .dataLost
                )
                RecorderLog.write("extension", "chunk_publish_move_failed", [
                    "recordingId": sessionId,
                    "index": index,
                    "error": error.localizedDescription
                ])
                return
            }

            let metadataPersisted = await persistChunkStatus(
                fallback: chunkSnapshot,
                index: index,
                status: .ready,
                validation: validation
            )
            RecorderLog.write("extension", "chunk_published", [
                "recordingId": sessionId,
                "index": index,
                "bytes": validation.fileSize,
                "durationMs": Int64((validation.duration * 1_000).rounded()),
                "metadataPersisted": metadataPersisted
            ])
            postNotification(RecorderConstants.chunkReadyNotification)
        } else {
            print("[SampleHandler] invalid chunk \(index): status=\(writer.status.rawValue), error=\(writer.error?.localizedDescription ?? "none")")
            try? FileManager.default.removeItem(at: partialURL)
            _ = await persistChunkStatus(
                fallback: chunkSnapshot,
                index: index,
                status: .dataLost
            )
            RecorderLog.write("extension", "chunk_validation_failed", [
                "recordingId": sessionId,
                "index": index,
                "writerStatus": writer.status.rawValue,
                "error": writer.error?.localizedDescription ?? "none"
            ])
        }
    }

    private func validateCompletedChunk(
        writer: AVAssetWriter,
        at url: URL
    ) async -> ValidatedChunk? {
        guard writer.status == .completed else { return nil }

        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { return nil }

        let asset = AVURLAsset(url: url)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard !videoTracks.isEmpty, seconds.isFinite, seconds > 0 else { return nil }
            guard let checksum = sha256(of: url) else { return nil }

            return ValidatedChunk(fileSize: fileSize, duration: seconds, sha256: checksum)
        } catch {
            print("[SampleHandler] media validation failed: \(error.localizedDescription)")
            let nsError = error as NSError
            RecorderLog.write("extension", "media_validation_error", [
                "recordingId": sessionId,
                "error": error.localizedDescription,
                "errorDomain": nsError.domain,
                "errorCode": nsError.code,
                "fileExtension": url.pathExtension,
                "fileSize": fileSize
            ])
            return nil
        }
    }

    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            print("[SampleHandler] checksum failed: \(error.localizedDescription)")
            RecorderLog.write("extension", "checksum_error", [
                "recordingId": sessionId,
                "error": error.localizedDescription
            ])
            return nil
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func persistChunkStatus(
        fallback: ChunkInfo?,
        index: Int,
        status: ChunkInfo.ChunkStatus,
        validation: ValidatedChunk? = nil
    ) async -> Bool {
        guard var chunk = ChunkMetadataStore.load(sessionId: sessionId, index: index)
            ?? RecordingManifest.load()?.chunks.first(where: { $0.index == index })
            ?? fallback else { return false }

        chunk.status = status
        if let validation {
            chunk.fileSize = validation.fileSize
            chunk.duration = validation.duration
            chunk.sha256 = validation.sha256
        }

        for attempt in 1...5 {
            let journalSaved = ChunkMetadataStore.save(sessionId: sessionId, chunk: chunk)
            let manifestSaved = RecordingManifestStore.upsertChunk(sessionId: sessionId, chunk: chunk)
            let verified = RecordingManifest.load()?.chunks.first(where: { $0.index == index })
            let metadataMatches = verified?.startOffsetMs == chunk.startOffsetMs &&
                verified?.duration == chunk.duration &&
                verified?.fileSize == chunk.fileSize &&
                verified?.sha256 == chunk.sha256
            if journalSaved && manifestSaved && metadataMatches {
                return true
            }

            RecorderLog.write("extension", "chunk_metadata_persist_retry", [
                "recordingId": sessionId,
                "index": index,
                "attempt": attempt,
                "journalSaved": journalSaved,
                "manifestSaved": manifestSaved,
                "metadataMatches": metadataMatches
            ])
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
        }
        return false
    }

    private func markStopped() {
        discardInvalidTrailingChunks()
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set("stopped", forKey: RecorderConstants.broadcastStatusKey)
        defaults?.set(
            Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            forKey: RecorderConstants.broadcastHeartbeatMsKey
        )
        defaults?.synchronize()

        // All callers already execute on the recording queue. Calling
        // queue.sync here would deadlock that queue during normal stop.
        manifest?.status = "stopped"
        let stoppedStateSaved = RecordingManifestStore.updateSessionStatus(
            sessionId: sessionId,
            status: "stopped"
        )
        RecorderLog.write("extension", "broadcast_stopped", [
            "recordingId": sessionId,
            "chunkCount": manifest?.chunks.count ?? 0,
            "interruptedReason": manifest?.interruptedReason ?? "none",
            "statePersisted": stoppedStateSaved
        ])

        postNotification(RecorderConstants.broadcastFinishedNotification)
    }

    private func markInterrupted(reason: String) {
        let interruptedAtMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        manifest?.interruptedAtMs = interruptedAtMs
        manifest?.interruptedReason = reason
        manifest?.save()
        RecorderLog.write("extension", "broadcast_interrupted", [
            "recordingId": sessionId,
            "reason": reason,
            "interruptedAtMs": interruptedAtMs
        ])
    }

    /// A writer can be terminated while its final MP4 atom is being closed.
    /// Only corrupt chunks at the tail are safely discardable; a corrupt chunk
    /// between valid indexes remains recorded as data loss for uploader review.
    private func discardInvalidTrailingChunks() {
        guard var latest = RecordingManifestStore.load(recordingId: sessionId) else { return }
        var discarded: [Int] = []
        while let tail = latest.chunks.max(by: { $0.index < $1.index }), tail.status == .dataLost {
            let partialURL = RecorderConstants.chunksDirectory(for: sessionId)
                .appendingPathComponent(String(format: "chunk_%04d.part.mp4", tail.index))
            let finalURL = RecorderConstants.chunksDirectory(for: sessionId)
                .appendingPathComponent(tail.fileName)
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: finalURL)
            ChunkMetadataStore.remove(sessionId: sessionId, index: tail.index)
            guard RecordingManifestStore.removeChunk(sessionId: sessionId, index: tail.index) else { break }
            discarded.append(tail.index)
            latest.chunks.removeAll { $0.index == tail.index }
        }
        if !discarded.isEmpty {
            manifest?.chunks.removeAll { discarded.contains($0.index) }
            manifest?.partialDataLoss = true
            _ = RecordingManifestStore.markPartialDataLoss(sessionId: sessionId)
            RecorderLog.write("extension", "trailing_invalid_chunks_discarded", [
                "recordingId": sessionId,
                "indexes": discarded.sorted().map(String.init).joined(separator: ","),
                "partialDataLoss": true
            ])
        }
    }

    // MARK: - Helpers

    private func shouldStop() -> Bool {
        UserDefaults(suiteName: RecorderConstants.appGroup)?.bool(forKey: RecorderConstants.stopRequestedKey) ?? false
    }

    private func updateBroadcastHeartbeat() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(
            Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            forKey: RecorderConstants.broadcastHeartbeatMsKey
        )
        defaults?.synchronize()
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
