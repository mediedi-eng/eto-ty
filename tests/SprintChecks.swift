import Foundation

@main
struct SprintChecks {
    @MainActor
    static func main() async throws {
        try CareChecks.run()
        try StorageChecks.run()
        try DocumentChecks.run()
        try await SessionChecks.run()
        print("Verified personal conversations, local storage, document handling and scheduled follow-up.")
    }
}
