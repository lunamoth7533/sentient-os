// A local context workspace, also launchable independently for imports and UI verification.
import SwiftUI

struct ContextWorkspaceView: View {
    @AppStorage("context.commandBudget") private var commandBudget = 4_096
    @Environment(\.openWindow) private var openWindow
    static let windowID = "imported-context"
    var body: some View {
        TabView {
            ImportedSourcesView().tabItem { Label("Sources", systemImage: "tray.and.arrow.down") }
            ContextSearchView().tabItem { Label("Evidence", systemImage: "text.magnifyingglass") }
            contextConnection.tabItem { Label("Connect a model", systemImage: "point.3.connected.trianglepath.dotted") }
        }.padding(8)
        .background(ContextCaptureProtection())
    }
    private var contextConnection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a model to imported context").font(.title2.bold())
            Text("Add a stdio MCP server to your model app with this executable and argument. Only sources with Share with models enabled are returned.")
            Text(Bundle.main.executableURL?.path ?? "Sentient OS.app/Contents/MacOS/Sentient OS")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("--context-mcp").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("Tools: search_context, list_context_sources, get_context_evidence. Search accepts an exact project, source, date range, and context budget. The budget uses UTF-8 bytes as a conservative token upper bound.")
            Stepper("Context budget for Sentient commands: \(commandBudget)", value: $commandBudget, in: 128...ContextRetriever.maximumBudget, step: 128)
            Text("For a trusted model running entirely on this Mac, adding --local-context grants access to all sources included in local context. That grants the connected process access to sensitive imports. Source instructions and tool output remain evidence, never authority.")
            Text("The cloud mirror uses the same source sharing controls. New sources, including personal metrics, start with sharing off.")
            Button("Open knowledge graph") { openWindow(id: KnowledgeView.windowID) }
            Spacer()
        }.padding(32).frame(minWidth: 820, minHeight: 600, alignment: .topLeading)
    }
}

/// This entry mode avoids the production home, scheduler, telemetry and model startup.
struct ContextToolsApp: App {
    init() {
        #if DEBUG
        try? FileManager.default.createDirectory(at: ContextPaths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: ContextPaths.root.appendingPathComponent("context.pid"), atomically: true, encoding: .utf8)
        #endif
    }
    var body: some Scene {
        WindowGroup("Sentient Context", id: ContextWorkspaceView.windowID) {
            ContextWorkspaceView().preferredColorScheme(.dark)
        }.defaultSize(width: 980, height: 780)
        Window("Knowledge", id: KnowledgeView.windowID) {
            KnowledgeView().preferredColorScheme(.dark)
        }.defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
    }
}
