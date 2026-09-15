import Foundation

enum SHA256Digest {
    static func hash(_ data: Data) -> Data {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize()
    }

    static func hexString(of data: Data) -> String {
        hash(data).reduce(into: "") { result, byte in
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0F)])
        }
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}

private struct SHA256Hasher {
    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0x6A09E667,
        0xBB67AE85,
        0x3C6EF372,
        0xA54FF53A,
        0x510E527F,
        0x9B05688C,
        0x1F83D9AB,
        0x5BE0CD19
    )
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var bufferLength = 0
    private var bitCount: UInt64 = 0

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            update(base, count: rawBuffer.count)
        }
    }

    mutating func finalize() -> Data {
        var copy = self
        copy.buffer[copy.bufferLength] = 0x80
        copy.bufferLength += 1
        if copy.bufferLength > 56 {
            while copy.bufferLength < 64 {
                copy.buffer[copy.bufferLength] = 0
                copy.bufferLength += 1
            }
            copy.processBlock()
            copy.bufferLength = 0
        }
        while copy.bufferLength < 56 {
            copy.buffer[copy.bufferLength] = 0
            copy.bufferLength += 1
        }
        var bits = copy.bitCount.bigEndian
        withUnsafeBytes(of: &bits) { bitBytes in
            for index in 0..<8 {
                copy.buffer[56 + index] = bitBytes[index]
            }
        }
        copy.processBlock()

        var digest = Data(count: 32)
        digest.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            let words = [
                copy.state.0.bigEndian,
                copy.state.1.bigEndian,
                copy.state.2.bigEndian,
                copy.state.3.bigEndian,
                copy.state.4.bigEndian,
                copy.state.5.bigEndian,
                copy.state.6.bigEndian,
                copy.state.7.bigEndian,
            ]
            var offset = 0
            for word in words {
                var value = word
                withUnsafeBytes(of: &value) { wordBytes in
                    for index in 0..<4 {
                        rawBuffer[offset + index] = wordBytes[index]
                    }
                }
                offset += 4
            }
        }
        return digest
    }

    private mutating func update(_ bytes: UnsafePointer<UInt8>, count: Int) {
        bitCount += UInt64(count) * 8
        var remaining = count
        var pointer = bytes
        if bufferLength > 0 {
            let toCopy = min(64 - bufferLength, remaining)
            for index in 0..<toCopy {
                buffer[bufferLength + index] = pointer[index]
            }
            bufferLength += toCopy
            pointer += toCopy
            remaining -= toCopy
            if bufferLength == 64 {
                processBlock()
                bufferLength = 0
            }
        }
        while remaining >= 64 {
            for index in 0..<64 {
                buffer[index] = pointer[index]
            }
            processBlock()
            pointer += 64
            remaining -= 64
        }
        for index in 0..<remaining {
            buffer[index] = pointer[index]
        }
        bufferLength = remaining
    }

    private mutating func processBlock() {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let offset = index * 4
            words[index] =
                (UInt32(buffer[offset]) << 24)
                | (UInt32(buffer[offset + 1]) << 16)
                | (UInt32(buffer[offset + 2]) << 8)
                | UInt32(buffer[offset + 3])
        }
        for index in 16..<64 {
            let s0 =
                rotateRight(words[index - 15], by: 7)
                ^ rotateRight(words[index - 15], by: 18)
                ^ (words[index - 15] >> 3)
            let s1 =
                rotateRight(words[index - 2], by: 17)
                ^ rotateRight(words[index - 2], by: 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = state.0
        var b = state.1
        var c = state.2
        var d = state.3
        var e = state.4
        var f = state.5
        var g = state.6
        var h = state.7

        for index in 0..<64 {
            let s1 =
                rotateRight(e, by: 6)
                ^ rotateRight(e, by: 11)
                ^ rotateRight(e, by: 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ k[index] &+ words[index]
            let s0 =
                rotateRight(a, by: 2)
                ^ rotateRight(a, by: 13)
                ^ rotateRight(a, by: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state.0 &+= a
        state.1 &+= b
        state.2 &+= c
        state.3 &+= d
        state.4 &+= e
        state.5 &+= f
        state.6 &+= g
        state.7 &+= h
    }
}

private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
}

private let k: [UInt32] = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
    0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
    0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
    0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
    0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
    0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
]
