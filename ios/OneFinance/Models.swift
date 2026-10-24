import Foundation

// MARK: - /home

struct HomeData: Decodable {
    let month: String
    let today: String
    let balance: BalanceInfo
    let summary: Summary
    let budget: BudgetStatus
    let cashflow: Cashflow
    let savings: [SavingsPocket]
    let cashCheck: CashCheck
    let nextSteps: [NextStep]
    let nextStepsBy: String
    let openReviewItems: Int
    let months: [String]
}

struct BalanceInfo: Decodable {
    let total: Double
    let change: Double
    let changePct: Double
    let accounts: Int
    let institutions: Int
}

struct Summary: Decodable {
    let spent: Double
    let budget: Double
    let left: Double
    let spendPerDayLast7Days: Double
    let insight: String?
    let pctUsed: Double
    let pctExpected: Double
}

struct BudgetStatus: Decodable {
    let month: String
    let daysInMonth: Int
    let daysElapsed: Int
    let daysToGo: Int
    let totalBudget: Double
    let totalSpent: Double
    let totalLeft: Double
    let pctUsed: Double
    let pctExpected: Double
    let pockets: [BudgetPocket]
}

struct BudgetPocket: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let budget: Double
    let rollover: Double
    let moved: Double
    let available: Double
    let spent: Double
    let left: Double
    let pctUsed: Double?
    let over: Bool
    let paid: Bool
    let usual: Double?
}

struct Cashflow: Decodable {
    let month: String
    let income: [Inflow]
    let outflows: [Outflow]
    let totalIn: Double
    let totalOut: Double
    let spent: Double
}

struct Inflow: Decodable {
    let source: String
    let amount: Double
}

struct Outflow: Decodable {
    let to: String
    let amount: Double
    let pct: Double
}

/// A savings or investing pocket: a label on the money, not tied to any account.
struct SavingsPocket: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let kind: String
    let custom: Bool
    let total: Double
    let monthlyAmount: Double?
    let thisMonth: Double
    let goal: Double?
    let goalDate: String?
    let pctOfGoal: Double?
}

struct CashCheck: Decodable {
    let cashUs: Double
    let cashIndonesia: Double
    let owedOnCards: Double
    let allMoney: Double
    let spendingLeft: Double
    let savingsAndInvesting: Double
    let unassigned: Double
    let pocketsPlusUnassigned: Double
    let balanced: Bool
}

// MARK: - /wallet

struct WalletData: Decodable {
    let month: String
    let balance: BalanceInfo
    let institutions: [Institution]
    let debts: [Debt]
    let spending: BudgetStatus
    let savings: [SavingsPocket]
    let cashCheck: CashCheck
    let moves: [PocketMove]
    let openReviewItems: Int
}

struct Institution: Decodable, Identifiable {
    var id: String { institution }
    let institution: String
    let kind: String
    let country: String
    let accounts: [InstitutionAccount]
    let totalUsd: Double
    let totalLocal: Double
    let currency: String
}

struct InstitutionAccount: Decodable {
    let name: String
    let subtype: String?
    let mask: String?
}

struct Debt: Decodable, Identifiable {
    let id: String
    let institution: String
    let name: String
    let officialName: String?
    let mask: String?
    let owed: Double
    let limit: Double?
    let pctOfLimit: Double?
    let nextAutopay: String?
}

struct PocketMove: Decodable, Identifiable {
    let id: Int
    let date: String
    let amount: Double
    let note: String?
    let createdBy: String
    let undone: Int
    let fromPocket: String?
    let toPocket: String?
}

struct NextStep: Decodable, Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let action: String
}

// MARK: - Other routes

struct BalanceHistory: Decodable {
    let points: [BalancePoint]
    let syntheticBefore: String?
}

struct BalancePoint: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let total: Double

    var day: Date { DateParse.day(date) }
}

struct ReviewList: Decodable { let items: [ReviewItem] }

struct ReviewItem: Decodable, Identifiable {
    let id: Int
    let kind: String
    let month: String?
    let amount: Double?
    let detail: String
    let status: String
    let pocket: String?
}

struct NotificationList: Decodable { let items: [AppNotification] }

struct AppNotification: Decodable, Identifiable {
    let id: Int
    let kind: String
    let title: String
    let body: String
    let createdAt: String
}

struct RunList: Decodable { let runs: [RunSummary] }

struct RunSummary: Decodable, Identifiable {
    var id: String { runId }
    let runId: String
    let started: String
    let agents: String?
    let modelCalls: Int?
    let toolCalls: Int?
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
}

struct RunDetail: Decodable { let runId: String; let steps: [RunStep] }

struct RunStep: Decodable, Identifiable {
    var id: Int { step }
    let step: Int
    let agent: String
    let chain: String?
    let stepType: String
    let tool: String?
    let text: String?
    let inputTokens: Int?
    let cachedTokens: Int?
    let outputTokens: Int?
}

struct EventList: Decodable { let events: [AgentEvent] }

struct AgentEvent: Decodable, Identifiable {
    let id: Int
    let runId: String
    let agent: String
    let chain: String?
    let stepType: String
    let tool: String?
}

struct ChatReply: Decodable {
    let runId: String
    let answer: String
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
}

struct AgentRunResult: Decodable {
    let runId: String
    let modelCalls: Int?
    let toolCalls: Int?
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
}

struct DigestResult: Decodable {
    let runId: String
    let digest: Digest?
    let inputTokens: Int
    let outputTokens: Int

    struct Digest: Decodable {
        let spendingTitle: String
        let spendingBody: String
        let investmentTitle: String
        let investmentBody: String
    }
}

struct PortfolioResponse: Decodable {
    let snapshot: Portfolio
    let latestBrief: PortfolioBrief?
}

struct Portfolio: Decodable {
    let account: String?
    let totalValue: Double
    let cash: Double
    let cashPct: Double
    let holdings: [Holding]
    let sectorSharesPct: [String: Double]
    let maxSectorSharePct: Double
}

struct Holding: Decodable, Identifiable {
    var id: String { symbol }
    let symbol: String
    let name: String?
    let quantity: Double
    let price: Double
    let value: Double
    let weightPct: Double
    let gainPct: Double?
    let sector: String
}

struct PortfolioBrief: Decodable {
    let asOf: String
    let holdings: [BriefHolding]
    let concentration: [String]
    let risks: [String]
    let sources: [String]

    struct BriefHolding: Decodable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let keyNumbers: String
        let note: String
    }
}

struct TransactionList: Decodable { let transactions: [Txn] }

struct Txn: Decodable, Identifiable {
    let id: String
    let date: String
    let description: String
    let merchantName: String?
    let amount: Double
    let currency: String
    let account: String
    let mask: String?
    let pocket: String?
}

struct PocketList: Decodable {
    let pockets: [PocketInfo]
    let catalog: [PocketInfo]
    struct PocketInfo: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let kind: String
        let monthlyBudget: Double?
        let goalAmount: Double?
        let goalDate: String?
        let custom: Int
        let description: String?
    }
}

struct BudgetSuggestionResult: Decodable {
    let runId: String
    let suggestion: Suggestion?
    struct Suggestion: Decodable {
        let suggestions: [Item]
        let note: String
    }
    struct Item: Decodable, Identifiable {
        var id: String { pocket }
        let pocket: String
        let monthlyAmount: Double
        let reason: String
    }
}

enum DateParse {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func day(_ s: String) -> Date { formatter.date(from: String(s.prefix(10))) ?? .distantPast }

    static func monthLabel(_ ym: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: day(ym + "-01"))
    }

    static func shortDay(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: day(s))
    }
}
