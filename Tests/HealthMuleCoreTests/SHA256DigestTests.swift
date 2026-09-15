import Foundation
import Testing
@testable import HealthMuleCore

@Suite("SHA-256 digest")
struct SHA256DigestTests {
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
    ])
    func matchesPublishedVectors(input: String, digest: String) {
        #expect(SHA256Digest.hexString(of: Data(input.utf8)) == digest)
    }
}
