import Foundation

/// Notes each time the app's main thread was held up for longer than a
/// frame (#21), when it is asked to with `AGENTTERM_MEASURE_MAIN=<file>`:
/// for measuring, by `scripts/test-mac.sh` with `MEASURE=1`. Without the
/// variable nothing runs.
///
/// A thread of its own asks the main thread to answer, again and again,
/// and times each answer: one that takes longer than 16 ms, a frame at 60
/// Hz, is a moment the window did not answer the user either. Each is
/// written as a line, when it was noticed and how long it took.
enum MainThreadWatch {
    static let variable = "AGENTTERM_MEASURE_MAIN"
    /// A frame at 60 Hz, in milliseconds.
    static let frame = 16.0

    static func startIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[variable], !path.isEmpty else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: path) else { return }
        let thread = Thread {
            let answered = DispatchSemaphore(value: 0)
            while true {
                let asked = DispatchTime.now()
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let took = Double(DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1_000_000
                if took > frame {
                    file.seekToEndOfFile()
                    file.write(Data(String(format: "%.3f %.1f\n", Date().timeIntervalSince1970, took).utf8))
                }
                usleep(2000)
            }
        }
        thread.name = "agentterm.main-thread-watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
