import Foundation
import NeoClashCore
import XCTest

final class AtomicFileWriterTests: XCTestCase {
    func testFailedReplacementCleansTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeoClashAtomicWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("config.yaml", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("child"))

        XCTAssertThrowsError(try AtomicFileWriter.write(Data("replacement".utf8), to: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("child").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".config.yaml.tmp-") }
        XCTAssertEqual(leftovers, [])
    }
}
