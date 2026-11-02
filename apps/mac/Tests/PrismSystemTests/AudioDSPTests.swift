import CoreAudio
import PrismAudioDSP
import Testing

struct AudioDSPTests {
    private func render(_ state: OpaquePointer, samples: [Float], channels: UInt32 = 2, outputChannels: UInt32 = 2,
                        outputFrames: Int? = nil) -> [Float] {
        var input = samples
        var output = [Float](repeating: 99, count: (outputFrames ?? samples.count / Int(channels)) * Int(outputChannels))
        input.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels,
                    mDataByteSize: UInt32(source.count), mData: source.baseAddress))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: outputChannels,
                    mDataByteSize: UInt32(destination.count), mData: destination.baseAddress))
                PrismAudioDSPRender(state, &inputList, &outputList)
            }
        }
        return output
    }

    @Test func preflightReadsSignalWithoutPlayingADuplicateAndGainRampsToTarget() throws {
        let state = try #require(PrismAudioDSPCreate(0.5))
        defer { PrismAudioDSPDestroy(state) }
        let samples = [Float](repeating: 0.8, count: 2048)
        #expect(render(state, samples: samples).allSatisfy { $0 == 0 })
        #expect(PrismAudioDSPHasSignal(state))
        PrismAudioDSPArm(state)
        let played = render(state, samples: samples)
        #expect(abs((played.last ?? 0) - 0.4) < 0.00001)
        #expect(played[0] > 0 && played[0] < 0.4)
        PrismAudioDSPSetGain(state, 0)
        #expect(render(state, samples: samples).last == 0)
    }

    @Test func silentOrNonfiniteInputCannotArmCaptureAndShortBuffersAreZeroFilled() throws {
        let state = try #require(PrismAudioDSPCreate(1))
        defer { PrismAudioDSPDestroy(state) }
        _ = render(state, samples: [0, 0, .nan, .infinity])
        #expect(!PrismAudioDSPHasSignal(state))
        PrismAudioDSPArm(state)
        _ = render(state, samples: [Float](repeating: 1, count: 1024))
        let short = render(state, samples: [0.4, 0.8], outputFrames: 3)
        #expect(short == [0.4, 0.8, 0, 0, 0, 0])
    }

    @Test func stereoDownmixAndMonoDuplicationKeepChannelLevels() throws {
        let state = try #require(PrismAudioDSPCreate(1))
        defer { PrismAudioDSPDestroy(state) }
        PrismAudioDSPArm(state)
        _ = render(state, samples: [Float](repeating: 1, count: 1024))
        #expect(render(state, samples: [0.2, 0.6], outputChannels: 1)[0] == 0.4)
        #expect(render(state, samples: [0.3], channels: 1) == [0.3, 0.3])
        PrismAudioDSPSetGain(state, .nan)
        #expect(render(state, samples: [Float](repeating: 1, count: 1024)).last == 0)
    }

    @Test func noninterleavedStereoIsMappedWithoutReadingPastEitherBuffer() throws {
        let state = try #require(PrismAudioDSPCreate(1))
        defer { PrismAudioDSPDestroy(state) }
        PrismAudioDSPArm(state)
        _ = render(state, samples: [Float](repeating: 1, count: 1024))
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride,
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let pointer = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = 2
        let input = UnsafeMutableAudioBufferListPointer(pointer)
        var left: [Float] = [0.2, 0.4], right: [Float] = [0.6]
        var output: [Float] = [99, 99, 99, 99]
        left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r in output.withUnsafeMutableBytes { out in
            input[0] = .init(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
            input[1] = .init(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
            var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: .init(mNumberChannels: 2,
                                              mDataByteSize: UInt32(out.count), mData: out.baseAddress))
            PrismAudioDSPRender(state, input.unsafePointer, &outputList)
        } } }
        #expect(output == [0.2, 0.6, 0, 0])
    }
}
