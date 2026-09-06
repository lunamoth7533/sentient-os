// Isolates the real ingestion/storage code from GPU, UI, telemetry, and live app directories.
import Foundation

nonisolated func Log(_ message: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { String(describing: error) }
nonisolated enum CrashReporting {
    enum Level { case error, warning }
    static func capture(_ error: Error) {}
    static func captureEvent(_ name: String, level: Level, tags: [String: String] = [:],
                             extra: [String: String] = [:], fingerprint: [String] = []) {}
}
enum Analytics { static func signal(_ name: String, parameters: [String: String] = [:]) {} }
enum PipelineActivity { static func begin() {}; static func end() {} }
enum Permissions { static func reportProbe() {} }
enum ModelLocator { static func resolve() -> String? { nil } }
enum LifetimeStats { static func bump(_ verdict: Verdict) {} }
enum SourceHealth {
    static func recordExtraction(succeeded: Bool) {}
    static func checkExtractionRate() {}
}
enum ChatWindowing { static func clampToContext(_ text: String) -> String { text } }
extension URL {
    nonisolated static var sentientSupport: URL {
        guard let path = ProcessInfo.processInfo.environment["SENTIENT_RELIABILITY_SUPPORT"] else {
            fatalError("Tests must explicitly isolate Application Support")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

// Only the costly native inference boundary is replaced. Triage and IterativeRun remain real.
actor Engine {
    struct Result: Sendable { let text: String; let totalTime: TimeInterval }
    enum Failure: Error { case syntheticGeneration }
    let modelPath: String
    init(modelPath: String, maxNumTokens: Int = 4096) { self.modelPath = modelPath }
    func load() async throws {}
    func reload() async throws {}
    func unload() {}
    func generate(prompt: String, imageData: Data?) async throws -> Result {
        if modelPath == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        if prompt.contains("FIXTURE_GENERATION_FAILURE") { throw Failure.syntheticGeneration }
        if prompt.contains("FIXTURE_PARSE_FAILURE") { return Result(text: "malformed response", totalTime: 0) }
        if prompt.contains("FIXTURE_EMPTY_SUMMARY") {
            return Result(text: #"{"summary":"","title":"Incomplete","junk":false}"#, totalTime: 0)
        }
        if prompt.contains("FIXTURE_JUNK") {
            return Result(text: #"{"summary":"Routine chatter","title":"Chatter","junk":true}"#, totalTime: 0)
        }
        if prompt.contains("FIXTURE_SENSITIVE") {
            return Result(text: #"{"summary":"","title":"","junk":false,"sensitive":true}"#, totalTime: 0)
        }
        return Result(text: #"{"summary":"Synthetic project planning","title":"Planning","junk":false}"#, totalTime: 0)
    }
}
