import PhotosUI
import SwiftUI

/// More (☰), built from mockups/more-dark.html: a profile card, then grouped lists like iOS
/// Settings. 1 AI agents, 2 Money, 3 Notifications, 4 Privacy and security, 5 Help and about,
/// and Demo tools (sample data only). Keeps everything the old Other tab had.
struct MoreView: View {
    @State private var settings: AppSettings?
    @State private var connections: [Connection] = []
    @State private var runs: [RunSummary] = []
    @State private var notifications: [AppNotification] = []
    @State private var working: String?
    @State private var steps: [AgentEvent] = []
    @State private var message: String?
    @State private var month = "2026-10"
    @State private var showMonthEnd = false
    @State private var showSetup = false
    @State private var confirmDelete = false
    @State private var confirmStartOver = false
    @State private var exportURL: URL?
    @State private var lockError: String?

    @AppStorage("faceIDLock") private var faceIDLock = false
    @AppStorage("hideBalances") private var hideBalances = false
    @AppStorage("lastSeenNotification") private var lastSeenNotification = 0
    @AppStorage(NotificationPrefs.spendingKey) private var notifySpending = true
    @AppStorage(NotificationPrefs.investmentKey) private var notifyInvestment = true
    @AppStorage(NotificationPrefs.overBudgetKey) private var notifyOverBudget = true
    @AppStorage(NotificationPrefs.salaryKey) private var notifySalary = true
    @AppStorage(NotificationPrefs.weekdayKey) private var digestWeekday = 1
    @AppStorage(NotificationPrefs.hourKey) private var digestHour = 18

    private let api = APIClient()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("More").font(.system(size: 30, weight: .bold)).tracking(-0.5).foregroundStyle(Theme.text)
                            .padding(.bottom, 14)
                        profileCard
                        aiGroup
                        moneyGroup
                        notificationsGroup
                        privacyGroup
                        helpGroup
                        if settings?.dataMode != "live" { demoGroup }
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.vib300).padding(.top, 12)
                        }
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
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .profile: ProfileView(settings: $settings)
                case .payday: PaydayView(settings: $settings)
                case .backend: BackendAddressView()
                case .aiPreferences: AIPreferencesView(settings: $settings)
                case .inbox: InboxView(notifications: notifications)
                case .runs: RunsView(runs: runs)
                case .run(let id): RunDetailView(runId: id)
                case .connection(let c): ConnectionView(connection: c) { Task { await load() } }
                case .digestTime: DigestTimeView()
                case .whatAISees: WhatTheAISeesView()
                case .howItWorks: HowItWorksView()
                case .backTap: BackTapGuideView()
                case .report: ReportProblemView()
                case .legal: LegalView()
                }
            }
            .sheet(isPresented: $showMonthEnd) { MonthEndSheet(month: $month) { Task { await run("month-end") } } }
            .sheet(isPresented: $showSetup, onDismiss: { Task { await load() } }) { BudgetSetupSheet() }
            .sheet(item: Binding(get: { exportURL.map(ExportFile.init) }, set: { exportURL = $0?.url })) { ExportSheet(url: $0.url) }
            .confirmationDialog("Delete all my data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { Task { await deleteAll() } }
            } message: {
                Text("Accounts, transactions, pockets, receipts and the AI's history are deleted from this app and live connections are switched off. This can't be undone (Reset sample data brings the sample back).")
            }
            .confirmationDialog("Start over?", isPresented: $confirmStartOver, titleVisibility: .visible) {
                Button("Switch off all pockets", role: .destructive) { Task { await startOver() } }
            } message: {
                Text("Every pocket is switched off and Budget setup opens on the first-time choice (AI draft or from scratch). Transactions stay.")
            }
            .alert("Face ID", isPresented: Binding(get: { lockError != nil }, set: { if !$0 { lockError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(lockError ?? "") }
        }
    }

    // MARK: Profile card

    private var profileCard: some View {
        NavigationLink(value: MoreRoute.profile) {
            HStack(spacing: 14) {
                Avatar(name: settings?.profileName ?? "", size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings?.profileName ?? " ").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(settings?.profileEmail ?? " ").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    DataBadge(mode: settings?.dataMode ?? "sample", investments: settings?.investmentsSource)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x6F6683))
            }
            .padding(14)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 1. AI agents

    private var aiGroup: some View {
        MoreGroup(title: "AI agents") {
            MoreRow(icon: "checkmark.seal.fill", color: 0x8A2BE2, title: "Month-end check") {
                RunPill(title: working == "month-end" ? "…" : "Run") { showMonthEnd = true }.disabled(working != nil)
            }
            MoreRow(icon: "newspaper.fill", color: 0x2F8CFF, title: "Weekly digest") {
                RunPill(title: working == "digest" ? "…" : "Run") { Task { await run("digest") } }.disabled(working != nil)
            }
            if working != nil {
                AgentActivity(steps: steps).padding(.horizontal, 12).padding(.vertical, 8)
            }
            NavigationLink(value: MoreRoute.inbox) {
                MoreRow(icon: "bell.fill", color: 0xE5484D, title: "Notifications") {
                    if unread > 0 { CountBadge(count: unread) }
                    Chevron()
                }
            }
            .simultaneousGesture(TapGesture().onEnded { lastSeenNotification = notifications.map(\.id).max() ?? lastSeenNotification })
            NavigationLink(value: MoreRoute.runs) {
                MoreRow(icon: "waveform.path.ecg", color: 0x14B8A6, title: "Agent runs and tokens", subtitle: runsSummary) { Chevron() }
            }
            NavigationLink(value: MoreRoute.aiPreferences) {
                MoreRow(icon: "slider.horizontal.3", color: 0xF59E0B, title: "AI preferences") { Chevron() }
            }
        }
    }

    private var unread: Int { notifications.filter { $0.id > lastSeenNotification }.count }

    private var runsSummary: String {
        let monthRuns = runs.filter { $0.started.hasPrefix(String(Date.now.formatted(.iso8601.year().month()).prefix(7))) }
        let list = monthRuns.isEmpty ? runs : monthRuns
        let tokens = list.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        return "\(list.count) runs · \(tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)") tokens\(monthRuns.isEmpty ? "" : " this month")"
    }

    // MARK: 2. Money

    private var moneyGroup: some View {
        MoreGroup(title: "Money") {
            ForEach(connections) { c in
                NavigationLink(value: MoreRoute.connection(c)) {
                    MoreRow(icon: c.icon, color: c.color, title: c.title, subtitle: c.via) {
                        StatusTag(status: c.status)
                    }
                }
            }
            Button { showSetup = true } label: {
                MoreRow(icon: "chart.pie.fill", color: 0xA45CFF, title: "Budget setup") { Chevron() }
            }
            MoreRow(icon: "arrow.left.arrow.right", color: 0x64748B, title: "Exchange rate IDR → USD",
                    subtitle: settings?.fxAsOf.map { "Updated \(DateParse.shortDay($0))" }) {
                if let r = settings?.idrPerUsd {
                    Text("Rp \(Int(r).formatted(.number.locale(Money.locale))) = $1").font(.system(size: 13.5)).monospacedDigit().foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: 3. Notifications

    private var notificationsGroup: some View {
        MoreGroup(title: "Notifications") {
            MoreRow(icon: "cart.fill", color: 0x2F8CFF, title: "Weekly spending digest",
                    subtitle: NotificationPrefs.timeLabel(weekday: digestWeekday, hour: digestHour)) {
                RowSwitch(isOn: $notifySpending)
            }
            MoreRow(icon: "chart.line.uptrend.xyaxis", color: 0x2FD39B, title: "Weekly investment digest",
                    subtitle: NotificationPrefs.timeLabel(weekday: digestWeekday, hour: digestHour)) {
                RowSwitch(isOn: $notifyInvestment)
            }
            NavigationLink(value: MoreRoute.digestTime) {
                MoreRow(icon: "clock.fill", color: 0x64748B, title: "Digest day and time") {
                    Text(NotificationPrefs.timeLabel(weekday: digestWeekday, hour: digestHour)).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                    Chevron()
                }
            }
            MoreRow(icon: "exclamationmark.triangle.fill", color: 0xF59E0B, title: "Over-budget alerts") {
                RowSwitch(isOn: $notifyOverBudget)
            }
            MoreRow(icon: "banknote.fill", color: 0x14B8A6, title: "Salary not received alerts") {
                RowSwitch(isOn: $notifySalary)
            }
        }
        .onChange(of: notifySpending) { NotificationPrefs.applySchedule() }
        .onChange(of: notifyInvestment) { NotificationPrefs.applySchedule() }
    }

    // MARK: 4. Privacy and security

    private var privacyGroup: some View {
        MoreGroup(title: "Privacy and security") {
            MoreRow(icon: "faceid", color: 0x2FD39B, title: "Face ID lock") {
                RowSwitch(isOn: Binding(get: { faceIDLock }, set: { on in Task { await setFaceID(on) } }))
            }
            MoreRow(icon: "eye.slash.fill", color: 0x64748B, title: "Hide balances", subtitle: "Mask the total on Home until tapped") {
                RowSwitch(isOn: $hideBalances)
            }
            NavigationLink(value: MoreRoute.whatAISees) {
                MoreRow(icon: "brain.head.profile", color: 0x8A2BE2, title: "What the AI sees") { Chevron() }
            }
            Button { Task { await export() } } label: {
                MoreRow(icon: "square.and.arrow.up.fill", color: 0x2F8CFF, title: "Export my data (CSV)") { Chevron() }
            }
            Button { confirmDelete = true } label: {
                MoreRow(icon: "trash.fill", color: 0xE5484D, title: "Delete all my data", danger: true) { EmptyView() }
            }
        }
    }

    // MARK: 5. Help and about

    private var helpGroup: some View {
        MoreGroup(title: "Help and about", footer: "Suggestions from the Investor and Advisor agents are not financial advice.") {
            NavigationLink(value: MoreRoute.howItWorks) {
                MoreRow(icon: "book.fill", color: 0xF59E0B, title: "How it works") { Chevron() }
            }
            NavigationLink(value: MoreRoute.backTap) {
                MoreRow(icon: "hand.tap.fill", color: 0xA45CFF, title: "Set up Back Tap") { Chevron() }
            }
            NavigationLink(value: MoreRoute.report) {
                MoreRow(icon: "ladybug.fill", color: 0xE5484D, title: "Report a problem") { Chevron() }
            }
            NavigationLink(value: MoreRoute.backend) {
                MoreRow(icon: "server.rack", color: 0x14B8A6, title: "Backend address") {
                    Text(APIClient.baseURL.host() ?? "").font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    Chevron()
                }
            }
            MoreRow(icon: "info.circle.fill", color: 0x64748B, title: "Version") {
                Text(AppInfo.version).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            }
            NavigationLink(value: MoreRoute.legal) {
                MoreRow(icon: "building.columns.fill", color: 0x2F8CFF, title: "Legal") { Chevron() }
            }
        }
    }

    // MARK: Demo tools

    private var demoGroup: some View {
        MoreGroup(title: "Demo tools · sample mode only") {
            Button { Task { await reset() } } label: {
                MoreRow(icon: "arrow.counterclockwise", color: 0xF59E0B, title: "Reset sample data") { Chevron() }
            }
            .disabled(working != nil)
            Button { confirmStartOver = true } label: {
                MoreRow(icon: "flag.fill", color: 0x8A2BE2, title: "Start over", subtitle: "Opens first-time setup") { Chevron() }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        settings = try? await api.get("settings")
        connections = (try? await api.get("connections") as ConnectionList)?.connections ?? []
        notifications = (try? await api.get("notifications") as NotificationList)?.items ?? []
        runs = (try? await api.get("runs", query: ["limit": "50"]) as RunList)?.runs ?? []
    }

    private func run(_ kind: String) async {
        showMonthEnd = false
        working = kind
        steps = []
        message = nil
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            if kind == "month-end" {
                let r: AgentRunResult = try await api.post("agents/month-end", body: ["month": month])
                message = "Month-end check done (\((r.inputTokens + r.outputTokens).formatted(.number.locale(Money.locale))) tokens). See Review in Wallet."
            } else {
                let r: DigestResult = try await api.post("agents/weekly-digest")
                if let d = r.digest {
                    if notifySpending { LocalNotifications.post(title: d.spendingTitle, body: d.spendingBody) }
                    if notifyInvestment, settings?.aiInvestmentSuggestions != false {
                        LocalNotifications.post(title: d.investmentTitle, body: d.investmentBody, after: 3)
                    }
                }
                message = "Digest sent (\((r.inputTokens + r.outputTokens).formatted(.number.locale(Money.locale))) tokens). It's in Notifications."
            }
        } catch {
            message = error.localizedDescription
        }
        watcher.cancel()
        working = nil
        await load()
    }

    private func setFaceID(_ on: Bool) async {
        guard on else { faceIDLock = false; return }
        // Turn it on only after one successful Face ID check, so nobody locks themselves out.
        switch await AppLock.authenticate(reason: "Turn on Face ID lock for One Finance") {
        case .success: faceIDLock = true
        case .unavailable(let why): lockError = why
        case .failed, .cancelled: break
        }
    }

    private func export() async {
        do {
            var request = URLRequest(url: APIClient.baseURL.appending(path: "export.csv"))
            request.timeoutInterval = 60
            let (data, _) = try await URLSession.shared.data(for: request)
            let url = FileManager.default.temporaryDirectory.appending(path: "one-finance-export.csv")
            try data.write(to: url)
            exportURL = url
        } catch {
            message = error.localizedDescription
        }
    }

    private func deleteAll() async {
        let _: OK? = try? await api.post("delete-all")
        hideBalances = false
        message = "All your data was deleted. Reset sample data (below) brings the sample back."
        await load()
    }

    private func reset() async {
        working = "reset"
        let _: OK? = try? await api.post("reset")
        working = nil
        message = "Sample data reset."
        await load()
    }

    private func startOver() async {
        let _: OK? = try? await api.post("budget/start-over")
        showSetup = true
    }
}

enum MoreRoute: Hashable {
    case profile, aiPreferences, inbox, runs, digestTime, whatAISees, howItWorks, backTap, report, legal, payday, backend
    case run(String)
    case connection(Connection)
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

enum AppInfo {
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Models

struct AppSettings: Decodable {
    var profileName: String
    var profileEmail: String
    var livesIn: String
    var homeCountry: String
    var displayCurrency: String
    var aiInvestmentSuggestions: Bool
    var maxSectorShare: Double
    var autoRecord: Bool
    let idrPerUsd: Double?
    let fxAsOf: String?
    let fxSource: String
    let dataMode: String
    let investmentsSource: String?
    let deleted: Bool
    var paySchedule: String
    var payday: String
    var payDetected: Bool
    var budgetMonthStart: String
    var budgetStartDay: Int
    var riskComfort: String
    var timeHorizon: String
    var timeZone: String
    let salary: SalaryStatus?
}

struct SalaryStatus: Decodable {
    let missing: Bool
    let expected: String?
}

struct ConnectionList: Decodable { let connections: [Connection] }

struct Connection: Decodable, Identifiable, Hashable {
    var id: String { source }
    let source: String
    let title: String
    let via: String
    let accounts: Int
    let status: String
    let asOf: String?
    let canRefresh: Bool

    var icon: String {
        switch source {
        case "plaid": "building.columns.fill"
        case "snaptrade": "chart.line.uptrend.xyaxis"
        default: "doc.text.fill"
        }
    }
    var color: UInt32 {
        switch source {
        case "plaid": 0x2F8CFF
        case "snaptrade": 0x2FD39B
        default: 0xE5484D
        }
    }
}

// MARK: - Building blocks (from the render)

struct MoreGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.muted)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                Group { content }
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -1)  // the first row's divider sits above the card and is clipped away
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 4)
            }
        }
        .padding(.top, 22)
    }
}

/// One row: a colored rounded-square icon, the title (and a small line under it), and
/// whatever goes on the right. Rows after the first get a hairline, inset past the icon.
struct MoreRow<Trailing: View>: View {
    let icon: String
    let color: UInt32
    let title: String
    var subtitle: String?
    var danger = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(hex: color), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: danger ? .semibold : .regular))
                    .foregroundStyle(danger ? Color(hex: 0xFF6B6B) : Theme.text)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 52)
        }
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x6F6683))
    }
}

struct RunPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib300)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(Theme.vib500.opacity(0.22), in: Capsule())
                .overlay(Capsule().stroke(Theme.vib400.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 4)
            .background(Color(hex: 0xE5484D), in: Capsule())
    }
}

struct StatusTag: View {
    let status: String
    var body: some View {
        let good = status == "Connected"
        Text(status).font(.system(size: 11, weight: .bold))
            .foregroundStyle(good ? Color(hex: 0x7FE8C0) : status == "Sample" ? Color(hex: 0xFFD27A) : Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((good ? Color(hex: 0x2FD39B) : status == "Sample" ? Color(hex: 0xF5C542) : .white).opacity(good || status == "Sample" ? 0.14 : 0.08),
                        in: Capsule())
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 54
    @AppStorage(ProfilePhoto.versionKey) private var photoVersion = 0

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Group {
            if photoVersion >= 0, let image = ProfilePhoto.load() {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(Theme.vib100)
            }
        }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .background(LinearGradient(colors: [Theme.vib500, Theme.vib900], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(Circle().stroke(Theme.vib300.opacity(0.35), lineWidth: 1))
            .shadow(color: Theme.vib500.opacity(0.4), radius: 10)
    }
}

/// "Sample data", or "Live" when real connections feed the app.
struct DataBadge: View {
    let mode: String
    var investments: String?

    var body: some View {
        let label = mode == "live" ? "Live" : mode == "empty" ? "No data" : "Sample data"
        Text(label).font(.system(size: 11, weight: .bold))
            .foregroundStyle(mode == "live" ? Color(hex: 0x7FE8C0) : Color(hex: 0xFFD27A))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((mode == "live" ? Color(hex: 0x2FD39B) : Color(hex: 0xF5C542)).opacity(0.14), in: Capsule())
    }
}

// MARK: - Pages

/// Profile, built from the "Profile" phones in mockups/more-dark.html. Only fields the app uses:
/// you (photo, name, email), where you live and your money (time zone from the phone), pay and
/// budget month (payday drives the late-salary alert; the budget month can start on payday), and
/// an optional investing profile the Investor and Advisor follow. No date of birth, address or ID.
struct ProfileView: View {
    @Binding var settings: AppSettings?
    @State private var name = ""
    @State private var email = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var error: String?
    @AppStorage(ProfilePhoto.versionKey) private var photoVersion = 0

    private static let countries = ["United States", "Indonesia", "Singapore", "Australia", "United Kingdom", "Japan", "Other"]
    private static let schedules = ["monthly", "twice a month", "every 2 weeks", "irregular"]
    private static let horizons = [("<3", "Under 3 years"), ("3-10", "3–10 years"), ("10+", "10+ years")]

    var body: some View {
        PageScroll(title: "Profile") {
            if let s = settings {
                header(s)
                MoreGroup(title: "You", footer: "Used for exports and Report a problem.") {
                    MoreRow(icon: "person.fill", color: 0x8A2BE2, title: "Name") {
                        TextField("Name", text: $name).multilineTextAlignment(.trailing).foregroundStyle(Theme.muted)
                            .onSubmit { Task { await save(["profile_name": name]) } }
                    }
                    MoreRow(icon: "envelope.fill", color: 0x2F8CFF, title: "Email") {
                        TextField("Email", text: $email).multilineTextAlignment(.trailing).foregroundStyle(Theme.muted)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { Task { await save(["profile_email": email]) } }
                    }
                }
                MoreGroup(title: "Where you live and your money") {
                    MoreRow(icon: "mappin.circle.fill", color: 0x2FD39B, title: "Lives in") {
                        choiceMenu(s.livesIn, Self.countries.map { ($0, $0) }) { c in Task { await save(["lives_in": c]) } }
                    }
                    MoreRow(icon: "globe", color: 0xE5484D, title: "Home country") {
                        choiceMenu(s.homeCountry, Self.countries.map { ($0, $0) }) { c in Task { await save(["home_country": c]) } }
                    }
                    MoreRow(icon: "dollarsign.circle.fill", color: 0xF59E0B, title: "Display currency") {
                        HStack(spacing: 5) {
                            Text(s.displayCurrency).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0x6F6683))
                        }
                    }
                    MoreRow(icon: "arrow.left.arrow.right", color: 0x64748B, title: "Exchange rates from") {
                        Text(s.fxSource).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing)
                    }
                    MoreRow(icon: "clock.fill", color: 0x14B8A6, title: "Time zone", subtitle: "Automatic") {
                        Text(TimeZone(identifier: s.timeZone)?.localizedName(for: .generic, locale: .current) ?? s.timeZone)
                            .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                    }
                }
                MoreGroup(title: "Pay and budget month", footer: "Pockets reset and roll over on this day.") {
                    MoreRow(icon: "banknote.fill", color: 0x2FD39B, title: "How you're paid",
                            subtitle: s.payDetected ? "Detected from your deposits" : nil) {
                        choiceMenu(Self.sentence(s.paySchedule), Self.schedules.map { ($0, Self.sentence($0)) }) { v in
                            Task { await save(["pay_schedule": v, "payday": Self.defaultPayday(v, current: s)]) }
                        }
                    }
                    if s.paySchedule != "irregular" {
                        NavigationLink(value: MoreRoute.payday) {
                            MoreRow(icon: "calendar", color: 0x2F8CFF, title: "Payday") {
                                Text(Self.paydayLabel(s.paySchedule, s.payday)).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                                Chevron()
                            }
                        }
                    }
                    MoreRow(icon: "arrow.triangle.2.circlepath", color: 0x8A2BE2, title: "Budget month starts on") {
                        let paydayOK = ["monthly", "twice a month"].contains(s.paySchedule)
                        let first = Self.ordinal(Int(s.payday.split(separator: ",").first ?? "1") ?? 1)
                        choiceMenu(s.budgetMonthStart == "payday" ? "Payday (the \(first))" : "The 1st",
                                   [("1st", "The 1st")] + (paydayOK ? [("payday", "Payday (the \(first))")] : [])) { v in
                            Task { await save(["budget_month_start": v]) }
                        }
                    }
                }
                MoreGroup(title: "Investing profile (optional)", footer: "The Investor and Advisor shape suggestions to this. Not financial advice.") {
                    VStack(alignment: .leading, spacing: 10) {
                        MoreRow(icon: "gauge.with.dots.needle.33percent", color: 0x8A2BE2, title: "Risk comfort") { EmptyView() }
                        RiskPicker(selected: s.riskComfort) { v in Task { await save(["risk_comfort": v]) } }
                            .padding(.leading, 52).padding(.trailing, 12).padding(.bottom, 12)
                    }
                    MoreRow(icon: "hourglass", color: 0xF59E0B, title: "Time horizon") {
                        choiceMenu(Self.horizons.first { $0.0 == s.timeHorizon }?.1 ?? "Not set",
                                   Self.horizons + [("", "Not set")]) { v in Task { await save(["time_horizon": v]) } }
                    }
                }
                privacyNote
                MoreGroup(title: "Privacy") {
                    NavigationLink(value: MoreRoute.whatAISees) {
                        MoreRow(icon: "brain.head.profile", color: 0x8A2BE2, title: "What the AI sees") { Chevron() }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.over).padding(.top, 8) }
            }
        }
        .onAppear { name = settings?.profileName ?? ""; email = settings?.profileEmail ?? "" }
        .onDisappear {
            Task {
                if let s = settings, name != s.profileName || email != s.profileEmail {
                    await save(["profile_name": name, "profile_email": email])
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    ProfilePhoto.save(data)
                    photoVersion += 1
                }
            }
        }
    }

    private func header(_ s: AppSettings) -> some View {
        VStack(spacing: 6) {
            Avatar(name: name.isEmpty ? s.profileName : name, size: 84)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Edit photo").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib300)
            }
            if ProfilePhoto.load() != nil, photoVersion >= 0 {
                Button("Remove photo") { ProfilePhoto.remove(); photoVersion += 1 }
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            DataBadge(mode: s.dataMode, investments: s.investmentsSource)
        }
        .frame(maxWidth: .infinity)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.positive).font(.system(size: 14)).padding(.top, 1)
            Text("We don't ask for your date of birth, address or ID. Your bank already verified who you are, and this app only reads your data.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.cardText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.positive.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.positive.opacity(0.25), lineWidth: 1))
        .padding(.top, 22)
    }

    private func choiceMenu(_ value: String, _ options: [(String, String)], set: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { key, label in Button(label) { set(key) } }
        } label: {
            HStack(spacing: 4) {
                Text(value).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Color(hex: 0x6F6683))
            }
        }
    }

    static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    static func paydayLabel(_ schedule: String, _ payday: String) -> String {
        switch schedule {
        case "monthly": return "\(ordinal(Int(payday) ?? 1)) of the month"
        case "twice a month":
            let d = payday.split(separator: ",").compactMap { Int($0) }
            return d.count == 2 ? "\(ordinal(d[0])) and \(ordinal(d[1]))" : "Not set"
        case "every 2 weeks":
            return payday.isEmpty ? "Not set" : "Every other \(DateParse.weekday(payday)), next \(DateParse.shortDay(payday))"
        default: return "—"
        }
    }

    static func defaultPayday(_ schedule: String, current: AppSettings) -> String {
        let days = current.payday.split(separator: ",").compactMap { Int($0) }
        switch schedule {
        case "monthly": return String(days.first ?? 1)
        case "twice a month": return days.count == 2 ? current.payday : "1,15"
        case "every 2 weeks":
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Calendar.current.date(byAdding: .day, value: 7, to: .now)!)
        default: return ""
        }
    }

    private func save(_ changes: [String: Any]) async {
        do {
            settings = try await APIClient().patch("settings", body: changes)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Cautious / Balanced / Growth, like the render's segmented control. Tapping the chosen one clears it.
struct RiskPicker: View {
    let selected: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(["cautious", "balanced", "growth"], id: \.self) { option in
                Button { set(option == selected ? "" : option) } label: {
                    Text(option.capitalized).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(option == selected ? .white : Theme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background {
                            if option == selected { RoundedRectangle(cornerRadius: 8).fill(Theme.vib500) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Payday: a day for monthly pay, two days for twice a month, the next date for every 2 weeks.
struct PaydayView: View {
    @Binding var settings: AppSettings?
    @State private var first = 1
    @State private var second = 15
    @State private var next = Date.now
    @State private var error: String?

    var body: some View {
        PageScroll(title: "Payday") {
            if let s = settings {
                MoreGroup(title: ProfileView.sentence(s.paySchedule),
                          footer: "If your salary hasn't arrived 2 days after payday, you get a “salary not received” alert (More → Notifications).") {
                    switch s.paySchedule {
                    case "monthly":
                        LabeledPicker(label: "Day of the month") {
                            Picker("Day of the month", selection: $first) {
                                ForEach(1...28, id: \.self) { Text(ProfileView.ordinal($0)).tag($0) }
                            }
                        }
                    case "twice a month":
                        LabeledPicker(label: "First payday") {
                            Picker("First payday", selection: $first) {
                                ForEach(1...27, id: \.self) { Text(ProfileView.ordinal($0)).tag($0) }
                            }
                        }
                        LabeledPicker(label: "Second payday") {
                            Picker("Second payday", selection: $second) {
                                ForEach((first + 1)...28, id: \.self) { Text(ProfileView.ordinal($0)).tag($0) }
                            }
                        }
                    default:
                        DatePicker("Next payday", selection: $next, displayedComponents: .date)
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12).frame(minHeight: 50)
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.over).padding(.top, 8) }
            }
        }
        .onAppear {
            let d = (settings?.payday ?? "").split(separator: ",").compactMap { Int($0) }
            first = d.first ?? 1
            second = d.count > 1 ? d[1] : 15
            if let iso = settings?.payday, iso.count == 10 { next = DateParse.localDay(iso) }
        }
        .onChange(of: first) { _, v in if second <= v { second = min(28, v + 1) }; Task { await save() } }
        .onChange(of: second) { Task { await save() } }
        .onChange(of: next) { Task { await save() } }
    }

    private func save() async {
        guard let s = settings else { return }
        let value: String
        switch s.paySchedule {
        case "monthly": value = String(first)
        case "twice a month": value = "\(first),\(second)"
        default:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            value = f.string(from: next)
        }
        guard value != s.payday else { return }
        do {
            settings = try await APIClient().patch("settings", body: ["pay_schedule": s.paySchedule, "payday": value])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The profile photo stays on the phone (never sent to the backend or the AI).
enum ProfilePhoto {
    static let versionKey = "profilePhotoVersion"
    private static var url: URL { URL.documentsDirectory.appending(path: "profile-photo.jpg") }

    static func load() -> UIImage? { UIImage(contentsOfFile: url.path) }

    static func save(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let side: CGFloat = 400
        let scale = side / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? small.jpegData(compressionQuality: 0.85)?.write(to: url)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Investment suggestions, max share per sector, auto-record: real backend settings.
struct AIPreferencesView: View {
    @Binding var settings: AppSettings?
    @State private var error: String?

    var body: some View {
        PageScroll(title: "AI preferences") {
            if let s = settings {
                MoreGroup(title: "Investing", footer: "The Investor flags any sector above this share of your portfolio.") {
                    MoreRow(icon: "lightbulb.fill", color: 0x8A2BE2, title: "Investment suggestions", subtitle: "Advisor and Investor suggest, never trade") {
                        RowSwitch(isOn: Binding(get: { s.aiInvestmentSuggestions }, set: { v in Task { await save(["ai_investment_suggestions": v]) } }))
                    }
                    MoreRow(icon: "chart.pie.fill", color: 0x2F8CFF, title: "Max share per sector") {
                        HStack(spacing: 10) {
                            stepButton("minus") { Task { await save(["max_sector_share": max(0.1, s.maxSectorShare - 0.05)]) } }
                            Text("\(Int((s.maxSectorShare * 100).rounded()))%").font(.system(size: 14, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Theme.text).frame(minWidth: 40)
                            stepButton("plus") { Task { await save(["max_sector_share": min(1.0, s.maxSectorShare + 0.05)]) } }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.05), in: Capsule())
                    }
                }
                NavigationLink(value: MoreRoute.profile) {
                    MoreRow(icon: "person.crop.circle", color: 0x64748B, title: "Investing profile",
                            subtitle: [s.riskComfort.capitalized, s.timeHorizon.isEmpty ? "" : s.timeHorizon + " years"]
                                .filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? "Not set (in Profile)") { Chevron() }
                }
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 12)
                MoreGroup(title: "Recording", footer: "Agents only change pocket numbers. They can't move real money, and every change can be undone.") {
                    MoreRow(icon: "checkmark.circle.fill", color: 0x2FD39B, title: "Auto-record confident matches", subtitle: "Unsure ones go to Review") {
                        RowSwitch(isOn: Binding(get: { s.autoRecord }, set: { v in Task { await save(["auto_record": v]) } }))
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.over) }
            }
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.vib300).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private func save(_ changes: [String: Any]) async {
        do {
            settings = try await APIClient().patch("settings", body: changes)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct InboxView: View {
    let notifications: [AppNotification]

    var body: some View {
        PageScroll(title: "Notifications") {
            if notifications.isEmpty {
                Text("No digests yet. Run the weekly digest from More.").font(.footnote).foregroundStyle(Theme.muted).padding(.top, 20)
            }
            ForEach(notifications) { n in
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            GlowDot(color: n.kind == "investment_digest" ? Theme.positive : Theme.vib400)
                            Text(n.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        }
                        Text(AIMarkdown.attributed(n.body)).font(.system(size: 13)).foregroundStyle(Theme.cardText).fixedSize(horizontal: false, vertical: true)
                        Text(n.createdAt.prefix(16).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

/// Every agent run with its tokens (Tokenomics); tap one for the step-by-step trace.
struct RunsView: View {
    let runs: [RunSummary]

    var body: some View {
        PageScroll(title: "Agent runs and tokens") {
            let total = runs.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            let cached = runs.reduce(0) { $0 + $1.cachedTokens }
            Text("\(runs.count) runs · \(total.formatted(.number.locale(Money.locale))) tokens · \(cached.formatted(.number.locale(Money.locale))) cached. Tap a run to trace it.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            MoreGroup(title: "Runs") {
                if runs.isEmpty { Text("No runs yet.").font(.footnote).foregroundStyle(Theme.muted).padding(12) }
                ForEach(runs) { r in
                    NavigationLink(value: MoreRoute.run(r.runId)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((r.agents ?? "").split(separator: ",").map { $0.capitalized }.joined(separator: " → "))
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                Text("\(r.modelCalls ?? 0) model calls · \(r.toolCalls ?? 0) tool calls · \(r.started.prefix(16).replacingOccurrences(of: "T", with: " "))")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\((r.inputTokens + r.outputTokens).formatted(.number.locale(Money.locale))) tok").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.vib300)
                                Text("\(r.cachedTokens.formatted(.number.locale(Money.locale))) cached").font(.caption2).monospacedDigit().foregroundStyle(Theme.muted)
                            }
                            Chevron()
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
                    }
                }
            }
        }
    }
}

/// One agent run, step by step: the traced run for the report.
struct RunDetailView: View {
    let runId: String
    @State private var steps: [RunStep] = []

    var body: some View {
        ZStack {
            Theme.background
            List(Array(steps.enumerated()), id: \.element.id) { n, s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(n + 1). \(s.chain ?? s.agent)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib300)
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

struct ConnectionView: View {
    let connection: Connection
    let onChange: () -> Void
    @State private var working = false
    @State private var message: String?

    var body: some View {
        PageScroll(title: connection.title) {
            MoreGroup(title: "Status") {
                MoreRow(icon: connection.icon, color: connection.color, title: connection.title, subtitle: connection.via) { StatusTag(status: connection.status) }
                MoreRow(icon: "number", color: 0x64748B, title: "Accounts") {
                    Text("\(connection.accounts)").foregroundStyle(Theme.muted)
                }
                if let asOf = connection.asOf {
                    MoreRow(icon: "clock.fill", color: 0x64748B, title: "Last updated") {
                        Text(DateParse.mediumDay(asOf)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Text(explanation).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 12)
            if connection.canRefresh {
                Button { Task { await self.refresh() } } label: {
                    Text(working ? "Refreshing…" : "Refresh now").frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).tint(Theme.vib500).disabled(working).padding(.top, 12)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.vib300).padding(.top, 8) }
        }
    }

    private var explanation: String {
        switch connection.source {
        case "plaid": return connection.status == "Connected"
            ? "Read-only through Plaid. The app never sees your bank login."
            : "Sample bank data in the shape Plaid sends. With Plaid keys on the backend, these come from the Plaid sandbox."
        case "snaptrade": return "Read-only through SnapTrade (no trading). The app refreshes it when the backend starts and after Reset."
        default: return "BCA, Mandiri and Jago have no open API, so their monthly statements are read by the Accountant. Amounts are converted to US dollars."
        }
    }

    private func refresh() async {
        working = true
        struct SyncReply: Decodable { let ok: Bool; let message: String? }
        let r = try? await APIClient().post("connections/snaptrade/refresh", as: SyncReply.self)
        message = r?.ok == true ? "Up to date." : (r?.message ?? "Couldn't refresh.")
        working = false
        onChange()
    }
}

struct DigestTimeView: View {
    @AppStorage(NotificationPrefs.weekdayKey) private var weekday = 1
    @AppStorage(NotificationPrefs.hourKey) private var hour = 18

    var body: some View {
        PageScroll(title: "Digest day and time") {
            MoreGroup(title: "When the weekly digests arrive") {
                LabeledPicker(label: "Day") {
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                }
                LabeledPicker(label: "Time") {
                    Picker("Time", selection: $hour) {
                        ForEach(6...22, id: \.self) { h in Text(NotificationPrefs.hourLabel(h)).tag(h) }
                    }
                }
            }
        }
        .onChange(of: weekday) { NotificationPrefs.applySchedule() }
        .onChange(of: hour) { NotificationPrefs.applySchedule() }
    }
}

struct WhatTheAISeesView: View {
    @State private var info: AIPrivacy?

    var body: some View {
        PageScroll(title: "What the AI sees") {
            Text("The three agents (Accountant, Investor, Advisor) run on the backend. This is what goes into their prompts.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            if let info {
                bullets("Sent to the AI", info.sent, icon: "arrow.up.circle.fill", color: Theme.vib300)
                bullets("Never sent", info.never, icon: "lock.fill", color: Theme.positive)
                bullets("What the AI can do", info.rules, icon: "checkmark.shield.fill", color: Color(hex: 0xF59E0B))
            }
        }
        .task { info = try? await APIClient().get("privacy/ai") }
    }

    private func bullets(_ title: String, _ items: [String], icon: String, color: Color) -> some View {
        MoreGroup(title: title) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon).foregroundStyle(color).font(.system(size: 13)).padding(.top, 2)
                    Text(item).font(.system(size: 14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }
    }
}

struct AIPrivacy: Decodable {
    let sent: [String]
    let never: [String]
    let rules: [String]
}

struct HowItWorksView: View {
    var body: some View {
        PageScroll(title: "How it works") {
            TextBlock(title: "Pockets", text: "Pockets are labels on your money, not bank accounts. Spending pockets get a monthly budget and unspent money rolls over. Savings and investing pockets grow by what you set aside. Pockets + Unassigned always add up to all your money (the cash check in Wallet).")
            TextBlock(title: "The three agents", text: "The Accountant records transactions, reads receipts and statements, and flags problems for Review. The Investor reads your holdings and the companies' SEC filings. The Advisor writes the weekly digests, answers in chat and drafts budgets. They suggest; you confirm. They can't move real money.")
            TextBlock(title: "Sample and live data", text: "Sample data is a made-up but realistic month of US and Indonesian banking. With keys on the backend, banks come from the Plaid sandbox and the brokerage from the SnapTrade sandbox. The badge on your profile says which you're seeing.")
            TextBlock(title: "Saving tokens", text: "Simple, sure matches (rent, groceries, your salary) are recorded by plain rules for free; only the unclear ones go to the AI. Every run's tokens are in Agent runs and tokens.")
        }
    }
}

struct BackTapGuideView: View {
    var body: some View {
        PageScroll(title: "Set up Back Tap") {
            Text("Log an expense by tapping the back of your iPhone.").font(.system(size: 14)).foregroundStyle(Theme.muted)
            MoreGroup(title: "Steps") {
                ForEach(Array(["Open the Shortcuts app, tap +, search \"One Finance\" and add \"Log expense\". Name the shortcut Log expense.",
                               "Open the Settings app → Accessibility → Touch → Back Tap.", "Choose Double Tap (or Triple Tap).",
                               "Under Shortcuts, pick \"Log expense\".",
                               "Double-tap the back of your iPhone: One Finance opens with the + menu ready to type."].enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Theme.vib500, in: Circle())
                        Text(step).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                }
            }
            Text("Back Tap needs a real iPhone 8 or newer; the Simulator doesn't have it. You can also run \"Log expense\" from the Shortcuts app or Siri.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 10)
        }
    }
}

struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        PageScroll(title: "Report a problem") {
            Text("What happened? The app version and the last agent run are added for you. Nothing else is attached.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(10)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 12)
            Button { Task { await send() } } label: {
                Text(sent ? "Sent. Thank you!" : "Send").frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).tint(Theme.vib500)
            .disabled(sent || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            .padding(.top, 12)
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.over) }
        }
    }

    private func send() async {
        do {
            let _: OK = try await APIClient().post("report-problem", body: ["text": text, "app_version": AppInfo.version])
            sent = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LegalView: View {
    var body: some View {
        PageScroll(title: "Legal") {
            TextBlock(title: "Not financial advice", text: "One Finance is a class project. Suggestions from the Investor and Advisor agents are for information only and are not financial, investment, tax or legal advice. They can be wrong. They follow the risk comfort and time horizon you set in Profile, but they don't know your whole situation. The app can't trade or move money.")
            TextBlock(title: "Privacy", text: "Your data stays in this app's own database on the backend. Bank and brokerage sign-in happens at Plaid and SnapTrade; the app only gets read-only data. AI prompts never include passwords, full account numbers or API keys (see What the AI sees). Delete all my data removes everything.")
            TextBlock(title: "Data sources", text: "US banks: Plaid (sandbox). Brokerage: SnapTrade (sandbox). Company filings: SEC EDGAR. Indonesian banks: your monthly statements. Exchange rate: a fixed rate for the sample data.")
        }
    }
}

struct TextBlock: View {
    let title: String
    let text: String

    var body: some View {
        MoreGroup(title: title) {
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.cardText).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A pushed page in the More tab's style.
struct PageScroll<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 180)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

struct MonthEndSheet: View {
    @Binding var month: String
    let onRun: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Accountant reads receipts and statements for the month, cross-checks them against the bank, and flags problems for Review in Wallet.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                HStack {
                    Text("Month").foregroundStyle(Theme.text)
                    Spacer()
                    MonthMenu(months: ["2026-10", "2026-09", "2026-08", "2026-07"], selected: $month)
                }
                Button(action: onRun) {
                    Text("Run month-end check").frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).tint(Theme.vib500)
                Spacer()
            }
            .padding(20)
            .background(Theme.onyx900)
            .navigationTitle("Month-end check")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .tint(Theme.vib400)
    }
}

struct ExportSheet: View {
    let url: URL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.fill").font(.system(size: 40)).foregroundStyle(Theme.vib300)
            Text("Your data is ready").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            Text("Every recorded expense, income and transfer, with pockets and amounts in US dollars.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            ShareLink(item: url) {
                Label("Share CSV", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).tint(Theme.vib500)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(Theme.onyx900)
    }
}

/// The render's switch (purple when on). A plain button, so a single tap always flips it.
struct RowSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? Theme.vib500 : Color.white.opacity(0.16))
                .frame(width: 51, height: 31)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// "Label ............ [value ⌃⌄]" inside a More group.
struct LabeledPicker<P: View>: View {
    let label: String
    @ViewBuilder var picker: P

    var body: some View {
        HStack {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.text)
            Spacer()
            picker.labelsHidden().pickerStyle(.menu)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 12) }
    }
}

/// Where the app finds the backend (the Mac running it). The Simulator uses localhost.
struct BackendAddressView: View {
    @State private var address = APIClient.baseURL.absoluteString
    @State private var status: String?

    var body: some View {
        PageScroll(title: "Backend address") {
            Text("The app talks only to the One Finance backend running on your Mac. On an iPhone, use the Mac's name or IP address on the same Wi-Fi, e.g. http://My-Mac.local:8000.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            MoreGroup(title: "Address") {
                TextField("http://My-Mac.local:8000", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)
                    .padding(12)
            }
            HStack {
                Button("Save and test") { Task { await save() } }.buttonStyle(.borderedProminent).tint(Theme.vib500)
                Button("Use localhost") {
                    UserDefaults.standard.removeObject(forKey: APIClient.addressKey)
                    address = APIClient.baseURL.absoluteString
                    status = "Using localhost (Simulator)."
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 12)
            if let status { Text(status).font(.footnote).foregroundStyle(Theme.vib300).padding(.top, 8) }
        }
    }

    private func save() async {
        guard let url = APIClient.normalized(address) else { status = "That doesn't look like an address."; return }
        UserDefaults.standard.set(url.absoluteString, forKey: APIClient.addressKey)
        address = url.absoluteString
        let ok = (try? await APIClient().get("health", as: Health.self))?.ok == true
        status = ok ? "Connected to \(url.host() ?? "")." : "Saved, but the backend didn't answer. Is it running with --host 0.0.0.0, on the same Wi-Fi?"
    }
}
