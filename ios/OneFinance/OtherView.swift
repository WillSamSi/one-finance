import SwiftUI

/// Other: run the agents (month-end check, weekly digest), the Notifications inbox,
/// agent runs with their token counts, and reset.
struct OtherView: View {
    @State private var notifications: [AppNotification] = []
    @State private var runs: [RunSummary] = []
    @State private var month = "2026-09"
    @State private var working: String?
    @State private var steps: [AgentEvent] = []
    @State private var message: String?

    private let api = APIClient()

    var body: some View {
        NavigationStack {
            ZStack {
            Theme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenTitle(title: "Other")
                    agentsCard
                    notificationsCard
                    runsCard
                    Button { Task { await reset() } } label: { Chip(text: "Reset sample data", color: Theme.muted) }
                        .disabled(working != nil)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 180)
            }
            .scrollIndicators(.hidden)
            }
            .refreshable { await load() }
            .task { await load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { RunDetailView(runId: $0) }
        }
    }

    private var agentsCard: some View {
        AICard {
            VStack(alignment: .leading, spacing: 12) {
                AILabel(title: "Agents", note: nil)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Month-end check").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text("The Accountant reads receipts and statements, cross-checks and flags problems.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    MonthMenu(months: ["2026-10", "2026-09", "2026-08", "2026-07"], selected: $month)
                }
                Button { Task { await run("month-end") } } label: { Chip(text: working == "month-end" ? "Accountant is working…" : "Run month-end check") }
                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly digest").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text("The Advisor writes this week's spending and investment notifications.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Button { Task { await run("digest") } } label: { Chip(text: working == "digest" ? "Advisor is working…" : "Send this week's digest now") }
                if working != nil { AgentActivity(steps: steps) }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.vib300) }
            }
            .disabled(working != nil)
        }
    }

    private var notificationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notifications").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                if notifications.isEmpty {
                    Text("No digests yet.").font(.footnote).foregroundStyle(Theme.muted)
                }
                ForEach(notifications) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            GlowDot(color: n.kind == "investment_digest" ? Theme.positive : Theme.vib400)
                            Text(n.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        }
                        Text(n.body).font(.system(size: 12.5)).foregroundStyle(Theme.cardText).fixedSize(horizontal: false, vertical: true)
                        Text(n.createdAt.prefix(16).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private var runsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Agent runs").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Every step and its tokens. Tap a run to trace it.").font(.caption).foregroundStyle(Theme.muted)
                if runs.isEmpty { Text("No runs yet.").font(.footnote).foregroundStyle(Theme.muted) }
                ForEach(runs) { r in
                    NavigationLink(value: r.runId) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((r.agents ?? "").split(separator: ",").map { $0.capitalized }.joined(separator: " → "))
                                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                                Text("\(r.modelCalls ?? 0) model calls · \(r.toolCalls ?? 0) tool calls · \(r.started.prefix(16).replacingOccurrences(of: "T", with: " "))")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\((r.inputTokens + r.outputTokens).formatted()) tok").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.vib300)
                                Text("\(r.cachedTokens.formatted()) cached").font(.caption2).monospacedDigit().foregroundStyle(Theme.muted)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        notifications = (try? await api.get("notifications") as NotificationList)?.items ?? []
        runs = (try? await api.get("runs", query: ["limit": "15"]) as RunList)?.runs ?? []
    }

    private func run(_ kind: String) async {
        working = kind
        steps = []
        message = nil
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            if kind == "month-end" {
                let r: AgentRunResult = try await api.post("agents/month-end", body: ["month": month])
                message = "Done: \(r.inputTokens + r.outputTokens) tokens. See Review in Wallet."
            } else {
                let r: DigestResult = try await api.post("agents/weekly-digest")
                if let d = r.digest {
                    LocalNotifications.post(title: d.spendingTitle, body: d.spendingBody)
                    LocalNotifications.post(title: d.investmentTitle, body: d.investmentBody, after: 3)
                }
                message = "Digest sent: \(r.inputTokens + r.outputTokens) tokens."
            }
        } catch {
            message = error.localizedDescription
        }
        watcher.cancel()
        working = nil
        await load()
    }

    private func reset() async {
        let _: OK? = try? await api.post("reset")
        message = "Sample data reset."
        await load()
    }
}

/// One agent run, step by step: the traced run for the report.
struct RunDetailView: View {
    let runId: String
    @State private var steps: [RunStep] = []

    var body: some View {
        ZStack {
            Theme.background
            List(steps) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(s.step). \(s.chain ?? s.agent)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib300)
                        Spacer()
                        if let i = s.inputTokens, let o = s.outputTokens {
                            Text("\(i) in · \(s.cachedTokens ?? 0) cached · \(o) out").font(.caption2).monospacedDigit().foregroundStyle(Theme.muted)
                        }
                    }
                    Text([s.stepType.replacingOccurrences(of: "_", with: " "), s.tool].compactMap { $0 }.joined(separator: ": "))
                        .font(.system(size: 13)).foregroundStyle(.white)
                    if let t = s.text, !t.isEmpty {
                        Text(t).font(.caption).foregroundStyle(Theme.cardText).lineLimit(6)
                    }
                }
                .listRowBackground(Theme.onyx800)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Run \(runId)")
        .navigationBarTitleDisplayMode(.inline)
        .task { steps = (try? await APIClient().get("runs/\(runId)") as RunDetail)?.steps ?? [] }
    }
}
