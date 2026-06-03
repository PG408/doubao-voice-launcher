import XCTest

final class NoDoubleTapModeTests: XCTestCase {
    func testAppSourceAndReadmeDoNotExposeDoubleTapMode() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedFiles = [
            repositoryRoot.appendingPathComponent("Sources/DoubaoVoiceLauncher/main.swift"),
            repositoryRoot.appendingPathComponent("README.md")
        ]

        for file in checkedFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.contains("双击模式"), "\(file.path) should not expose double-tap mode")
            XCTAssertFalse(content.contains("doubleTap"), "\(file.path) should not keep doubleTap state")
            XCTAssertFalse(content.contains("double-tap"), "\(file.path) should not mention double-tap mode")
        }
    }
}
