import XCTest
@testable import ClaudeUsage

final class AccountSelectionTests: XCTestCase {
    private func usage(_ percent: Double) -> UsageData {
        UsageData(sessionUtilization: percent, sessionResetsAt: nil,
                  weeklyUtilization: 0, weeklyResetsAt: nil,
                  sonnetUtilization: nil, sonnetResetsAt: nil, modelLimits: [],
                  extraUsageEnabled: false, extraUsageMonthlyLimit: nil,
                  extraUsageUsedCredits: nil)
    }

    private func profile(_ service: String, account: String? = "account", organization: String = "org",
                         percent: Double? = 1) -> ClaudeProfile {
        ClaudeProfile(service: service, label: "same@example.com",
                      usage: percent.map { usage($0) },
                      error: percent == nil ? "expired" : nil,
                      identity: account.map { ClaudeAccountIdentity(accountID: $0, organizationID: organization) })
    }

    func testDuplicateAccountKeepsSelectedServiceAndStableOrder() {
        let profiles = [profile("preferred"), profile("other", account: "other"), profile("selected")]
        let unique = ClaudeProfileList.unique(profiles, selectedService: "selected")
        XCTAssertEqual(unique.map(\.service), ["selected", "other"])
    }

    func testWorkingDuplicateWinsOverFailedSelectedCredential() {
        let unique = ClaudeProfileList.unique([profile("failed", percent: nil), profile("working")],
                                               selectedService: "failed")
        XCTAssertEqual(unique.map(\.service), ["working"])
    }

    func testSameEmailDifferentAccountsOrOrganizationsAreNotCollapsed() {
        let profiles = [profile("one"), profile("two", account: "different"),
                        profile("three", organization: "different")]
        XCTAssertEqual(ClaudeProfileList.unique(profiles, selectedService: nil).count, 3)
    }

    func testUnresolvedIdentityRemainsVisible() {
        let profiles = [profile("one", account: nil), profile("two", account: nil, percent: nil)]
        XCTAssertEqual(ClaudeProfileList.unique(profiles, selectedService: nil).count, 2)
    }

    func testProfileIdentityRequiresAccountAndOrganizationIDs() {
        let complete = Data(#"{"account":{"uuid":"account","email":"same@example.com"},"organization":{"uuid":"org"}}"#.utf8)
        XCTAssertEqual(ClaudeAccountDetails.parse(complete)?.identity,
                       ClaudeAccountIdentity(accountID: "account", organizationID: "org"))
        let partial = Data(#"{"account":{"uuid":"account","email":"same@example.com"}}"#.utf8)
        XCTAssertNil(ClaudeAccountDetails.parse(partial)?.identity)
        XCTAssertEqual(ClaudeAccountDetails.parse(partial)?.email, "same@example.com")
    }

    @MainActor
    func testMenuBarColourUsesSelectedAccountOnly() async {
        let manager = UsageManager()
        manager.profiles = [profile("low", percent: 1), profile("high", account: "other", percent: 100)]
        manager.usage = usage(1)
        XCTAssertEqual(manager.maxUtilization, 1)
        XCTAssertEqual(manager.statusEmoji, "🟢")
        manager.usage = usage(100)
        XCTAssertEqual(manager.maxUtilization, 100)
        XCTAssertEqual(manager.statusEmoji, "🔴")
        manager.usage = nil
        XCTAssertEqual(manager.maxUtilization, 0)
        XCTAssertEqual(manager.statusEmoji, "❓")
    }
}
