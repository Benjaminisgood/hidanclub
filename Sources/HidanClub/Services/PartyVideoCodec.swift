import CoreMedia
import CoreVideo
import Foundation
import HidanCore
import VideoToolbox

/// Real-time H.264 for the peer link, on the system encoder (hardware where the
/// Mac has one). Camera frames are scaled down to `maxWidth` with their aspect
/// ratio intact, then encoded without frame reordering so the receiver can show
/// each picture as soon as it arrives. Keyframes carry SPS/PPS.
final class PartyVideoEncoder: @unchecked Sendable {
    struct Configuration: Equatable {
        var maxWidth: Int
        var bitrate: Int
        var framesPerSecond = 30
        var keyframeInterval = 60
    }
    typealias Output = (PartyVideoPacket) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var sourceSize = CGSize.zero
    private var targetSize = CGSize.zero
    private var configuration: Configuration
    private var pendingConfiguration: Configuration?
    private var forceKeyframe = true
    private var invalidated = false
    private var failure: String?
    private let output: Output

    init(configuration: Configuration, output: @escaping Output) {
        self.configuration = configuration
        self.output = output
    }

    /// Applied before the next frame; the session restarts with a keyframe.
    func update(configuration: Configuration) {
        lock.lock(); defer { lock.unlock() }
        if configuration != self.configuration { pendingConfiguration = configuration }
    }

    func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }

    var lastFailure: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var outputSize: CGSize { lock.lock(); defer { lock.unlock() }; return targetSize }

    /// Scaled copy plus asynchronous encode. Returns false when nothing was submitted.
    @discardableResult
    func encode(_ source: CVPixelBuffer, timestamp: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return false }
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        guard size.width > 0, size.height > 0 else { return false }
        if let pending = pendingConfiguration {
            configuration = pending; pendingConfiguration = nil; tearDown()
        }
        if session == nil || size != sourceSize {
            tearDown(); sourceSize = size
            guard setUp() else { return false }
        }
        guard let session, let pool, let transfer else { return false }
        var scaled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled) == kCVReturnSuccess, let scaled else {
            failure = "无法分配缩放缓冲区"; return false
        }
        let transferred = VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled)
        guard transferred == noErr else { failure = "画面缩放失败 (\(transferred))"; return false }
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        let presentation = CMTime(seconds: timestamp, preferredTimescale: 90_000)
        var info = VTEncodeInfoFlags()
        let output = self.output
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: scaled, presentationTimeStamp: presentation,
                                                     duration: .invalid, frameProperties: properties, infoFlagsOut: &info) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let packet = PartyVideoEncoder.packet(from: sampleBuffer) else { return }
            output(packet)
        }
        if status != noErr {
            failure = "编码失败 (\(status))"
            if status == kVTInvalidSessionErr { tearDown() }
            return false
        }
        failure = nil
        return true
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidated = true
        tearDown()
    }

    /// Output dimensions: at most `maxWidth` wide, even on both sides, same aspect ratio as the camera.
    static func targetSize(for source: CGSize, maxWidth: Int) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(1, CGFloat(max(16, maxWidth)) / source.width)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(source.width * scale), height: even(source.height * scale))
    }

    private func setUp() -> Bool {
        targetSize = Self.targetSize(for: sourceSize, maxWidth: configuration.maxWidth)
        let width = Int(targetSize.width), height = Int(targetSize.height)
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                      bufferAttributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            failure = "无法创建缩放缓冲池"; return false
        }
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr, let transfer else {
            failure = "无法创建画面缩放会话"; return false
        }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        var session: VTCompressionSession?
        let specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let created = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                 encoderSpecification: specification as CFDictionary,
                                                 imageBufferAttributes: bufferAttributes as CFDictionary,
                                                 compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                 compressionSessionOut: &session)
        guard created == noErr, let session else { failure = "无法创建 H.264 编码器 (\(created))"; return false }
        let bytesPerSecond = configuration.bitrate / 8
        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate),
            (kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond * 3 / 2, 1] as CFArray),
            (kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.keyframeInterval),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        ]
        // Optional tuning keys differ between encoders; a refused key is not fatal.
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.pool = pool; self.transfer = transfer; self.session = session
        forceKeyframe = true
        return true
    }

    private func tearDown() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        session = nil; transfer = nil; pool = nil
    }

    /// AVCC access unit plus, on keyframes, the H.264 parameter sets.
    static func packet(from sampleBuffer: CMSampleBuffer) -> PartyVideoPacket? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        var parameterSets: [Data] = []
        if isKeyframe {
            var count = 0
            var headerLength: Int32 = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                     parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                     nalUnitHeaderLengthOut: &headerLength) == noErr,
                  headerLength == 4 else { return nil }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                parameterSets.append(Data(bytes: pointer, count: size))
            }
        }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        return PartyVideoPacket(timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                width: Int(dimensions.width), height: Int(dimensions.height),
                                isKeyframe: isKeyframe, parameterSets: parameterSets, data: data)
    }
}

/// Decodes the peer's packets in arrival order on one serial queue. Nothing is
/// produced until the first keyframe; a changed SPS/PPS rebuilds the session.
final class PartyVideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private(set) var lastFailure: String?
    private(set) var decodedFrames = 0

    var isReady: Bool { session != nil }

    func decode(_ packet: PartyVideoPacket) -> CGImage? {
        if packet.isKeyframe, !packet.parameterSets.isEmpty, packet.parameterSets != parameterSets || session == nil {
            rebuild(parameterSets: packet.parameterSets)
        }
        guard let session, let format else { return nil }
        var blockBuffer: CMBlockBuffer?
        let count = packet.data.count
        guard count > 0,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: count, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { lastFailure = "无法分配解码缓冲区"; return nil }
        let replaced = packet.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: count)
        }
        guard replaced == kCMBlockBufferNoErr else { lastFailure = "无法复制解码数据"; return nil }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: packet.timestamp, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { lastFailure = "无法组装解码样本"; return nil }
        var decoded: CVImageBuffer?
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &info) { status, _, imageBuffer, _, _ in
            if status == noErr { decoded = imageBuffer }
        }
        if status == kVTInvalidSessionErr { tearDown() }
        guard status == noErr, let decoded else { lastFailure = "解码失败 (\(status))"; return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(decoded, options: nil, imageOut: &image) == noErr, let image else {
            lastFailure = "无法生成解码图像"; return nil
        }
        lastFailure = nil
        decodedFrames += 1
        return image
    }

    func reset() { tearDown(); parameterSets = []; decodedFrames = 0; lastFailure = nil }

    private func rebuild(parameterSets sets: [Data]) {
        tearDown()
        let copies: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, set.count))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                    parameterSetPointers: pointerBuffer.baseAddress!,
                                                                    parameterSetSizes: sizeBuffer.baseAddress!,
                                                                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { lastFailure = "无法读取对方的视频参数 (\(status))"; return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                                   imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &session)
        guard created == noErr, let session else { lastFailure = "无法创建 H.264 解码器 (\(created))"; return }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session; self.format = format; parameterSets = sets
    }

    private func tearDown() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
    }
}
