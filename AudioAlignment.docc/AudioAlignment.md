#  ``AudioAlignment``

Estimation of audio alignment relative to a given reference, using shift-invariant fingerprints of the spectrum.

## Example Usage

```swift
import AudioAlignment

let sample = try AudioFingerprint(audioURL: URL(fileURLWithPath: "sample.m4a"))
let reference = try AudioFingerprint(audioURL: URL(fileURLWithPath: "reference.m4a"))

let timeOffset = try sample.align(with: reference).estimatedTimeOffset
```

