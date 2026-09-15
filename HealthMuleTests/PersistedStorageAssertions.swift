import Foundation
import XCTest

enum PersistedStorageAssertions {
    static func assertProtectedAndExcludedFromBackup(
        _ url: URL,
        expectedProtection: FileProtectionType =
            .completeUntilFirstUserAuthentication,
        excludesFromBackup: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey, .fileProtectionKey]
        )
        XCTAssertEqual(
            values.isExcludedFromBackup,
            excludesFromBackup,
            file: file,
            line: line
        )
        if let protection = values.fileProtection {
            XCTAssertEqual(
                protection,
                URLFileProtection.completeUntilFirstUserAuthentication,
                file: file,
                line: line
            )
            return
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(
                protection,
                expectedProtection,
                file: file,
                line: line
            )
            return
        }
        XCTFail("missing file protection class", file: file, line: line)
    }
}
