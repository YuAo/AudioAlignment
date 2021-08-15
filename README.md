# AudioAlignment

![](https://github.com/YuAo/AudioAlignment/workflows/Swift/badge.svg)

Estimation of audio alignment relative to a given reference, using shift-invariant fingerprints of the spectrum.

## Usage

```swift
import AudioAlignment

let sample = try AudioFingerprint(audioURL: URL(fileURLWithPath: "sample.m4a"))
let reference = try AudioFingerprint(audioURL: URL(fileURLWithPath: "reference.m4a"))
let timeOffset = try sample.align(with: reference).estimatedTimeOffset
```

## Swift Package

To use this package in a SwiftPM project, add the following line to the dependencies in your Package.swift file:

```swift
.package(url: "https://github.com/YuAo/AudioAlignment", from: "0.0.1"),
```

## Performance

[Accelerate](https://developer.apple.com/documentation/accelerate/) is used to boost performance.

Audio fingerprint generation is approximatelly 60ms per minute audio on a 2019 Intel iMac with i5 processor (in release mode). 

## Acknowledgements

### Audio_Snippets_Alignment

[ranwsn/Audio_Snippets_Alignment](https://github.com/ranwsn/Audio_Snippets_Alignment)

### Example Audio

Endless Light

by Siddhartha Corsus

https://creativecommons.org/licenses/by-nc/4.0/
