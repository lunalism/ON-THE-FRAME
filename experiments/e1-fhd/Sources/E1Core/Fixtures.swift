import CryptoKit
import Foundation

/// 재현 가능한 합성 오디오 fixture. 모든 시각은 샘플 인덱스(48 kHz)로 정의한다.
public struct AudioFixtureSpec: Codable, Sendable {
    public struct Tone: Codable, Sendable { public let startSample: Int; public let endSample: Int; public let hz: Double; public let amplitude: Double }
    public let name: String
    public let lengthSamples: Int
    public let tones: [Tone]
    public let clickStartSamples: [Int]
    public let clickLengthSamples: Int
    public let clickAmplitude: Double
    public let clickSeed: UInt64
    public let fadeSamples: Int
    public let format: String

    /// 선택 소스 S (20초). 톤 135/600/2700 Hz, 클릭은 프레임 중간 시각 (2k+1)/60 s.
    public static let selected = AudioFixtureSpec(
        name: "S-selected",
        lengthSamples: 20 * 48_000,
        tones: [
            Tone(startSample: 0, endSample: 3 * 48_000, hz: 135, amplitude: 0.25),
            Tone(startSample: 5 * 48_000, endSample: 8 * 48_000, hz: 600, amplitude: 0.25),
            Tone(startSample: 12 * 48_000, endSample: 15 * 48_000, hz: 2700, amplitude: 0.25),
        ],
        clickStartSamples: [168_800, 216_800, 312_800, 648_800, 792_800, 888_800],
        clickLengthSamples: 96, clickAmplitude: 0.8, clickSeed: 0x5E1EC7ED,
        fadeSamples: 240, format: "WAVE LPCM s16le 48000 Hz stereo (L=R)")

    /// 무관 오디오 U (20초). 4700 Hz 연속 톤, 클릭은 1.25 + 2k s.
    public static let unrelated = AudioFixtureSpec(
        name: "U-unrelated",
        lengthSamples: 20 * 48_000,
        tones: [Tone(startSample: 0, endSample: 20 * 48_000, hz: 4700, amplitude: 0.2)],
        clickStartSamples: (0..<10).map { 60_000 + 96_000 * $0 },
        clickLengthSamples: 96, clickAmplitude: 0.8, clickSeed: 0x0BADC0DE,
        fadeSamples: 240, format: "WAVE LPCM s16le 48000 Hz stereo (L=R)")

    func clickBurst() -> [Double] {
        var state = clickSeed
        var out = [Double](repeating: 0, count: clickLengthSamples)
        for i in 0..<clickLengthSamples {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF) * 2 - 1
            out[i] = u * clickAmplitude
        }
        out[0] = clickAmplitude  // 시작 샘플을 명확히 해서 onset 측정을 쉽게 한다
        return out
    }

    func sample(_ i: Int, burst: [Double]) -> Double {
        var x = 0.0
        for t in tones where i >= t.startSample && i < t.endSample {
            let k = i - t.startSample
            let fromEnd = t.endSample - 1 - i
            var g = 1.0
            let edge = min(k, fromEnd)
            if edge < fadeSamples { g = 0.5 * (1 - cos(Double.pi * Double(edge) / Double(fadeSamples))) }
            x += t.amplitude * g * sin(2 * Double.pi * t.hz * Double(k) / 48_000)
        }
        for c in clickStartSamples where i >= c && i < c + clickLengthSamples {
            x += burst[i - c]
        }
        return max(-1, min(1, x))
    }

    /// WAV 바이트를 직접 만든다(변환기·디더 개입 없음).
    public func wavData() -> Data {
        let burst = clickBurst()
        let ch = 2, bytesPerFrame = 4
        let dataBytes = lengthSamples * bytesPerFrame
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(ch)); u32(48_000)
        u32(UInt32(48_000 * bytesPerFrame)); u16(UInt16(bytesPerFrame)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var frame = [Int16](repeating: 0, count: 2)
        for i in 0..<lengthSamples {
            let v = Int16((sample(i, burst: burst) * 32767).rounded())
            frame[0] = v.littleEndian; frame[1] = v.littleEndian
            frame.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        return d
    }
}

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 파일을 1 MiB 단위로 읽어 해시한다.
    public static func sha256(file url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
