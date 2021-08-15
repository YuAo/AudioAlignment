//
//  File.swift
//  
//
//  Created by YuAo on 2021/8/15.
//

import Foundation
import AudioAlignment
import Fixtures

let reference = try AudioFingerprint(audioURL: Fixtures.referenceAudioURL)
let sample = try AudioFingerprint(audioURL: Fixtures.sampleAudioURL)
let alignment = try sample.align(with: reference)
print(alignment)
