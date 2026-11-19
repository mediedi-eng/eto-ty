import Foundation

@main
struct SprintChecks {
    @MainActor
    static func main() async throws {
        try CareChecks.run()
        try StorageChecks.run()
        try DocumentChecks.run()
        try DocumentFollowUpChecks.run()
        try WeeklyCheckInChecks.run()
        try HistoryQueryChecks.run()
        try ScannerChecks.run()
        try PageReaderChecks.run()
        try PersonalBriefChecks.run()
        try await SessionChecks.run()
        print("Verified personal conversations, local storage, document intake, page reading, visit summaries and scheduled follow-up.")
    }
}
