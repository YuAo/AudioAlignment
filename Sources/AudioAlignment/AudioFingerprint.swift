import AVFoundation
import Accelerate
import OSLog

/// A shift-invariant, spectrum based fingerprint of an audio clip.
public struct AudioFingerprint {
    
    private static let log = OSLog(subsystem: "com.imyuao.audio-alignment.fingerprint", category: "performance")
    
    public typealias SamplePosition = Int32
    public typealias Frequency = Int32
    
    public enum FingerprintError: Swift.Error {
        case audioTooShort
        case cannotCreatePCMBuffer
        case cannotCreateAudioConverter
        case cannotSetupFFT
        case stftSegmentTooShort
        case invalidSTFTSegment
        case noPatternsFound
    }
    
    public enum ImageProcessorError: Swift.Error {
        case vImageHistogramError(vImage_Error)
        case vImageMaxError(vImage_Error)
    }
    
    /// Short-time Fourier transform configuration.
    public struct STFTConfiguration: Hashable {
        public init(segment: Int = 1024, overlap: Int = Int(0.9 * 1024)) {
            self.segment = segment
            self.overlap = overlap
        }
        
        /// Length of each segment, i.e. the number of samples in a STFT window.
        public var segment: Int
        
        /// Number of samples to overlap between segments.
        public var overlap: Int
    }
    
    /// A configuration that controls peek generation.
    public struct PeaksConfiguration: Hashable {
        public init(localMaximumKernelSize: Int = 5, maximumAmplitudeApproximatePercentile: Float = 0.999, relativeMinimumAmplitude: Float = -35, minimumFrequency: Frequency = 50, maximumFrequency: Frequency = 5000) {
            self.localMaximumKernelSize = localMaximumKernelSize
            self.maximumAmplitudeApproximatePercentile = maximumAmplitudeApproximatePercentile
            self.relativeMinimumAmplitude = relativeMinimumAmplitude
            self.minimumFrequency = minimumFrequency
            self.maximumFrequency = maximumFrequency
        }
        
        /// Number of cells around an amplitude peak in the spectrogram to be considered a spectral peak.
        public var localMaximumKernelSize: Int
        
        /// Percentile for approximating the maximum amplitude in the spectrogram.
        public var maximumAmplitudeApproximatePercentile: Float

        /// Minimum amplitude in the spectrogram to be considered a peak, relative to the maximum amplitude in the spectrogram.
        public var relativeMinimumAmplitude: Float
        
        /// Minimum frequency of a sample in the spectrogram to be considered a peak.
        public var minimumFrequency: Frequency
        
        /// Maximum frequency of a sample in the spectrogram to be considered a peak.
        public var maximumFrequency: Frequency
    }
    
    /// A configuration that controls pattern generation.
    public struct PatternsConfiguration: Hashable {
        public init(fan: Int = 10, minimumSamplePositionDelta: SamplePosition = 0, maximumSamplePositionDelta: SamplePosition = 8000) {
            self.fan = fan
            self.minimumSamplePositionDelta = minimumSamplePositionDelta
            self.maximumSamplePositionDelta = maximumSamplePositionDelta
        }
        
        /// Degree to which a peek can be paired with its neighbors.
        public var fan: Int
        
        /// How close peeks can be in order to be paired as a pattern.
        public var minimumSamplePositionDelta: SamplePosition
        
        /// How far peeks can be in order to be paired as a pattern.
        public var maximumSamplePositionDelta: SamplePosition
    }
    
    /// A configuration that controls the fingerprint generation.
    public struct Configuration: Hashable {
        public init(sampleRate: Double = 16000, stftConfiguration: AudioFingerprint.STFTConfiguration = STFTConfiguration(), peaksConfiguration: AudioFingerprint.PeaksConfiguration = PeaksConfiguration(), patternsConfiguration: AudioFingerprint.PatternsConfiguration = PatternsConfiguration()) {
            self.sampleRate = sampleRate
            self.stftConfiguration = stftConfiguration
            self.peaksConfiguration = peaksConfiguration
            self.patternsConfiguration = patternsConfiguration
        }
        
        /// Sample rate used in fingerprint generation.
        public var sampleRate: Double
        
        /// Short-time Fourier transform configuration.
        public var stftConfiguration: STFTConfiguration
        
        /// Configuration that controls peek generation.
        public var peaksConfiguration: PeaksConfiguration
        
        /// Configuration that controls pattern generation.
        public var patternsConfiguration: PatternsConfiguration
        
        /// The finest time resolution of this configuration.
        public var finestTimeResolution: Float {
            return Float(stftConfiguration.segment - stftConfiguration.overlap) / Float(sampleRate)
        }
    }
    
    private struct Spectrum {
        var frequencies: [Frequency]
        var positions: [SamplePosition]
        var stft: [Float]
    }
    
    private struct Peak {
        var frequency: Frequency
        var position: SamplePosition
    }
    
    private struct Pattern: Hashable {
        var frequencyA: Frequency
        var frequencyB: Frequency
        var positionDelta: SamplePosition
    }
    
    private typealias Patterns = [Pattern: SamplePosition]
    
    private let patterns: Patterns
    
    /// Configuration used to generate this fingerprint.
    public let configuration: Configuration
    
    /// Creates an audio fingerprint from a file URL.
    public init(audioURL: URL, configuration: Configuration = Configuration()) throws {
        let sourceBuffer = try AudioFingerprint.decodeAudioFile(url: audioURL, commonFormat: .pcmFormatFloat32)
        try self.init(audioBuffer: sourceBuffer, configuration: configuration)
    }
    
    /// Creates an audio fingerprint from a PCM buffer.
    public init(audioBuffer inAudioBuffer: AVAudioPCMBuffer, configuration: Configuration = Configuration()) throws {
        let audioBuffer = try AudioFingerprint.convertAudioBuffer(inAudioBuffer, commonFormat: .pcmFormatFloat32, sampleRate: configuration.sampleRate)
        let spectrum = try AudioFingerprint.makeSpectrum(audio: audioBuffer.floatChannelData!.pointee, sampleCount: Int(audioBuffer.frameLength), sampleRate: audioBuffer.format.sampleRate, configuration: configuration.stftConfiguration)
        let peaks = try AudioFingerprint.makePeaks(spectrum: spectrum, configuration: configuration.peaksConfiguration)
        let patterns = try AudioFingerprint.makePatterns(peaks: peaks, configuration: configuration.patternsConfiguration)
        self.configuration = configuration
        self.patterns = patterns
    }
}

extension AudioFingerprint {
    
    private static func convertAudioBuffer(_ buffer: AVAudioPCMBuffer, commonFormat: AVAudioCommonFormat, sampleRate: Double) throws -> AVAudioPCMBuffer {
        os_signpost(.begin, log: AudioFingerprint.log, name: "convert")
        defer {
            os_signpost(.end, log: AudioFingerprint.log, name: "convert")
        }
        
        if buffer.format.commonFormat == commonFormat && buffer.format.sampleRate == sampleRate {
            return buffer
        }
        
        let duration = ceil(Double(buffer.frameLength) / buffer.format.sampleRate)
        let targetFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
            throw FingerprintError.cannotCreatePCMBuffer
        }
        guard let audioConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw FingerprintError.cannotCreateAudioConverter
        }
        audioConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var dataProvided: Bool = false
        audioConverter.convert(to: targetBuffer, error: nil, withInputFrom: { count, status in
            if dataProvided {
                status.pointee = .endOfStream
                return nil
            } else {
                status.pointee = .haveData
                dataProvided = true
                return buffer
            }
        })
        return targetBuffer
    }
    
    private static func decodeAudioFile(url: URL, commonFormat: AVAudioCommonFormat) throws -> AVAudioPCMBuffer {
        os_signpost(.begin, log: AudioFingerprint.log, name: "decode")
        defer {
            os_signpost(.end, log: AudioFingerprint.log, name: "decode")
        }
        
        let audioFile = try AVAudioFile(forReading: url, commonFormat: commonFormat, interleaved: false)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw FingerprintError.cannotCreatePCMBuffer
        }
        try audioFile.read(into: sourceBuffer)
        return sourceBuffer
    }
    
    private static func makeSpectrum(audio: UnsafePointer<Float>, sampleCount: Int, sampleRate: Double, configuration: STFTConfiguration) throws -> Spectrum {
        os_signpost(.begin, log: AudioFingerprint.log, name: "spectrum")
        defer {
            os_signpost(.end, log: AudioFingerprint.log, name: "spectrum")
        }
        
        guard configuration.segment > 16 else {
            throw FingerprintError.stftSegmentTooShort
        }
        guard sampleCount > configuration.segment * 2, sampleCount > Int(sampleRate) else {
            throw FingerprintError.audioTooShort
        }
        let log2n = vDSP_Length(log2(Float(configuration.segment)))
        guard pow(2, Double(log2n)) == Double(configuration.segment) else {
            throw FingerprintError.invalidSTFTSegment
        }
        
        let complexValuesCount = configuration.segment / 2
        let positionCount = (sampleCount - configuration.segment) / (configuration.segment - configuration.overlap) + 1
        
        let frequences: [Frequency] = {
            let fhz = sampleRate/2
            let channel = fhz / (Double(configuration.segment) / 2)
            return (0..<configuration.segment/2).map({ i in Frequency(round(channel * Double(i))) })
        }()
        
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw FingerprintError.cannotSetupFFT
        }
        
        var window = [Float](repeating: 0, count: configuration.segment)
        vDSP_hann_window(&window, vDSP_Length(configuration.segment), Int32(vDSP_HANN_NORM))
        
        let scale = 1.0 / window.reduce(0, +) / 2.0 // `/ 2.0` : See https://developer.apple.com/library/archive/documentation/Performance/Conceptual/vDSP_Programming_Guide/UsingFourierTransforms/UsingFourierTransforms.html#//apple_ref/doc/uid/TP40005147-CH3-SW5
        
        let vScaleScale = [scale]
        let vScalar20: [Float] = [20]
        let vScalar1eNeg20: [Float] = [1e-20]
        let vScalarComplexValuesCount: [Int32] = [Int32(complexValuesCount)]
        
        var complexImaginaries = [Float](repeating: 0,
                                         count: complexValuesCount)
        var buffer = [Float](repeating: 0, count: configuration.segment)
        
        var stft = [Float](unsafeUninitializedCapacity: positionCount * complexValuesCount, initializingWith: { _, count in count = positionCount * complexValuesCount })
        var positions = [SamplePosition](unsafeUninitializedCapacity: positionCount, initializingWith: { _, count in count = positionCount })

        var stftIndex = 0
        var sampleIndex = 0
        while sampleIndex + configuration.segment <= sampleCount {
            vDSP_vmul(audio.advanced(by: sampleIndex), 1, window, 1, &buffer, 1, vDSP_Length(configuration.segment))
            buffer.withUnsafeBytes { bufferPtr in
                stft.withUnsafeMutableBufferPointer { stftPtr in
                    complexImaginaries.withUnsafeMutableBufferPointer { imagPtr in
                        let stftPtr = stftPtr.baseAddress!.advanced(by: stftIndex * complexValuesCount)
                        var splitComplex = DSPSplitComplex(realp: stftPtr,
                                                           imagp: imagPtr.baseAddress!)
                        vDSP_ctoz(bufferPtr.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                                  &splitComplex, 1,
                                  vDSP_Length(complexValuesCount))
                        vDSP_fft_zrip(fft,
                                      &splitComplex, 1,
                                      log2n,
                                      FFTDirection(kFFTDirection_Forward))
                        
                        // Blow away the packed nyquist component.
                        imagPtr[0] = 0
                        
                        vDSP_zvabs(&splitComplex, 1, stftPtr, 1, vDSP_Length(complexValuesCount))
                        vDSP_vsmul(stftPtr, 1, vScaleScale, stftPtr, 1, vDSP_Length(complexValuesCount))
                        vDSP_vsadd(stftPtr, 1, vScalar1eNeg20, stftPtr, 1, vDSP_Length(complexValuesCount))
                        vvlog10f(stftPtr, stftPtr, vScalarComplexValuesCount)
                        vDSP_vsmul(stftPtr, 1, vScalar20, stftPtr, 1, vDSP_Length(complexValuesCount))
                    }
                }
            }
            positions[stftIndex] = SamplePosition(sampleIndex)
            
            sampleIndex += (configuration.segment - configuration.overlap)
            stftIndex += 1
        }
        
        vDSP_destroy_fftsetup(fft)
        
        return Spectrum(frequencies: frequences, positions: positions, stft: stft)
    }
    
    private static func makePeaks(spectrum: Spectrum, configuration: PeaksConfiguration) throws -> [Peak] {
        os_signpost(.begin, log: AudioFingerprint.log, name: "peaks")
        defer {
            os_signpost(.end, log: AudioFingerprint.log, name: "peaks")
        }
        var localMaximum = [Float](unsafeUninitializedCapacity: spectrum.stft.count, initializingWith: { _, count in count = spectrum.stft.count })
        let width = spectrum.frequencies.count
        let height = spectrum.stft.count/spectrum.frequencies.count
        try localMaximum.withUnsafeMutableBytes({ ptr in
            try spectrum.stft.withUnsafeBytes({ src in
                //src.baseAddress: not actually mutating.
                var srcBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
                var buffer = vImage_Buffer(data: ptr.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
                let error = vImageMax_PlanarF(&srcBuffer, &buffer, nil, 0, 0, vImagePixelCount(configuration.localMaximumKernelSize), vImagePixelCount(configuration.localMaximumKernelSize), vImage_Flags(kvImageNoFlags))
                if error != kvImageNoError {
                    throw ImageProcessorError.vImageMaxError(error)
                }
            })
        })
        
        let largestValApprox = try approximatePercetile(spectrum.stft, delta: 0.1, percetile: configuration.maximumAmplitudeApproximatePercentile)
        
        let minValue = largestValApprox + configuration.relativeMinimumAmplitude
        
        var peaks: [Peak] = []
        for (index, value) in spectrum.stft.enumerated() where value == localMaximum[index] {
            let frequenceIndex = index % width
            let frequency = spectrum.frequencies[frequenceIndex]
            if value > minValue && frequency >= configuration.minimumFrequency && frequency <= configuration.maximumFrequency {
                let positionIndex = index / width
                peaks.append(Peak(frequency: frequency, position: spectrum.positions[positionIndex]))
            }
        }
        
        return peaks
    }
    
    private static func makePatterns(peaks: [Peak], configuration: PatternsConfiguration) throws -> Patterns {
        os_signpost(.begin, log: AudioFingerprint.log, name: "patterns")
        defer {
            os_signpost(.end, log: AudioFingerprint.log, name: "patterns")
        }
        
        var patterns: Patterns = [:]
        let numberOfPeaks = peaks.count
        for i in 0..<numberOfPeaks {
            for j in 1..<configuration.fan {
                if i + j < numberOfPeaks {
                    let peak1 = peaks[i]
                    let peak2 = peaks[i + j]
                    let positionDelta = peak2.position - peak1.position
                    if configuration.minimumSamplePositionDelta <= positionDelta && positionDelta <= configuration.maximumSamplePositionDelta {
                        patterns[Pattern(frequencyA: peak1.frequency, frequencyB: peak2.frequency, positionDelta: positionDelta)] = peak1.position
                    }
                }
            }
        }
        
        guard patterns.count > 0 else {
            throw FingerprintError.noPatternsFound
        }
        
        return patterns
    }
}

extension AudioFingerprint {
    
    private static func approximatePercetile(_ values: [Float], delta: Float, percetile: Float) throws -> Float {
        precondition(values.count > 0)
        precondition(percetile >= 0 && percetile <= 1)
        
        let (histogram, bins) = try AudioFingerprint.histogram(values, delta: delta)
        var pdf: Double = 0
        for (index, value) in histogram.enumerated() {
            pdf += Double(value) / Double(values.count)
            if pdf >= Double(percetile) {
                return bins[index]
            }
        }
        fatalError("[AudioFingerprint.approximatePercetile] Cannot find percentile.")
    }
    
    private static func histogram(_ values: [Float], delta: Float) throws -> (histogram: [UInt], binCenters: [Float]) {
        precondition(values.count > 0)
        precondition(delta > 0)
        
        var max: Float = values[0]
        var min: Float = values[0]
        vDSP_maxv(values, 1, &max, vDSP_Length(values.count))
        vDSP_minv(values, 1, &min, vDSP_Length(values.count))
        if min == max {
            return ([UInt(values.count)], [min])
        }
        let nbins = Int(ceil((max - min)/delta))
        var histogram = [vImagePixelCount](repeating: 0, count: nbins)
        try values.withUnsafeBytes({ input in
            try histogram.withUnsafeMutableBufferPointer({ hist in
                //input.baseAddress: not actually mutating.
                var buffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress), height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * MemoryLayout<Float>.size)
                let error = vImageHistogramCalculation_PlanarF(&buffer, hist.baseAddress!, UInt32(nbins), min, max, 0)
                if error != kvImageNoError {
                    throw ImageProcessorError.vImageHistogramError(error)
                }
            })
        })
        let channel = (max - min) / Float(nbins)
        let bins: [Float] = (0..<nbins).map({ i in min + channel * Float(i) + channel * 0.5 })
        return (histogram, bins)
    }
}

extension AudioFingerprint {
    
    /// Options that control the fingerprint alignment.
    public struct FittingOptions {
        public init(timeResolution: Float = 0.001, timeResolutionCoarse: Float = 0.1, focusInterval: Float = 5) {
            self.timeResolution = timeResolution
            self.timeResolutionCoarse = timeResolutionCoarse
            self.focusInterval = focusInterval
        }
        
        /// Time resolution used in the fingerprint alignment.
        public var timeResolution: Float
        
        /// Coarse time resolution used in the fingerprint alignment.
        public var timeResolutionCoarse: Float
        
        /// Focus interval, in seconds, for searching around the coarse alignment.
        public var focusInterval: Float
    }
    
    public enum FittingError: Swift.Error {
        case noMatchesFound
        case fingerprintConfigurationMismatch
    }
    
    /// Alignment information of two audio fingerprints.
    public struct Alignment {
        /// The estimated time offset of the source fingerprint relative to the start of the reference fingerprint.
        public var estimatedTimeOffset: Float
    }
    
    /// Align the fingerprint with a reference fingerprint.
    public func align(with reference: AudioFingerprint, options: FittingOptions = FittingOptions()) throws -> Alignment {
        os_signpost(.begin, log: AudioFingerprint.log, name: "fit")
        defer {
            os_signpost(.end, log: AudioFingerprint.log, name: "fit")
        }
        
        guard self.configuration == reference.configuration else {
            throw FittingError.fingerprintConfigurationMismatch
        }
        
        let finestResoultion = configuration.finestTimeResolution
        let timeResolution = max(options.timeResolution, finestResoultion)
        let timeResolutionCoarse = max(options.timeResolutionCoarse, finestResoultion)
        let focusInterval = options.focusInterval
        var diffs: [Float] = []
        for (pattern, position) in patterns {
            if let refPosition = reference.patterns[pattern] {
                diffs.append(Float(Double(refPosition - position)/configuration.sampleRate))
            }
        }
        
        guard diffs.count > 0 else {
            throw FittingError.noMatchesFound
        }
        
        let (histCoarse, offsetsCoarse) = try AudioFingerprint.histogram(diffs, delta: timeResolutionCoarse)
        let maxElement = histCoarse.enumerated().max(by: { $0.element < $1.element })!
        let idx = maxElement.offset
        let center = offsetsCoarse[idx]
        let dt = focusInterval / 2
        let dFocus = diffs.filter({ $0 >= center - dt && $0 <= center + dt })
        let (hist, offsets) = try AudioFingerprint.histogram(dFocus, delta: timeResolution)
        let histMax = hist.enumerated().max(by: { $0.element < $1.element })!
        let offset = offsets[histMax.offset]
                
        return Alignment(estimatedTimeOffset: offset)
    }
}
