from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch_kspnuvio_local_intro_vBRDC043.py KSOptions.swift FFmpegDecode.swift")

options_path = Path(sys.argv[1])
decoder_path = Path(sys.argv[2])
options = options_path.read_text()
decoder = decoder_path.read_text()

options_anchor = "#if canImport(UIKit)\nimport UIKit\n#endif\nopen class KSOptions {\n"
options_insert = """#if canImport(UIKit)
import UIKit
#endif

/// Debrid Channels vBRDC043 opt-in local intro fingerprint sample.
/// This is intentionally tiny and irreversible: no PCM data is exposed.
public struct KSAudioFingerprintSample {
    public let seconds: TimeInterval
    public let hash: UInt64
    public let energy: Float
    public let zeroCrossingRate: Float

    public init(seconds: TimeInterval, hash: UInt64, energy: Float, zeroCrossingRate: Float) {
        self.seconds = seconds
        self.hash = hash
        self.energy = energy
        self.zeroCrossingRate = zeroCrossingRate
    }
}

open class KSOptions {
"""
if options.count(options_anchor) != 1:
    raise SystemExit("Expected one KSOptions class anchor")
options = options.replace(options_anchor, options_insert, 1)

property_anchor = "    public var audioFilters = [String]()\n    public var syncDecodeAudio = false\n"
property_insert = "    public var audioFilters = [String]()\n    public var syncDecodeAudio = false\n    /// Optional local-only per-second audio fingerprint sink. Nil by default.\n    public var audioFingerprintSampleHandler: ((KSAudioFingerprintSample) -> Void)?\n"
if options.count(property_anchor) != 1:
    raise SystemExit("Expected one KSOptions audio property anchor")
options = options.replace(property_anchor, property_insert, 1)
options_path.write_text(options)

property_anchor = "    private let filter: MEFilter\n    private let seekByBytes: Bool\n"
property_insert = "    private let filter: MEFilter\n    private let seekByBytes: Bool\n    private var fingerprintSecond = -1\n    private var fingerprintLastSampleSeconds = -Double.greatestFiniteMagnitude\n    private var fingerprintEnergySum: Double = 0\n    private var fingerprintZeroCrossingSum: Double = 0\n    private var fingerprintFrameCount = 0\n    private var fingerprintBitVotes = [Int](repeating: 0, count: 64)\n    private var fingerprintFrameBinTotals = [Double](repeating: 0, count: 32)\n    private var fingerprintFrameBinCounts = [Int](repeating: 0, count: 32)\n"
if decoder.count(property_anchor) != 1:
    raise SystemExit("Expected one FFmpegDecode property anchor")
decoder = decoder.replace(property_anchor, property_insert, 1)

method_anchor = "    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {\n"
methods = r'''    private func resetFingerprintAccumulator(second: Int = -1) {
        fingerprintSecond = second
        fingerprintLastSampleSeconds = -Double.greatestFiniteMagnitude
        fingerprintEnergySum = 0
        fingerprintZeroCrossingSum = 0
        fingerprintFrameCount = 0
        for index in fingerprintBitVotes.indices { fingerprintBitVotes[index] = 0 }
    }

    private func publishFingerprintIfAvailable() {
        guard fingerprintSecond >= 0,
              fingerprintFrameCount > 0,
              let handler = options.audioFingerprintSampleHandler else { return }
        var hash: UInt64 = 0
        for index in 0..<64 where fingerprintBitVotes[index] * 2 >= fingerprintFrameCount {
            hash |= UInt64(1) << UInt64(index)
        }
        handler(KSAudioFingerprintSample(
            seconds: TimeInterval(fingerprintSecond),
            hash: hash,
            energy: Float(fingerprintEnergySum / Double(fingerprintFrameCount)),
            zeroCrossingRate: Float(fingerprintZeroCrossingSum / Double(fingerprintFrameCount))
        ))
    }

    private func accumulateFingerprint(_ frame: AudioFrame) {
        guard options.audioFingerprintSampleHandler != nil,
              frame.timebase.den != 0 else { return }
        let seconds = Double(frame.timestamp) * Double(frame.timebase.num) / Double(frame.timebase.den)
        guard seconds.isFinite, seconds >= 0, seconds <= (15 * 60 + 2) else { return }
        let second = Int(seconds.rounded(.down))
        if fingerprintSecond != second {
            publishFingerprintIfAvailable()
            resetFingerprintAccumulator(second: second)
        }

        // vBRDC049 playback graphics stability: one audio fingerprint sample every 125 ms
        // is ample for the one-second recurring-intro signature. AAC commonly produces
        // ~40-50 decoded frames per second; hashing every one of those frames needlessly
        // competes with video decode/presentation during the first 15 minutes. Keep the
        // full late-intro time window, but cut the decoder-thread analysis rate to <= 8 Hz.
        guard seconds - fingerprintLastSampleSeconds >= 0.125 else { return }
        fingerprintLastSampleSeconds = seconds

        guard let raw = frame.data.first ?? nil else { return }
        let sampleCount: Int
        switch frame.audioFormat.commonFormat {
        case .pcmFormatInt16:
            sampleCount = frame.dataSize / MemoryLayout<Int16>.size
        case .pcmFormatInt32:
            sampleCount = frame.dataSize / MemoryLayout<Int32>.size
        default:
            sampleCount = frame.dataSize / MemoryLayout<Float>.size
        }
        guard sampleCount >= 32 else { return }

        // Sample at most 192 points directly from the already-decoded PCM plane. Do not
        // call AudioFrame.toFloat(), which would allocate/copy the entire audio frame just
        // for intro detection. The two tiny passes below use no per-frame arrays.
        let targetCount = min(192, sampleCount)
        let step = max(1, sampleCount / max(1, targetCount))

        var sumSquares = 0.0
        var sumAbs = 0.0
        var crossings = 0
        var positiveCount = 0
        var previous: Float?
        var actualCount = 0
        for index in 0..<32 {
            fingerprintFrameBinTotals[index] = 0
            fingerprintFrameBinCounts[index] = 0
        }

        func consume(_ value: Float) {
            guard value.isFinite else { return }
            let clipped = max(-1, min(1, value))
            let sample = Double(clipped)
            let magnitude = abs(sample)
            sumSquares += sample * sample
            sumAbs += magnitude
            let bin = min(31, actualCount * 32 / max(1, targetCount))
            fingerprintFrameBinTotals[bin] += magnitude
            fingerprintFrameBinCounts[bin] += 1
            if clipped >= 0 { positiveCount += 1 }
            if let previous,
               (previous < 0 && clipped >= 0) || (previous >= 0 && clipped < 0) {
                crossings += 1
            }
            previous = clipped
            actualCount += 1
        }

        switch frame.audioFormat.commonFormat {
        case .pcmFormatInt16:
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { src in
                var index = 0
                while index < sampleCount && actualCount < targetCount {
                    consume(Float(src[index]) / 32767.0)
                    index += step
                }
            }
        case .pcmFormatInt32:
            raw.withMemoryRebound(to: Int32.self, capacity: sampleCount) { src in
                var index = 0
                while index < sampleCount && actualCount < targetCount {
                    consume(Float(src[index]) / 2_147_483_647.0)
                    index += step
                }
            }
        default:
            raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { src in
                var index = 0
                while index < sampleCount && actualCount < targetCount {
                    consume(src[index])
                    index += step
                }
            }
        }
        guard actualCount >= 32 else { return }
        let meanAbs = sumAbs / Double(actualCount)

        // Build a coarse temporal-energy signature from the same sampled PCM pass above.
        // The 32 tiny bin accumulators are decoder-instance storage reused for every frame,
        // so this path performs no per-frame collection allocation or second PCM traversal.
        var frameHash: UInt64 = 0
        var previousBin = 0.0
        for bin in 0..<32 {
            let count = fingerprintFrameBinCounts[bin]
            let average = count > 0 ? fingerprintFrameBinTotals[bin] / Double(count) : 0
            if average >= meanAbs { frameHash |= UInt64(1) << UInt64(bin) }
            if bin > 0, average >= previousBin { frameHash |= UInt64(1) << UInt64(31 + bin) }
            previousBin = average
        }
        if positiveCount * 2 >= actualCount {
            frameHash |= UInt64(1) << UInt64(63)
        }

        let rms = sqrt(sumSquares / Double(actualCount))
        let zeroCrossingRate = Double(crossings) / Double(max(1, actualCount - 1))
        fingerprintEnergySum += rms
        fingerprintZeroCrossingSum += zeroCrossingRate
        fingerprintFrameCount += 1
        for bit in 0..<64 where (frameHash & (UInt64(1) << UInt64(bit))) != 0 {
            fingerprintBitVotes[bit] += 1
        }
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
'''
if decoder.count(method_anchor) != 1:
    raise SystemExit("Expected one FFmpegDecode method anchor")
decoder = decoder.replace(method_anchor, methods, 1)

frame_anchor = "                        frame.timestamp = timestamp\n                        bestEffortTimestamp = timestamp &+ frame.duration\n                        completionHandler(.success(frame))\n"
frame_insert = "                        frame.timestamp = timestamp\n                        bestEffortTimestamp = timestamp &+ frame.duration\n                        if let audioFrame = frame as? AudioFrame {\n                            accumulateFingerprint(audioFrame)\n                        }\n                        completionHandler(.success(frame))\n"
if decoder.count(frame_anchor) != 1:
    raise SystemExit("Expected one FFmpegDecode frame completion anchor")
decoder = decoder.replace(frame_anchor, frame_insert, 1)

flush_anchor = "    func doFlushCodec() {\n        bestEffortTimestamp = Int64(0)\n"
if decoder.count(flush_anchor) != 1:
    raise SystemExit("Expected one flush anchor")
decoder = decoder.replace(flush_anchor, "    func doFlushCodec() {\n        bestEffortTimestamp = Int64(0)\n        resetFingerprintAccumulator()\n", 1)

decode_anchor = "    func decode() {\n        bestEffortTimestamp = Int64(0)\n"
if decoder.count(decode_anchor) != 1:
    raise SystemExit("Expected one decode reset anchor")
decoder = decoder.replace(decode_anchor, "    func decode() {\n        bestEffortTimestamp = Int64(0)\n        resetFingerprintAccumulator()\n", 1)

decoder_path.write_text(decoder)
