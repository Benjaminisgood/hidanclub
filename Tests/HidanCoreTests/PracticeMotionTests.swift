import XCTest
@testable import HidanCore

final class PracticeMotionTests: XCTestCase {
    func testEveryMoveKeepsBothCoordinateLayers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("practice-motion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PracticeMotionLibrary.install(into: root)
        try PracticeMotionLibrary.install(into: root)
        for move in DanceCatalog.moves {
            let count = try PracticeMotionLibrary.frameCount(in: root, id: move.id)
            XCTAssertEqual(count, PracticeMotionLibrary.frameCount(for: move))
            XCTAssertGreaterThanOrEqual(count, 180)
            let raw = try PracticeMotionLibrary.load(in: root, id: move.id, optimized: false)
            let optimized = try PracticeMotionLibrary.load(in: root, id: move.id, optimized: true)
            XCTAssertEqual(raw.frameCount, optimized.frameCount)
            XCTAssertEqual(raw.data.count, count * AISTMotion.bytesPerFrame)
            XCTAssertNotEqual(raw.data, optimized.data)
            var rawGaps = 0
            var optimizedGaps = 0
            for frame in 0..<count {
                for joint in raw.joints(at: frame) where !joint.x.isFinite || !joint.y.isFinite || !joint.z.isFinite { rawGaps += 1 }
                for joint in optimized.joints(at: frame) where !joint.x.isFinite || !joint.y.isFinite || !joint.z.isFinite { optimizedGaps += 1 }
            }
            XCTAssertGreaterThan(rawGaps, 0, move.id)
            XCTAssertEqual(optimizedGaps, 0, move.id)
        }
        let bounce = try PracticeMotionLibrary.load(in: root, id: "hiphop-bounce", optimized: true)
        let pose = bounce.joints(at: 0)
        XCTAssertEqual(pose.count, 17)
        XCTAssertGreaterThan(pose[0].y, pose[5].y)
        XCTAssertGreaterThan(pose[11].y, pose[13].y)
        XCTAssertGreaterThan(pose[13].y, pose[15].y)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hiphop-bounce.optimized.f64"))
        XCTAssertThrowsError(try PracticeMotionLibrary.load(in: root, id: "hiphop-bounce", optimized: false)) { error in
            XCTAssertEqual(error as? PracticeMotionError, .incompletePair("hiphop-bounce"))
        }
    }

    func testLibrarySequenceRejectsAMissingLayer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aist-pair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sequences", isDirectory: true), withIntermediateDirectories: true)
        let id = "gMH_sBM_cAll_d01_mMH0_ch01"
        let byteCount = 2 * AISTMotion.bytesPerFrame
        let json = """
        {"id":"\(id)","genreCode":"gMH","genreName":"Middle Hip-hop","dancerID":"d01","musicID":"mMH0","frameCount":2,"fps":60,"rawPath":"sequences/\(id).raw.f64","optimizedPath":"sequences/\(id).optimized.f64","byteCount":\(byteCount),"ignored":false}
        """
        let sequence = try JSONDecoder().decode(AISTSequence.self, from: Data(json.utf8))
        let payload = Data(count: byteCount)
        try payload.write(to: root.appendingPathComponent(sequence.rawPath))
        XCTAssertThrowsError(try sequence.requireBothCoordinateFiles(in: root)) { error in
            XCTAssertEqual(error as? AISTDataError, .missingCoordinateLayer(id))
        }
        try payload.write(to: root.appendingPathComponent(sequence.optimizedPath))
        XCTAssertNoThrow(try sequence.requireBothCoordinateFiles(in: root))
    }
}
