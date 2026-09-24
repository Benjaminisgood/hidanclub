import CoreVideo
import Foundation
import HidanCore

/// Hands each analyzed camera frame to one extra consumer (the peer video
/// sender) on the capture queue, before the main-thread preview handoff.
/// Handlers must return quickly and must not keep the pixel buffer beyond the
/// call; installing nil detaches without touching the capture session.
final class LivePoseFrameTap: @unchecked Sendable {
    typealias Handler = (CVPixelBuffer, LivePoseObservation) -> Void
    private let lock = NSLock()
    private var handler: Handler?

    var isInstalled: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }

    func install(_ handler: Handler?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func deliver(_ buffer: CVPixelBuffer, _ observation: LivePoseObservation) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(buffer, observation)
    }
}
