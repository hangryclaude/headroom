import Foundation

/// One reading per account, as the policy sees it.
struct AccountReading: Equatable {
    let name: String
    let label: String
    /// 5-hour utilization.
    let p5: Int
    /// 7-day utilization.
    let p7: Int
    let ok: Bool
    /// Why this account is unusable, in the policy's vocabulary.
    let problem: String?
    let resets5h: Date?

    /// Weighted toward the week on purpose -- see `Policy`.
    var score: Double { Policy.w7 * Double(p7) + Policy.w5 * Double(p5) }

    /// Raw problem codes are not for humans. "stale" in particular means the
    /// access token aged out and will heal itself, which reads as breakage if
    /// shown verbatim -- and sending someone to re-login over it burns a
    /// perfectly good account.
    var humanProblem: String? {
        switch problem {
        case "no-creds":    return "needs login"
        case "stale":       return "token refreshing"
        case "rate-limit":  return "rate limited"
        case .some(let p):  return p
        case nil:           return nil
        }
    }
}

enum Verdict: String, Equatable {
    case stay, swap, rotateSoon, rebalance, allHot, noAccounts

    /// Plain English, because "STAY (target: aa)" is a debug printout, not a UI.
    var headline: String {
        switch self {
        case .stay:        return "All accounts healthy"
        case .swap:        return "Swap now"
        case .rotateSoon:  return "Rotate at your next break"
        case .rebalance:   return "Weekly burn is uneven"
        case .allHot:      return "Every account is hot"
        case .noAccounts:  return "No accounts saved"
        }
    }

    /// Only trouble gets colour. `stay` returning nil is the rule that keeps the
    /// menu bar quiet when nothing is wrong.
    var accentPercent: Int? {
        switch self {
        case .stay, .noAccounts: return nil
        case .rotateSoon, .rebalance: return 75
        case .swap: return 95
        case .allHot: return 88
        }
    }
}

struct Decision: Equatable {
    let verdict: Verdict
    let target: String?
    let why: String
}

/// When to swap Claude accounts, and to which one.
///
/// This policy is ported from an earlier shell implementation rather than
/// reinvented. The reasoning, verbatim from that script:
///
///   The 7-DAY window is the real budget -- it refills once a week and unused
///   capacity is gone forever. The 5-HOUR window is only a throttle. So: drain
///   the WEEKLY budgets EVENLY (never idle two accounts while one locks out),
///   and inside that, respect the 5h throttle.
///
/// Ported rather than shelled out to because the original script cannot run
/// here any more: it depended on files that do not exist on this machine.
/// Shelling out would mean showing "—" forever.
enum Policy {
    /// 5h utilization that forces a swap now.
    static let h5Hard = 80
    /// 5h utilization that starts looking for the exit.
    static let h5Soft = 60
    /// 7d utilization that retires an account for the week, keeping a tail for
    /// emergencies.
    static let d7Reserve = 90
    /// Weekly-burn spread that justifies a rebalance swap.
    static let d7Imbalance = 15
    /// "Genuinely cold" 5h utilization.
    static let cold5h = 25

    static let w7 = 0.75
    static let w5 = 0.25

    /// Accounts with room, best first.
    static func eligible(_ accounts: [AccountReading]) -> [AccountReading] {
        accounts
            .filter { $0.ok && $0.p5 < h5Hard && $0.p7 < d7Reserve }
            .sorted { $0.score < $1.score }
    }

    static func decide(current: AccountReading?, accounts: [AccountReading]) -> Decision {
        guard !accounts.isEmpty else {
            return Decision(verdict: .noAccounts, target: nil, why: "no accounts saved yet")
        }

        let ranked = eligible(accounts)

        guard let current else {
            if let target = ranked.first {
                return Decision(verdict: .swap, target: target.name,
                                why: "not on a known account; \(target.label) has the most room (7d \(target.p7)%)")
            }
            return Decision(verdict: .allHot, target: nil, why: "no account has headroom")
        }

        if !current.ok {
            let problem = current.humanProblem ?? "unavailable"
            if let target = ranked.first(where: { $0.name != current.name }) {
                return Decision(verdict: .swap, target: target.name,
                                why: "\(current.label) \(problem) — \(target.label) is live (7d \(target.p7)%)")
            }
            return Decision(verdict: .allHot, target: nil,
                            why: "\(current.label) \(problem) and nothing else has headroom")
        }

        let best = ranked.first { $0.name != current.name }

        // Weekly exhaustion outranks the 5h throttle: the week is the budget.
        if current.p7 >= d7Reserve {
            if let best {
                return Decision(verdict: .swap, target: best.name,
                                why: "\(current.label) is at \(current.p7)% of its week — keep the tail, move to \(best.label) (7d \(best.p7)%)")
            }
            return Decision(verdict: .allHot, target: nil,
                            why: "\(current.label) is at \(current.p7)% weekly and no other account has room")
        }

        if current.p5 >= h5Hard {
            if let best {
                return Decision(verdict: .swap, target: best.name,
                                why: "\(current.label) 5h window at \(current.p5)% — swap before it locks mid-task; \(best.label) is at \(best.p5)%")
            }
            let resets = current.resets5h.map { " resets in \(Format.countdown($0.timeIntervalSinceNow))" } ?? ""
            return Decision(verdict: .allHot, target: nil,
                            why: "every account is hot;\(resets.isEmpty ? " no room anywhere" : " \(current.label) 5h\(resets)")")
        }

        // Not urgent, but there is somewhere genuinely cold to go. Deliberately
        // advisory: the swap should land at a natural break, not mid-task.
        if current.p5 >= h5Soft, let best, best.p5 <= cold5h, best.score < current.score {
            return Decision(verdict: .rotateSoon, target: best.name,
                            why: "\(current.label) 5h at \(current.p5)% and \(best.label) is cold (5h \(best.p5)%, 7d \(best.p7)%) — swap at your next break, not mid-task")
        }

        if let best, current.p7 - best.p7 > d7Imbalance {
            return Decision(verdict: .rebalance, target: best.name,
                            why: "weekly burn is uneven (\(current.label) \(current.p7)% vs \(best.label) \(best.p7)%) — unused weekly capacity expires, so drain \(best.label) next")
        }

        // No parenthetical restating the percentages: they are already on screen
        // at a larger size, and repeating them is most of what made this line
        // wrap to three lines in a 360pt popover.
        var why = "\(current.label) has room"
        if let best { why += " — \(best.label) is next in line" }
        return Decision(verdict: .stay, target: current.name, why: why)
    }
}
