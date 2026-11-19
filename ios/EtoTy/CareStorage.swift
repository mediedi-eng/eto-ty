import Foundation

enum CareStorageError: LocalizedError, Equatable {
    case corruptProfile
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .corruptProfile:
            return "Не удалось прочитать сохранённый профиль. Исходный файл сохранён."
        case .unsupportedVersion:
            return "Для этой версии профиля нужна другая версия приложения."
        }
    }
}

/// One personal profile in the application's private container.
struct CareStorage {
    private let explicitDirectory: URL?
    private let filename = "personal-profile.json"

    init() { explicitDirectory = nil }
    init(directory: URL) { explicitDirectory = directory }

    private func directory() throws -> URL {
        if let explicitDirectory { return explicitDirectory }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: false)
        return support.appendingPathComponent("EtoTyPersonal", isDirectory: true)
    }

    func load() throws -> CarePlan? {
        let file = try directory().appendingPathComponent(filename)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        do {
            return try JSONDecoder().decode(ProfileFile.self, from: data).plan
        } catch is DecodingError {
            throw CareStorageError.corruptProfile
        }
    }

    func save(_ plan: CarePlan) throws {
        // A failed read (including a locked device) must never become a fresh empty profile.
        _ = try load()
        let data = try JSONEncoder().encode(ProfileFile(plan: plan))
        var folder = try directory()
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        options.insert(.completeFileProtection)
        #endif
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #endif
        try data.write(to: folder.appendingPathComponent(filename), options: options)
    }

    func delete() throws {
        let file = try directory().appendingPathComponent(filename)
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    private struct ProfileFile: Codable {
        static let currentVersion = 1
        let version: Int
        let plan: CarePlan

        init(plan: CarePlan) {
            version = Self.currentVersion
            self.plan = plan
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else { throw CareStorageError.unsupportedVersion(version) }
            plan = try fields.decode(CarePlan.self, forKey: .plan)
        }
    }
}
