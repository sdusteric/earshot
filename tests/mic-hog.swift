// Opens the default input with AVAudioEngine for N seconds, then exits.
// Used by the seesAnotherAppOpenTheMic test as EARSHOT_TEST_MIC_HOG.
//
// Compile once (a script run with `swift` starts too slowly for the test's wait):
//   swiftc -O tests/mic-hog.swift -o /tmp/mic-hog
//   EARSHOT_TEST_MIC_HOG=/tmp/mic-hog swift test --package-path app/EarshotKit --filter seesAnotherAppOpenTheMic
import AVFoundation
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 3 : 3
let engine = AVAudioEngine()
let input = engine.inputNode
input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { _, _ in }
engine.prepare()
do {
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("mic-hog: could not start the input: \(error)\n".utf8))
    exit(1)
}
Thread.sleep(forTimeInterval: seconds)
engine.stop()
input.removeTap(onBus: 0)
