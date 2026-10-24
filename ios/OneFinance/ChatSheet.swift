import SwiftUI

/// The AI ring button: ask the Advisor. While it works, its steps (and hand-offs to the
/// Accountant or Investor) appear live from the backend's run log.
struct ChatSheet: View {
    private struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        var tokens: String?
    }

    @State private var messages: [Message] = []
    @State private var question = ""
    @State private var working = false
    @State private var liveSteps: [AgentEvent] = []
    @FocusState private var focused: Bool

    private let api = APIClient()
    private let suggestions = ["How is my budget this month?", "Why is Dining over budget?", "Is my portfolio too concentrated?"]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if messages.isEmpty { intro }
                                ForEach(messages) { bubble($0) }
                                if working { AgentActivity(steps: liveSteps).id("working") }
                            }
                            .padding(20)
                        }
                        .onChange(of: liveSteps.count) { proxy.scrollTo("working", anchor: .bottom) }
                    }
                    inputBar
                }
            }
            .navigationTitle("Advisor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.onyx900, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AIRing(size: 28, ring: 6)
                Text("Ask about your budget, spending or investments.").foregroundStyle(Theme.text)
            }
            Text("The Advisor can hand work to the Accountant or the Investor. Suggestions only: it can't move money or trade.")
                .font(.footnote).foregroundStyle(Theme.muted)
            ForEach(suggestions, id: \.self) { s in
                Button { question = s; send() } label: { Chip(text: s) }
            }
        }
    }

    private func bubble(_ m: Message) -> some View {
        VStack(alignment: m.fromUser ? .trailing : .leading, spacing: 4) {
            Text(m.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .padding(12)
                .background(m.fromUser ? Theme.vib700.opacity(0.6) : Theme.onyx700, in: RoundedRectangle(cornerRadius: 16))
            if let tokens = m.tokens {
                Text(tokens).font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask the Advisor…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(12)
                .background(Theme.onyx800, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline, lineWidth: 1))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.vib500, in: Circle())
            }
            .disabled(working || question.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(working ? 0.4 : 1)
        }
        .padding(12)
        .background(Theme.onyx900)
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !working else { return }
        messages.append(Message(fromUser: true, text: q))
        question = ""
        focused = false
        working = true
        liveSteps = []
        Task {
            let watcher = Task { await watchSteps() }
            do {
                let reply: ChatReply = try await api.post("agents/chat", body: ["question": q])
                messages.append(Message(fromUser: false, text: reply.answer,
                                        tokens: "\(reply.inputTokens + reply.outputTokens) tokens · \(reply.cachedTokens) cached"))
            } catch {
                messages.append(Message(fromUser: false, text: "Sorry, that didn't work: \(error.localizedDescription)"))
            }
            watcher.cancel()
            working = false
        }
    }

    /// Polls the run log so the user sees which agent is doing what.
    private func watchSteps() async {
        await AgentWatcher.watch(api: api) { liveSteps.append(contentsOf: $0) }
    }
}

/// Follows the run log from "now" on, calling `onNew` with each batch of new steps.
enum AgentWatcher {
    private struct LatestID: Decodable { let id: Int }

    static func watch(api: APIClient, onNew: @escaping ([AgentEvent]) -> Void) async {
        var after = (try? await api.get("events/latest-id") as LatestID)?.id ?? 0
        while !Task.isCancelled {
            if let new: EventList = try? await api.get("events", query: ["after": "\(after)"]), let last = new.events.last {
                await MainActor.run { onNew(new.events) }
                after = last.id
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}

/// A compact live view of what the agents are doing.
struct AgentActivity: View {
    let steps: [AgentEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().tint(Theme.vib400)
                Text("Working…").font(.footnote.weight(.semibold)).foregroundStyle(Theme.vib300)
            }
            ForEach(steps.suffix(6)) { s in
                HStack(spacing: 6) {
                    GlowDot(color: color(s.agent), size: 5)
                    Text(describe(s)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.onyx800.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(_ agent: String) -> Color {
        switch agent {
        case "accountant": return Color(hex: 0xFF8A4C)
        case "investor": return Color(hex: 0x2FD39B)
        default: return Theme.vib400
        }
    }

    private func describe(_ s: AgentEvent) -> String {
        let who = s.agent.capitalized
        switch s.stepType {
        case "tool_result": return "\(who) used \(s.tool ?? "a tool")"
        case "delegation": return "Advisor handed work to \((s.chain ?? "").contains("investor") ? "the Investor" : "a specialist")"
        case "model_response": return "\(who) is thinking"
        case "prompt": return s.chain?.contains(">") == true ? "\(who) picked up the task" : "\(who) started"
        case "final_output": return "\(who) finished"
        case "rules": return "Rules recorded the obvious charges (no AI cost)"
        case "retry": return "\(who) was asked to re-check its numbers"
        case "limit": return "\(who) hit a safety limit"
        default: return "\(who): \(s.stepType)"
        }
    }
}
