// Read-only adapters for locally verified transcript formats. Native evidence remains attributed;
// rendered projections and wire representations are never treated as separate conversations.
import Foundation
import SQLite3
import CryptoKit

nonisolated enum SessionAdapters {
    static func parse(url: URL, source: ImportSource) throws -> [ImportDocument] {
        var documents = try parseNative(url: url, source: source)
        for index in documents.indices {
            try Task.checkCancellation()
            documents[index].records = try resolvedRecordLinks(documents[index].records)
        }
        return documents
    }

    private static func parseNative(url: URL, source: ImportSource) throws -> [ImportDocument] {
        try Task.checkCancellation()
        if ["db", "sqlite", "sqlite3"].contains(url.pathExtension.lowercased()) {
            let db = try SessionSQLite(url: url)
            switch source.kind {
            case .hermes: return try hermesDatabase(db, url: url, source: source)
            case .openClaw: return try clawDatabase(db, url: url, source: source)
            case .codex: return try codexDatabase(db, url: url, source: source)
            default: throw ContextError.invalid("This source does not use a supported session database.")
            }
        }
        if url.pathExtension.lowercased() == "json" {
            let data = try StructuredInput.readData(at: url)
            let value = try JSONSerialization.jsonObject(with: data)
            if source.kind == .hermes {
                let objects = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
                return hermesExports(objects.enumerated().map { JSONLine(number: $0.offset + 1, object: $0.element) }, complete: true, issues: [], url: url, source: source)
            }
            if source.kind == .openClaw, let object = value as? [String: Any],
               let header = object["header"] as? [String: Any], let entries = object["entries"] as? [[String: Any]] {
                return [clawEvents(([header] + entries).enumerated().map { JSONLine(number: $0.offset + 1, object: $0.element) }, url: url, source: source, leafID: string(object["leafId"]))]
            }
            return unsupported(url, "Choose a native transcript or a supported session export.")
        }
        let input = try StructuredInput.jsonLines(at: url)
        switch source.kind {
        case .codex: return [codexLines(input, url: url, source: source)]
        case .claudeCode: return claudeLines(input, url: url, source: source)
        case .openClaw:
            var doc = clawEvents(input.lines, url: url, source: source)
            doc.complete = doc.complete && input.complete; doc.issues += input.issues
            return [doc]
        case .hermes: return hermesExports(input.lines, complete: input.complete, issues: input.issues, url: url, source: source)
        default: throw ContextError.invalid("Choose the adapter matching this session source.")
        }
    }

    private struct Attribution {
        var session: String
        var project: String?
        var timestamp: String?
        var provider: String?
        var model: String?
        var application: String
        var attributes: [String: String] = [:]
        var links: [EvidenceLink] = []

        mutating func metadata(_ value: [String: Any]) {
            project = string(value["cwd"]) ?? project
            model = string(value["model"]) ?? string(value["modelId"]) ?? model
            provider = string(value["model_provider"]) ?? string(value["modelProvider"]) ?? string(value["provider"]) ?? provider
            application = string(value["originator"]) ?? string(value["application"]) ?? application
            for field in ["originator", "source", "cli_version", "version", "history_mode", "agent_path", "agent_nickname", "git_branch", "gitBranch", "profile_name", "sessionKey"] {
                if let value = string(value[field]) { attributes[field] = value }
            }
            if let git = value["git"] as? [String: Any], let branch = string(git["branch"]) { attributes["git_branch"] = branch }
            for (key, relation) in [("parent_thread_id", "parent_session"), ("parent_session_id", "parent_session"), ("parent_session_key", "parent_session"), ("previous_session_id", "previous_session"), ("forked_from_id", "forked_from"), ("fork_source_session_id", "forked_from")] {
                if let target = string(value[key]), !links.contains(where: { $0.relation == relation && $0.target == target }) {
                    links.append(EvidenceLink(relation: relation, target: target))
                }
            }
            if let nested = value["source"] as? [String: Any], let agent = nested["subagent"] as? [String: Any], let spawn = agent["spawn"] as? [String: Any] {
                metadata(spawn)
            }
            let origin = string(value["origin"]) ?? application
            let parts = (project ?? "").split(separator: "/").map(String.init)
            if ["sentient", "sentient-os", "sentient os", "sentientos"].contains(origin.lowercased()) || parts.contains(where: { $0.hasPrefix(".sentientos-vault-staging-") || $0 == "sentient-proactive-judge" || $0 == "Sentient OS - Knowledge Base" }) {
                attributes["origin"] = "sentient"
            }
        }

        func record(_ native: String, text: String, role: EvidenceRole, kind: String = "message", locator: String,
                    extra: [String: String] = [:], links additional: [EvidenceLink] = [], sensitive: Bool = false) -> EvidenceRecord {
            EvidenceRecord(id: session + ":" + native, text: text, role: role, kind: kind, sessionID: session,
                project: project, timestamp: timestamp, provider: provider, model: model, application: application,
                locator: locator, attributes: attributes.merging(["native_record_id": native], uniquingKeysWith: { _, new in new })
                    .merging(extra, uniquingKeysWith: { _, new in new }), links: links + additional, sensitive: sensitive)
        }
    }

    private static func codexLines(_ input: JSONLines, url: URL, source: ImportSource) -> ImportDocument {
        guard let metadata = input.lines.first(where: { string($0.object["type"]) == "session_meta" })?.object["payload"] as? [String: Any],
              let session = string(metadata["id"]) ?? string(metadata["session_id"]) else {
            return unsupported(url, "No Codex session metadata was found. Prompt history and usage indexes are not transcripts.").first!
        }
        var context = Attribution(session: session, project: source.project, application: "Codex")
        context.metadata(metadata)
        var records: [(EvidenceRecord, Bool)] = []
        var issues = input.issues
        var turn = "initial"
        var projectedCalls = Set<String>()
        for line in input.lines {
            let object = line.object
            guard let payload = object["payload"] as? [String: Any] else { continue }
            context.timestamp = timestamp(object["timestamp"])
            let locator = "\(url.path)#L\(line.number)"
            let outer = string(object["type"]) ?? ""
            if outer == "turn_context" { context.metadata(payload); turn = string(payload["turn_id"]) ?? turn; continue }
            if outer == "session_meta" { continue }
            if outer == "event_msg", let newTurn = string(payload["turn_id"]) { turn = newTurn }
            context.attributes["turn_id"] = turn
            let fallback = "ordinal-" + (string(object["ordinal"]) ?? String(line.number))
            if outer == "compacted" {
                let text = string(payload["message"]) ?? visibleText(payload["summary"])
                if !text.isEmpty { records.append((context.record(fallback, text: text, role: .summary, kind: "compaction", locator: locator), false)) }
            } else if outer == "event_msg", string(payload["type"]) == "item_completed", let item = payload["item"] as? [String: Any] {
                if !supportedCodexItem(item) { addIssue(&issues, "Some Codex history item types are not supported; accepted records remain available.", line: line.number) }
                let result = codexItem(item, context: context, fallback: fallback, locator: locator)
                for record in result {
                    if record.kind == "tool_call", let id = record.attributes["call_id"] { projectedCalls.insert(id) }
                    records.append((record, true))
                }
            } else if outer == "response_item" {
                let type = string(payload["type"]) ?? ""
                let native = string(payload["id"]) ?? fallback
                switch type {
                case "message":
                    let role = evidenceRole(string(payload["role"]))
                    let text = visibleText(payload["content"])
                    if !text.isEmpty {
                        records.append((context.record(native, text: text, role: role, locator: locator,
                            extra: ["phase": string(payload["channel"]) ?? string(payload["phase"]) ?? ""]), false))
                    }
                case "function_call", "custom_tool_call":
                    let callID = string(payload["call_id"]) ?? native
                    records.append((context.record("tool-call:" + callID,
                        text: toolText(name: string(payload["name"]), arguments: payload["arguments"] ?? payload["input"]), role: .assistant,
                        kind: "tool_call", locator: locator, extra: ["call_id": callID]), false))
                case "function_call_output", "custom_tool_call_output":
                    let callID = string(payload["call_id"]) ?? native
                    let text = visibleText(payload["output"])
                    if !text.isEmpty { records.append((context.record("tool-result:" + callID, text: text, role: .tool, kind: "tool_result", locator: locator,
                        extra: ["call_id": callID], links: [EvidenceLink(relation: "tool_call", target: callID)]), false)) }
                case "reasoning":
                    let text = visibleText(payload["summary"])
                    if !text.isEmpty { records.append((context.record(native, text: text, role: .assistant, kind: "reasoning", locator: locator, sensitive: true), false)) }
                case "agent_message":
                    // Inter-agent envelopes are not statements by the human user.
                    let text = visibleText(payload["content"])
                    if !text.isEmpty { records.append((context.record(native, text: text, role: .assistant, kind: "agent_message", locator: locator), false)) }
                case "web_search_call", "local_shell_call", "image_generation_call", "computer_call":
                    records.append((context.record(native, text: "Recorded \(type)", role: .assistant, kind: "tool_call", locator: locator), false))
                default:
                    if !type.isEmpty { addIssue(&issues, "Some Codex response item types are not supported; accepted records remain available.", line: line.number) }
                }
            } else if outer == "event_msg", ["user_message", "agent_message", "agent_reasoning"].contains(string(payload["type"]) ?? "") {
                let type = string(payload["type"]) ?? ""
                let text = string(payload["message"]) ?? string(payload["text"]) ?? ""
                if !text.isEmpty { records.append((context.record(fallback, text: text, role: type == "user_message" ? .user : .assistant,
                    kind: type == "agent_reasoning" ? "reasoning" : "message", locator: locator, extra: ["legacy_event": "true"]), false)) }
            }
        }
        // Projected item completions have stable identities. Legacy event messages also mirror Responses
        // messages, but repeated human text in different turns must survive.
        let projectedSignatures = Set(records.filter(\.1).map { signature($0.0) })
        let rawSignatures = Set(records.filter { !$0.1 && $0.0.attributes["legacy_event"] == nil }.map { signature($0.0) })
        let accepted = records.compactMap { record, projected -> EvidenceRecord? in
            if !projected {
                if projectedSignatures.contains(signature(record)) { return nil }
                if record.attributes["legacy_event"] != nil && rawSignatures.contains(signature(record)) { return nil }
                if let callID = record.attributes["call_id"], projectedCalls.contains(callID) { return nil }
            }
            return record
        }
        return ImportDocument(id: session, records: unique(accepted), complete: input.complete && issues.isEmpty, issues: issues)
    }

    private static func codexItem(_ item: [String: Any], context: Attribution, fallback: String, locator: String) -> [EvidenceRecord] {
        let type = string(item["type"]) ?? ""
        let native = string(item["id"]) ?? fallback
        switch type.lowercased() {
        case "usermessage", "agentmessage":
            let text = string(item["text"]) ?? visibleText(item["content"])
            return text.isEmpty ? [] : [context.record(native, text: text, role: type.lowercased() == "usermessage" ? .user : .assistant, locator: locator,
                extra: ["phase": string(item["phase"]) ?? ""])]
        case "reasoning":
            let text = [visibleText(item["summary"] ?? item["summary_text"]), visibleText(item["raw_content"] ?? item["content"])].filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? [] : [context.record(native, text: text, role: .assistant, kind: "reasoning", locator: locator, sensitive: true)]
        case "commandexecution", "mcptoolcall", "dynamictoolcall":
            let name = string(item["tool"]) ?? string(item["name"]) ?? (type.lowercased() == "commandexecution" ? "command" : type)
            var result = [context.record("tool-call:" + native, text: toolText(name: name, arguments: item["arguments"] ?? item["command"]),
                role: .assistant, kind: "tool_call", locator: locator, extra: ["call_id": native, "status": string(item["status"]) ?? ""])]
            let output = visibleText(item["aggregatedOutput"] ?? item["aggregated_output"] ?? item["result"] ?? item["contentItems"])
            if !output.isEmpty { result.append(context.record("tool-result:" + native, text: output, role: .tool, kind: "tool_result", locator: locator,
                extra: ["call_id": native, "exit_code": string(item["exitCode"] ?? item["exit_code"]) ?? ""], links: [EvidenceLink(relation: "tool_call", target: native)])) }
            return result
        case "contextcompaction":
            let summary = visibleText(item["summary"])
            return [context.record(native, text: summary.isEmpty ? "Source recorded context compaction." : summary, role: .boundary, kind: "compaction", locator: locator)]
        case "filechange":
            return [context.record(native, text: jsonText(item["changes"]), role: .tool, kind: "file_change", locator: locator,
                extra: ["status": string(item["status"]) ?? ""])]
        case "subagentactivity":
            let target = string(item["agentThreadId"] ?? item["agent_thread_id"])
            return [context.record(native, text: "Source recorded subagent activity.", role: .boundary, kind: "subagent", locator: locator,
                links: target.map { [EvidenceLink(relation: "child_session", target: $0)] } ?? [])]
        case "websearch", "extension":
            guard type.lowercased() != "extension" || (string(item["kind"]) ?? "").contains("web") else { return [] }
            let details = ["query": item["query"] ?? "", "action": item["action"] ?? [:], "results": item["results"] ?? []] as [String: Any]
            return [context.record(native, text: jsonText(details), role: .tool, kind: "web_search", locator: locator)]
        case "collabagenttoolcall":
            let targets = (item["receiverThreadIds"] as? [String] ?? []).map { EvidenceLink(relation: "child_session", target: $0) }
            var result = [context.record("tool-call:" + native, text: toolText(name: string(item["tool"]), arguments: item["prompt"]), role: .assistant,
                kind: "tool_call", locator: locator, extra: ["call_id": native, "status": string(item["status"]) ?? ""], links: targets)]
            if let states = item["agentsStates"] as? [String: Any], !states.isEmpty {
                result.append(context.record("tool-result:" + native, text: jsonText(states), role: .tool, kind: "tool_result", locator: locator,
                    links: [EvidenceLink(relation: "tool_call", target: native)] + targets))
            }
            return result
        case "imageview":
            return [context.record(native, text: "Source viewed an image attachment.", role: .tool, kind: "attachment", locator: locator, sensitive: true)]
        case "enteredreviewmode", "exitedreviewmode":
            return [context.record(native, text: string(item["review"]) ?? "Source recorded a review-mode boundary.", role: .boundary, kind: "review", locator: locator)]
        case "sleep": return []
        default: return []
        }
    }

    private static func supportedCodexItem(_ item: [String: Any]) -> Bool {
        let type = (string(item["type"]) ?? "").lowercased()
        if type == "extension" { return (string(item["kind"]) ?? "").contains("web") }
        return ["usermessage", "agentmessage", "reasoning", "commandexecution", "mcptoolcall", "dynamictoolcall", "contextcompaction", "filechange", "subagentactivity", "websearch", "collabagenttoolcall", "imageview", "enteredreviewmode", "exitedreviewmode", "sleep"].contains(type)
    }

    private static func claudeLines(_ input: JSONLines, url: URL, source: ImportSource) -> [ImportDocument] {
        var contexts: [String: Attribution] = [:]
        var records: [String: [EvidenceRecord]] = [:]
        var issues = input.issues
        for line in input.lines {
            let object = line.object
            guard let session = string(object["sessionId"]) ?? string(object["session_id"]) else { continue }
            var context = contexts[session] ?? Attribution(session: session, project: source.project, application: "Claude Code")
            context.metadata(object); context.timestamp = timestamp(object["timestamp"])
            let type = string(object["type"]) ?? ""
            let native = string(object["uuid"]) ?? "line-\(line.number)"
            let locator = "\(url.path)#L\(line.number)"
            var links: [EvidenceLink] = []
            if let parent = string(object["parentUuid"]) { links.append(EvidenceLink(relation: "parent_record", target: session + ":" + parent)) }
            if bool(object["isSidechain"]) { context.attributes["sidechain"] = "true" }
            if let agent = string(object["agentId"]) { context.attributes["agent_id"] = agent }
            if ["user", "assistant"].contains(type) {
                guard let message = object["message"] as? [String: Any] else {
                    addIssue(&issues, "A Claude message is incomplete.", line: line.number); continue
                }
                context.metadata(message)
                let role: EvidenceRole = bool(object["isMeta"]) ? .instruction : evidenceRole(string(message["role"]) ?? type)
                let newRecords = contentRecords(message["content"], native: native, context: context, role: role, locator: locator, links: links)
                records[session, default: []] += newRecords
            } else if type == "system", string(object["subtype"]) == "compact_boundary" {
                records[session, default: []].append(context.record(native, text: "Source recorded a context compaction boundary.", role: .boundary,
                    kind: "compaction", locator: locator, links: links))
            } else if type == "summary", let summary = string(object["summary"]) {
                records[session, default: []].append(context.record(native, text: summary, role: .summary, kind: "compaction", locator: locator, links: links))
            }
            contexts[session] = context
        }
        if contexts.isEmpty { return unsupported(url, "No Claude Code transcript entries were found. Prompt recall and UI metadata are not transcripts.") }
        return contexts.keys.sorted().map { ImportDocument(id: $0, records: unique(records[$0] ?? []), complete: input.complete && issues.isEmpty, issues: issues) }
    }

    private static func contentRecords(_ content: Any?, native: String, context: Attribution, role: EvidenceRole, locator: String,
                                       links: [EvidenceLink] = []) -> [EvidenceRecord] {
        guard let blocks = content as? [[String: Any]] else {
            let text = visibleText(content)
            return text.isEmpty ? [] : [context.record(native, text: text, role: role, locator: locator, links: links)]
        }
        var records: [EvidenceRecord] = []
        for (index, block) in blocks.enumerated() {
            let id = blocks.count == 1 ? native : native + ":part-\(index)"
            let type = string(block["type"]) ?? ""
            switch type {
            case "tool_use", "toolCall":
                let call = string(block["id"]) ?? id
                records.append(context.record(id, text: toolText(name: string(block["name"]), arguments: block["arguments"] ?? block["input"]), role: .assistant,
                    kind: "tool_call", locator: locator, extra: ["call_id": call, "tool_name": string(block["name"]) ?? ""], links: links))
            case "tool_result", "toolResult":
                let call = string(block["tool_use_id"] ?? block["toolCallId"] ?? block["toolUseId"])
                let text = visibleText(block["text"] ?? block["content"])
                var extra: [String: String] = [:]
                extra["call_id"] = call
                extra["is_error"] = errorFlag(block["is_error"] ?? block["isError"])
                if !text.isEmpty { records.append(context.record(id, text: text, role: .tool, kind: "tool_result", locator: locator,
                    extra: extra,
                    links: links + (call.map { [EvidenceLink(relation: "tool_call", target: $0)] } ?? []))) }
            case "thinking", "reasoning":
                let text = visibleText(block["thinking"] ?? block["text"])
                if !text.isEmpty { records.append(context.record(id, text: text, role: .assistant, kind: "reasoning", locator: locator, links: links, sensitive: true)) }
            case "text", "input_text", "output_text", "summary_text":
                let text = visibleText(block["text"])
                if !text.isEmpty { records.append(context.record(id, text: text, role: role, locator: locator, links: links)) }
            case "image", "input_image", "image_url", "audio", "input_audio", "document":
                records.append(context.record(id, text: "Source contains a \(type) attachment; its binary contents were not imported.", role: role,
                    kind: "attachment", locator: locator, links: links, sensitive: true))
            default: break // Opaque signatures and encrypted blocks are not text.
            }
        }
        for index in records.indices { records[index].attributes["native_record_id"] = native }
        return records
    }

    private static func hermesDatabase(_ db: SessionSQLite, url: URL, source: ImportSource) throws -> [ImportDocument] {
        try db.require("sessions", columns: ["id", "source"])
        try db.require("messages", columns: ["id", "session_id", "role", "content"])
        let sessions = try db.rows("SELECT * FROM sessions ORDER BY id")
        let rows = try db.rows("SELECT * FROM messages ORDER BY id")
        let grouped = Dictionary(grouping: rows, by: { string($0["session_id"]) ?? "" })
        return sessions.compactMap { session in
            guard let id = string(session["id"]) else { return nil }
            return hermesSession(session, rows: grouped[id] ?? [], url: url, source: source, locatorPrefix: "\(url.path)#messages/")
        }
    }

    private static func hermesSession(_ session: [String: Any], rows: [[String: Any]], url: URL, source: ImportSource, locatorPrefix: String) -> ImportDocument {
        let id = string(session["id"]) ?? string(session["session_id"]) ?? "unknown"
        var context = Attribution(session: id, project: source.project, application: "Hermes")
        context.metadata(session)
        if let config = object(session["model_config"]) {
            context.metadata(config)
            for (key, relation) in [("_branched_from", "forked_from"), ("_delegate_from", "delegated_from"), ("_reset_from", "reset_from")] {
                if let target = string(config[key]) { context.links.append(EvidenceLink(relation: relation, target: target)) }
            }
        }
        // Exactly the installed Hermes display key. Copies retain their original timestamp; two
        // distinct calls with identical text remain distinct because call fields participate.
        var display: [String: (Int, [String: Any])] = [:]
        var issues: [ImportIssue] = []
        for (index, row) in rows.enumerated() {
            let active = row["active"] == nil || bool(row["active"])
            if !active && !bool(row["compacted"]) { continue }
            let parts = [row["role"], row["content"], row["timestamp"], row["tool_call_id"], row["tool_calls"], row["tool_name"]]
            let key = EvidenceIdentity.digest(jsonText(parts.map { $0 ?? NSNull() }))
            if let old = display[key], bool(old.1["active"]) && !active { continue }
            display[key] = (index, row)
        }
        var records: [EvidenceRecord] = []
        for (index, row) in display.values.sorted(by: { $0.0 < $1.0 }) {
            guard let rawRole = string(row["role"]) else { addIssue(&issues, "A Hermes message has no role."); continue }
            if rawRole == "session_meta" { continue }
            let native = string(row["id"]) ?? "export-\(index)"
            let locator = locatorPrefix + native
            context.timestamp = timestamp(row["timestamp"], unit: .seconds)
            let summary = bool(row["_compressed_summary"])
            let role = summary ? EvidenceRole.summary : evidenceRole(rawRole)
            let content = hermesContent(row["content"])
            var links: [EvidenceLink] = []
            if let call = string(row["tool_call_id"]) { links.append(EvidenceLink(relation: "tool_call", target: call)) }
            var result = contentRecords(content, native: native, context: context, role: role, locator: locator, links: links)
            if rawRole == "tool" { for i in result.indices { result[i].kind = "tool_result" } }
            if summary { for i in result.indices { result[i].role = .summary; result[i].kind = "compaction" } }
            records += result
            if let calls = array(row["tool_calls"]) {
                for (callIndex, call) in calls.enumerated() {
                    let function = call["function"] as? [String: Any] ?? call
                    let callID = string(call["id"]) ?? "\(native)-\(callIndex)"
                    records.append(context.record(native + ":call:" + callID, text: toolText(name: string(function["name"]), arguments: function["arguments"]),
                        role: .assistant, kind: "tool_call", locator: locator, extra: ["call_id": callID]))
                }
            }
            let reasoning = string(row["reasoning_content"]) ?? string(row["reasoning"]) ?? ""
            if !reasoning.isEmpty { records.append(context.record(native + ":reasoning", text: reasoning, role: .assistant, kind: "reasoning", locator: locator, sensitive: true)) }
        }
        return ImportDocument(id: id, records: unique(records), complete: issues.isEmpty, issues: issues)
    }

    private static func hermesExports(_ lines: [JSONLine], complete: Bool, issues: [ImportIssue], url: URL, source: ImportSource) -> [ImportDocument] {
        var docs: [ImportDocument] = []
        var problems = issues
        for line in lines {
            guard string(line.object["id"]) ?? string(line.object["session_id"]) != nil,
                  let messages = line.object["messages"] as? [[String: Any]] else {
                addIssue(&problems, "This is not a Hermes full-session export. Use state.db or an unfiltered sessions export.", line: line.number); continue
            }
            var doc = hermesSession(line.object, rows: messages, url: url, source: source, locatorPrefix: "\(url.path)#L\(line.number)/messages/")
            doc.complete = complete && doc.complete; docs.append(doc)
        }
        if docs.isEmpty { return unsupported(url, "No full Hermes sessions were found. Routing indexes and prompt-only exports are not transcripts.") }
        if !problems.isEmpty { for i in docs.indices { docs[i].complete = false; docs[i].issues += problems } }
        return docs
    }

    private static func clawDatabase(_ db: SessionSQLite, url: URL, source: ImportSource) throws -> [ImportDocument] {
        try db.require("transcript_events", columns: ["session_id", "seq", "event_json"])
        var metadata: [String: [String: Any]] = [:]
        if db.hasTable("session_windows") {
            for row in try db.rows("SELECT * FROM session_windows") { if let id = string(row["session_id"]) { metadata[id] = row } }
        }
        if db.hasTable("session_nodes") {
            for row in try db.rows("SELECT * FROM session_nodes") {
                if let id = string(row["current_session_id"]) {
                    var value = object(row["entry_json"]) ?? [:]
                    value["sessionKey"] = row["session_key"]
                    metadata[id] = (metadata[id] ?? [:]).merging(value, uniquingKeysWith: { _, new in new })
                }
            }
        }
        var leafs: [String: String] = [:]
        var dirtyIndexes = Set<String>()
        if db.hasTable("session_transcript_index_state") {
            for row in try db.rows("SELECT * FROM session_transcript_index_state") {
                if let id = string(row["session_id"]), bool(row["needs_rebuild"]) { dirtyIndexes.insert(id); continue }
                if let id = string(row["session_id"]), let leaf = string(row["leaf_event_id"]) { leafs[id] = leaf }
            }
        }
        let groups = Dictionary(grouping: try db.rows("SELECT session_id,seq,event_json FROM transcript_events ORDER BY session_id,seq"), by: { string($0["session_id"]) ?? "" })
        return groups.keys.sorted().map { id in
            if dirtyIndexes.contains(id) {
                return ImportDocument(id: id, records: [], complete: false, issues: [ImportIssue("OpenClaw is rebuilding this transcript's branch index. Retry after the source finishes saving.")])
            }
            var lines: [JSONLine] = []
            var issues: [ImportIssue] = []
            for row in groups[id] ?? [] {
                guard let event = object(row["event_json"]), let sequence = Int(string(row["seq"]) ?? "") else {
                    addIssue(&issues, "An OpenClaw transcript row is malformed; later rows were not accepted."); break
                }
                lines.append(JSONLine(number: sequence, object: event))
            }
            var doc = clawEvents(lines, url: url, source: source, sessionID: id, metadata: metadata[id] ?? [:], leafID: leafs[id], sqlite: true)
            doc.issues += issues; doc.complete = doc.complete && issues.isEmpty
            return doc
        }
    }

    private static func clawEvents(_ lines: [JSONLine], url: URL, source: ImportSource, sessionID: String? = nil,
                                   metadata: [String: Any] = [:], leafID: String? = nil, sqlite: Bool = false) -> ImportDocument {
        let header = lines.first(where: { string($0.object["type"]) == "session" })?.object
        guard let id = sessionID ?? string(header?["id"]) else {
            return unsupported(url, "No OpenClaw session header was found. Select the native agent database or session-branch.json, not trajectory event mirrors.").first!
        }
        var context = Attribution(session: id, project: source.project, application: "OpenClaw")
        context.metadata(metadata); context.metadata(header ?? [:])
        var records: [EvidenceRecord] = []
        var issues: [ImportIssue] = []
        // The branch graph is authoritative when an explicit current leaf is supplied by SQLite/export.
        var parents: [String: String] = [:]
        for line in lines { if let native = string(line.object["id"]), let parent = string(line.object["parentId"]) { parents[native] = parent } }
        var active = Set<String>()
        var cursor = leafID
        while let current = cursor, !active.contains(current) { active.insert(current); cursor = parents[current] }
        for line in lines {
            let event = line.object
            let type = string(event["type"]) ?? ""
            if type == "session" { continue }
            guard let native = string(event["id"]) else { addIssue(&issues, "An OpenClaw event is missing its native identity.", line: line.number); continue }
            let locator = sqlite ? "\(url.path)#transcript_events/\(id)/\(line.number)" : "\(url.path)#L\(line.number)"
            context.timestamp = timestamp(event["timestamp"])
            var links: [EvidenceLink] = []
            if let parent = string(event["parentId"]) { links.append(EvidenceLink(relation: "parent_record", target: id + ":" + parent)) }
            var result: [EvidenceRecord] = []
            switch type {
            case "message":
                guard let message = event["message"] as? [String: Any], let rawRole = string(message["role"]) else {
                    addIssue(&issues, "An OpenClaw message is incomplete.", line: line.number); continue
                }
                context.metadata(message)
                context.timestamp = context.timestamp ?? timestamp(message["timestamp"], unit: .milliseconds)
                if let call = string(message["toolCallId"]) { links.append(EvidenceLink(relation: "tool_call", target: call)) }
                result = contentRecords(message["content"], native: native, context: context, role: evidenceRole(rawRole), locator: locator, links: links)
                if rawRole == "toolResult" {
                    for i in result.indices {
                        result[i].role = .tool; result[i].kind = "tool_result"
                        if let flag = errorFlag(message["isError"]) { result[i].attributes["is_error"] = flag }
                        if let name = string(message["toolName"]) { result[i].attributes["tool_name"] = name }
                        if let call = string(message["toolCallId"]) { result[i].attributes["call_id"] = call }
                    }
                }
            case "model_change":
                context.metadata(event)
                result = [context.record(native, text: "Source changed its model to \(context.model ?? "an unspecified model").", role: .boundary, kind: "model_change", locator: locator, links: links)]
            case "compaction", "branch_summary":
                let text = string(event["summary"]) ?? "Source recorded context compaction."
                result = [context.record(native, text: text, role: .summary, kind: type, locator: locator,
                    extra: ["first_kept_entry_id": string(event["firstKeptEntryId"]) ?? ""], links: links)]
            case "custom_message":
                result = contentRecords(event["content"], native: native, context: context, role: .instruction, locator: locator, links: links)
            case "thinking_level_change", "session_info", "label", "custom": break
            default: addIssue(&issues, "Some OpenClaw event types are not supported; accepted records remain available.", line: line.number)
            }
            if leafID != nil && !active.contains(native) {
                for i in result.indices { result[i].attributes["branch_state"] = "inactive"; result[i].deleted = true }
            }
            records += result
        }
        return ImportDocument(id: id, records: unique(records), complete: issues.isEmpty, issues: issues)
    }

    private static func codexDatabase(_ db: SessionSQLite, url: URL, source: ImportSource) throws -> [ImportDocument] {
        try db.require("thread_items", columns: ["thread_id", "turn_id", "item_id", "item_json", "rollout_ordinal"])
        let groups = Dictionary(grouping: try db.rows("SELECT * FROM thread_items ORDER BY thread_id,rollout_ordinal"), by: { string($0["thread_id"]) ?? "" })
        return groups.keys.sorted().map { id in
            var context = Attribution(session: id, project: source.project, application: "Codex")
            var records: [EvidenceRecord] = []
            var issues: [ImportIssue] = []
            for row in groups[id] ?? [] {
                guard let item = object(row["item_json"]), let native = string(row["item_id"]) else {
                    addIssue(&issues, "A Codex projected history item is malformed."); break
                }
                let turn = string(row["turn_id"]) ?? ""
                if !supportedCodexItem(item) { addIssue(&issues, "Some Codex history item types are not supported; accepted records remain available.") }
                context.attributes["turn_id"] = turn
                context.timestamp = timestamp(row["created_at_ms"], unit: .milliseconds)
                records += codexItem(item, context: context, fallback: native, locator: "\(url.path)#thread_items/\(id)/\(turn)/\(native)")
            }
            return ImportDocument(id: id, records: unique(records), complete: issues.isEmpty, issues: issues)
        }
    }

    private static func unsupported(_ url: URL, _ message: String) -> [ImportDocument] {
        [ImportDocument(id: "unrecognized:" + EvidenceIdentity.digest(url.path), records: [], complete: false, issues: [ImportIssue(message)])]
    }
    private static func addIssue(_ issues: inout [ImportIssue], _ message: String, line: Int? = nil) {
        if !issues.contains(where: { $0.message == message }) { issues.append(ImportIssue(message, line: line)) }
    }
    private static func unique(_ records: [EvidenceRecord]) -> [EvidenceRecord] {
        var positions: [String: Int] = [:]
        var result: [EvidenceRecord] = []
        for record in records {
            if let i = positions[record.id] { result[i] = record }
            else { positions[record.id] = result.count; result.append(record) }
        }
        return result
    }

    /// Native tool IDs and message-envelope IDs are not always evidence IDs: a message may
    /// contain several content blocks. Resolve those aliases only within the recorded session,
    /// retaining the original native IDs as attributes and unresolved external links unchanged.
    private static func resolvedRecordLinks(_ records: [EvidenceRecord]) throws -> [EvidenceRecord] {
        var calls: [String: [String]] = [:], messages: [String: [String]] = [:]
        for record in records {
            try Task.checkCancellation()
            guard let session = record.sessionID else { continue }
            if record.kind == "tool_call", let call = record.attributes["call_id"] {
                calls[session + "\u{0}" + call, default: []].append(record.id)
            }
            if let native = record.attributes["native_record_id"] {
                messages[session + ":" + native, default: []].append(record.id)
            }
        }
        return try records.map { record in
            try Task.checkCancellation()
            var result = record
            result.links = Array(Set(record.links.flatMap { link -> [EvidenceLink] in
                let targets: [String]?
                if link.relation == "tool_call", let session = record.sessionID { targets = calls[session + "\u{0}" + link.target] }
                else if link.relation == "parent_record" { targets = messages[link.target] }
                else { targets = nil }
                return targets?.map { EvidenceLink(relation: link.relation, target: $0) } ?? [link]
            })).sorted { ($0.relation, $0.target) < ($1.relation, $1.target) }
            return result
        }
    }
    private static func signature(_ record: EvidenceRecord) -> String {
        EvidenceIdentity.digest([record.attributes["turn_id"] ?? "", record.role.rawValue, record.kind, record.text].joined(separator: "\u{0}"))
    }
    private static func evidenceRole(_ value: String?) -> EvidenceRole {
        switch value {
        case "user": .user
        case "assistant": .assistant
        case "tool", "toolResult": .tool
        case "system", "developer": .instruction
        default: .observation
        }
    }
    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? NSNumber { return value.boolValue }
        return (value as? String) == "true" || (value as? String) == "1"
    }
    private static func errorFlag(_ value: Any?) -> String? {
        (value as? Bool).map { $0 ? "true" : "false" }
    }
    private static func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func array(_ value: Any?) -> [[String: Any]]? {
        if let values = value as? [[String: Any]] { return values }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
    private static func hermesContent(_ value: Any?) -> Any? {
        guard let text = value as? String, text.hasPrefix("\u{0}json:"), let data = String(text.dropFirst(6)).data(using: .utf8) else { return value }
        return (try? JSONSerialization.jsonObject(with: data)) ?? value
    }
    private static func visibleText(_ value: Any?, depth: Int = 0) -> String {
        guard depth < 12 else { return "" }
        if let text = value as? String { return text }
        if let values = value as? [Any] { return values.map { visibleText($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        if let value = value as? [String: Any] {
            if ["encrypted_content", "image", "input_image", "image_url", "audio", "input_audio"].contains(string(value["type"]) ?? "") { return "" }
            // Alias fields (OpenClaw toolResult text/content) are alternate representations.
            return visibleText(value["text"] ?? value["content"] ?? value["output"], depth: depth + 1)
        }
        return ""
    }
    private static func jsonText(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func toolText(name: String?, arguments: Any?) -> String {
        let args = jsonText(arguments)
        return "Tool: \(name ?? "unnamed")" + (args.isEmpty ? "" : "\nArguments: " + args)
    }
    private enum EpochUnit { case seconds, milliseconds }
    private static func timestamp(_ value: Any?, unit: EpochUnit? = nil) -> String? {
        if let text = value as? String, text.contains("T") { return text }
        guard let unit, let raw = string(value), let number = Double(raw), number.isFinite else { return nil }
        return EvidenceDates.string(Date(timeIntervalSince1970: unit == .milliseconds ? number / 1000 : number))
    }
}

/// Active databases use a read transaction with their WAL. A closed database whose WAL is absent is
/// copied only after verifying a stable main file and absent journals; Apple SQLite cannot otherwise
/// open a WAL-mode database without creating source sidecars. The private copy owns any such writes.
nonisolated private final class SessionSQLite {
    private var handle: OpaquePointer?
    private var snapshotDirectory: URL?
    private var tables = Set<String>()
    private var consumedBytes = 0
    init(url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ContextError.invalid("Select a regular SQLite database, not a symbolic link.") }
        guard (info.fileSize ?? 0) <= 1_073_741_824 else { throw ContextError.limit("This database exceeds the 1 GiB import limit. Select an exported session.") }
        let fm = FileManager.default
        let wal = URL(fileURLWithPath: url.path + "-wal")
        var readURL = url
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if fm.fileExists(atPath: wal.path) {
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                guard fm.fileExists(atPath: sidecar.path) else { throw ContextError.unavailable("The active database is still preparing its WAL index. Retry after the source saves.") }
                let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ContextError.invalid("Database sidecars must be regular files.") }
            }
        } else {
            let directory = fm.temporaryDirectory.appendingPathComponent("sentient-session-snapshot-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                readURL = try Self.copyClosedDatabase(url, into: directory)
            } catch { try? fm.removeItem(at: directory); throw error }
            snapshotDirectory = directory
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX // Only the private copy can create sidecars.
        }
        guard sqlite3_open_v2(readURL.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle); self.handle = nil }
            if let snapshotDirectory { try? fm.removeItem(at: snapshotDirectory); self.snapshotDirectory = nil }
            throw ContextError.database("The session database could not be opened read-only. Check its access permission and WAL sidecars.")
        }
        sqlite3_busy_timeout(handle, 1500)
        do {
            try execute("PRAGMA query_only=ON")
            try execute("BEGIN")
            tables = Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] as? String })
        } catch {
            sqlite3_close(handle); handle = nil
            if let snapshotDirectory { try? fm.removeItem(at: snapshotDirectory); self.snapshotDirectory = nil }
            throw error
        }
    }
    deinit {
        sqlite3_close(handle)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
    }
    private static func copyClosedDatabase(_ source: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        func hasJournal() -> Bool {
            ["-wal", "-journal"].contains { fm.fileExists(atPath: source.path + $0) }
        }
        guard !hasJournal() else { throw ContextError.unavailable("The database is changing. Retry after the source saves.") }
        let before = try fm.attributesOfItem(atPath: source.path)
        let copy = directory.appendingPathComponent("snapshot.sqlite")
        try fm.copyItem(at: source, to: copy)
        let copyHash = try digestFile(copy)
        let sourceHash = try digestFile(source)
        let after = try fm.attributesOfItem(atPath: source.path)
        let unchanged = [FileAttributeKey.size, .modificationDate, .systemFileNumber].allSatisfy {
            String(describing: before[$0]) == String(describing: after[$0])
        }
        guard unchanged, copyHash == sourceHash, !hasJournal() else {
            throw ContextError.unavailable("The database changed while its snapshot was being captured. Retry after the source saves.")
        }
        return copy
    }
    private static func digestFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        var count = 0
        while let part = try file.read(upToCount: 65_536), !part.isEmpty {
            try Task.checkCancellation()
            count += part.count
            guard count <= 1_073_741_824 else { throw ContextError.limit("The database grew beyond the snapshot limit.") }
            digest.update(data: part)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func hasTable(_ name: String) -> Bool { tables.contains(name) }
    func require(_ table: String, columns required: Set<String>) throws {
        guard tables.contains(table) else { throw ContextError.invalid("This database does not contain the supported \(table) session schema. Select the canonical transcript database.") }
        let columns = Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
        guard required.isSubset(of: columns) else { throw ContextError.invalid("The \(table) schema is unsupported or incomplete. Export a session with the source application.") }
    }
    private func execute(_ query: String) throws {
        guard sqlite3_exec(handle, query, nil, nil, nil) == SQLITE_OK else { throw ContextError.database("A read-only session snapshot could not be established. Retry after the writer saves.") }
    }
    func rows(_ query: String) throws -> [[String: Any]] {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            throw ContextError.database("A supported session table could not be read. The schema may have changed.")
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String: Any]] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ContextError.database("The session snapshot could not be read completely. No source data was changed.") }
            guard result.count < 100_000 else { throw ContextError.limit("The session table exceeds 100,000 rows. Select a smaller export.") }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    consumedBytes += count
                    guard count <= 8 * 1_024 * 1_024, consumedBytes <= StructuredInput.maximumBytes else {
                        throw ContextError.limit("The selected transcript exceeds the bounded text import limit. Export a smaller session.")
                    }
                    if let pointer = sqlite3_column_text(statement, column) {
                        // Hermes's structured-content sentinel starts with NUL; C-string decoding loses it.
                        guard let text = String(data: Data(bytes: pointer, count: count), encoding: .utf8) else {
                            throw ContextError.invalid("A session text field is not valid UTF-8.")
                        }
                        row[name] = text
                    }
                case SQLITE_NULL: break
                default: break // Binary attachments, vector tables, and encrypted blobs are not transcripts.
                }
            }
            result.append(row)
        }
        return result
    }
}
