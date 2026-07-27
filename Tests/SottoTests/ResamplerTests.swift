import Testing
import AVFoundation
@testable import Sotto

struct ResamplerTests {
    private func sine(frequency: Double, rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(rate * seconds)
        return (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// Estimate frequency by counting positive-going zero crossings.
    private func estimatedFrequency(_ samples: [Float], rate: Double) -> Double {
        var crossings = 0
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 {
            crossings += 1
        }
        return Double(crossings) / (Double(samples.count) / rate)
    }

    @Test func sineResample48kTo16k() {
        let input = sine(frequency: 440, rate: 48_000, seconds: 1)
        var out: [Float] = []
        let n = input.withUnsafeBufferPointer {
            AudioUtil.resampleLinearTo16k($0, inputRate: 48_000, into: &out)
        }
        #expect(n == 16_000)
        let freq = estimatedFrequency(Array(out[0..<n]), rate: 16_000)
        #expect(abs(freq - 440) <= 2)
    }

    @Test func resampleFrom16kIsIdentity() {
        let input = sine(frequency: 200, rate: 16_000, seconds: 0.25)
        var out: [Float] = []
        let n = input.withUnsafeBufferPointer {
            AudioUtil.resampleLinearTo16k($0, inputRate: 16_000, into: &out)
        }
        #expect(n == input.count)
        for i in 0..<n {
            #expect(abs(out[i] - input[i]) <= 1e-6)
        }
    }

    @Test func emptyInputReturnsZero() {
        var out: [Float] = []
        let n = [Float]().withUnsafeBufferPointer {
            AudioUtil.resampleLinearTo16k($0, inputRate: 48_000, into: &out)
        }
        #expect(n == 0)
    }

    @Test func scratchBufferDoesNotRegrow() {
        let input = sine(frequency: 440, rate: 48_000, seconds: 0.1)
        var out: [Float] = []
        _ = input.withUnsafeBufferPointer {
            AudioUtil.resampleLinearTo16k($0, inputRate: 48_000, into: &out)
        }
        let sizeAfterFirst = out.count
        let capacityAfterFirst = out.capacity
        _ = input.withUnsafeBufferPointer {
            AudioUtil.resampleLinearTo16k($0, inputRate: 48_000, into: &out)
        }
        #expect(out.count == sizeAfterFirst)
        #expect(out.capacity == capacityAfterFirst)
    }

    /// The VPIO regression: a buffer with an unexpected multichannel layout
    /// must use channel 0 only and must not crash.
    @Test func multichannelBufferUsesChannelZeroOnly() throws {
        let layout = try #require(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        let reference = sine(frequency: 440, rate: 48_000, seconds: 0.1)
        let frames = AVAudioFrameCount(reference.count)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let channels = try #require(buffer.floatChannelData)
        reference.withUnsafeBufferPointer { src in
            channels[0].update(from: src.baseAddress!, count: reference.count)
        }
        // Garbage in every other channel — must not leak into the output.
        for channel in 1..<9 {
            channels[channel].update(repeating: 123.0, count: reference.count)
        }

        var out: [Float] = []
        let n = AudioUtil.resampleChannel0To16k(buffer, into: &out)

        var expected: [Float] = []
        let expectedN = reference.withUnsafeBufferPointer {
            AudioUtil.resampleLinearTo16k($0, inputRate: 48_000, into: &expected)
        }
        #expect(n == expectedN)
        #expect(n > 0)
        for i in 0..<n {
            #expect(abs(out[i] - expected[i]) <= 1e-6)
        }
    }
}
