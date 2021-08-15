import XCTest
import AVFoundation
import AudioAlignment
import Fixtures

final class AudioAlignmentTests: XCTestCase {
    
    func testAlignment() throws {
        let sample = try AudioFingerprint(audioURL: Fixtures.sampleAudioURL)
        let reference = try AudioFingerprint(audioURL: Fixtures.referenceAudioURL)
        let offset = try sample.align(with: reference).estimatedTimeOffset
        print(offset)
        XCTAssert(offset >= 10.0 - sample.configuration.finestTimeResolution && offset <= 10.0 + sample.configuration.finestTimeResolution)
    }
    
    func testSelfAlignment() throws {
        let sample = try AudioFingerprint(audioURL: Fixtures.sampleAudioURL)
        let offset = try sample.align(with: sample).estimatedTimeOffset
        XCTAssert(offset == 0)
    }
}
