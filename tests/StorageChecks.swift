import Foundation

enum StorageChecks {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("personal", isDirectory: true)
        let store = CareStorage(directory: folder)
        let other = CareStorage(directory: root.appendingPathComponent("another-install", isDirectory: true))
        let missing = try store.load()
        precondition(missing == nil)
        try store.delete()

        var plan = CarePlan()
        try store.save(plan)
        plan.receive("Вымышленная цель для проверки сохранения")
        try store.save(plan)
        let reopened = CareStorage(directory: folder)
        guard let restored = try reopened.load() else { fatalError("Missing saved profile") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(plan)
        let after = try encoder.encode(restored)
        precondition(before == after)
        let unrelated = try other.load()
        precondition(unrelated == nil)

        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        precondition(files.count == 1)
        let file = files[0]
        let cases: [(Data, CareStorageError)] = [
            (Data("broken".utf8), .corruptProfile),
            (Data(#"{"version":999,"unfamiliarPayload":"future"}"#.utf8), .unsupportedVersion(999))
        ]
        for (bytes, expected) in cases {
            try bytes.write(to: file, options: .atomic)
            do {
                _ = try reopened.load()
                fatalError("An unreadable profile must produce an error")
            } catch let error as CareStorageError {
                precondition(error == expected)
            }
            do {
                try reopened.save(plan)
                fatalError("An unreadable profile must survive a save attempt")
            } catch let error as CareStorageError {
                precondition(error == expected)
            }
            let unchanged = try Data(contentsOf: file)
            precondition(unchanged == bytes)
        }
        try reopened.delete()
        try reopened.delete()
        let deleted = try reopened.load()
        precondition(deleted == nil)
        try reopened.save(plan)
        let fresh = try reopened.load()
        precondition(fresh != nil)
    }
}
