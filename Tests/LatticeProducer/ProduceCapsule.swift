// Synthetic input for Lattice's actual Workbench exporter; producer/codec logic is not duplicated.
import Foundation

@main struct ProduceCapsule {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "LatticeProducerTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supply the temporary output JSON path."])
        }
        let instant = ISO8601DateFormatter().date(from: "2026-09-06T15:00:00Z")!
        let project = ProjectLens(id: "native-roundtrip", name: "Synthetic Producer Roundtrip", aliases: ["synthetic"])
        let other = ProjectLens(id: "unrelated-project", name: "Synthetic Unrelated Project")
        let archive = RDWorkspaceArchive(
            projects: [project, other],
            contexts: [ProjectContext(id: "context", projectID: project.id, generatedAt: instant,
                provider: .human, goal: "Verify a native Workbench capsule with synthetic records.")],
            events: [
                WorkEventRecord(id: "decision", projectID: project.id, threadID: "native-session",
                    occurredAt: instant, kind: .decision, status: .informational, source: "Synthetic harness",
                    title: "Orchidproof decision", summary: "Decision: preserve the synthetic cobalt records after restart.",
                    evidence: ["synthetic:decision-proof"], metadata: ["fixture": "synthetic"]),
                WorkEventRecord(id: "failed-check", projectID: project.id, threadID: "native-session",
                    occurredAt: instant, kind: .test, status: .failed, source: "Synthetic harness",
                    title: "Orchidfailure check", summary: "A synthetic check failed; completion remains unverified."),
                WorkEventRecord(id: "unrelated", projectID: other.id, occurredAt: instant,
                    kind: .decision, source: "Synthetic harness", title: "Unrelated fixture",
                    summary: "UNRELATED_PROJECT_SENTINEL must stay outside the selected export.")
            ],
            releases: [ReleaseReceipt(id: "release", projectID: project.id, version: "0.0", build: "synthetic-1",
                commitSHA: String(repeating: "0", count: 40), occurredAt: instant, processingStatus: "not submitted",
                source: "Synthetic harness", ciStatus: "failed", localTestSummary: "One synthetic failure remains open.",
                blockers: ["Synthetic blocker"], openLoops: ["Verify recovery with synthetic fixtures."])]
        )
        // RDWorkspaceStore.exportCapsule and ContextCapsuleDocument.init invoke these same APIs.
        let capsule = try AgentContextExporter.capsule(archive: archive, projectID: project.id,
                                                       generatedAt: instant.addingTimeInterval(300))
        let data = try ContextCapsuleCodec.encode(capsule)
        let decoded = try ContextCapsuleCodec.decode(data)
        guard decoded.provider == .lattice, decoded.events.count == 2, decoded.releases.count == 1,
              decoded.events.allSatisfy({ $0.projectID == project.id }),
              !String(decoding: data, as: UTF8.self).contains("UNRELATED_PROJECT_SENTINEL") else {
            throw NSError(domain: "LatticeProducerTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native producer failed synthetic source isolation checks."])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("PASS native producer: capsule v1, two events, one release, unrelated project excluded")
    }
}
