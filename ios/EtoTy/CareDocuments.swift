import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CareDocumentError: LocalizedError {
    case invalid, unsupported, password, tooLarge, tooManyPages, imageDimensions, unavailable, invalidCitation, changed

    var errorDescription: String? {
        switch self {
        case .invalid: return "Не удалось прочитать документ. Попробуй открыть оригинал и выбрать его заново."
        case .unsupported: return "Подойдут PDF, JPEG, PNG и HEIC."
        case .password: return "Этот PDF защищён паролем. Для просмотра здесь нужна копия без пароля."
        case .tooLarge: return "PDF должен быть до 20 МБ, фото — до 10 МБ."
        case .tooManyPages: return "В одном PDF можно сохранить до 30 страниц."
        case .imageDimensions: return "Размер одного изображения ограничен 30 мегапикселями."
        case .changed: return "Запись изменилась. Сверь актуальный источник и выбери область ещё раз."
        case .invalidCitation: return "Проверь страницу в оригинале. Цитата должна содержать не больше 1000 символов."
        case .unavailable: return "Не удалось открыть сохранённый материал."
        }
    }
}

struct CareDocuments {
    private struct Metadata: Codable {
        var name: String
        var kind: CareDocumentKind
        var imported: Date
        var regionName: String?
        var evidence: CareDocumentEvidence?
    }

    // A document and its metadata become visible together when their directory is renamed.
    private static let fileLock = NSLock()
    private static var generations: [URL: UInt64] = [:]
    private let directory: URL
    private let files = FileManager.default
    static let pdfLimit = 20_000_000
    static let pdfPageLimit = 30
    private static let imageLimit = 10_000_000

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("CareDocuments", isDirectory: true)
    }

    func list() throws -> [CareDocument] {
        try Self.fileLock.withLock {
            let entries: [URL]
            do { entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch where Self.isMissing(error) { return [] }
            var documents = [CareDocument]()
            for entry in entries {
                let id = entry.lastPathComponent
                if id.hasPrefix(".import-") { try files.removeItem(at: entry); continue }
                guard Self.validID(id) else { continue }
                documents.append(try read(id))
            }
            return documents.sorted { $0.imported == $1.imported ? $0.id < $1.id : $0.imported > $1.imported }
        }
    }

    static func loadSelectedFile(_ url: URL) throws -> Data {
        guard url.startAccessingSecurityScopedResource() else { return try boundedRead(url) }
        defer { url.stopAccessingSecurityScopedResource() }
        return try coordinatedRead(url)
    }

    static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try boundedRead(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CareDocumentError.invalid }
        return try result.get()
    }

    static func boundedRead(_ url: URL) throws -> Data {
        try boundedRead(url, matching: nil)
    }

    // Check the opened descriptor so a replaced path cannot change the file after validation.
    static func boundedRead(_ url: URL, matching identity: (dev_t, ino_t)?) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CareDocumentError.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CareDocumentError.invalid }
        if let identity, (info.st_dev, info.st_ino) != identity { throw CareDocumentError.unavailable }
        guard info.st_size <= pdfLimit else { throw CareDocumentError.tooLarge }
        var data = Data()
        while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
            guard chunk.count <= pdfLimit - data.count else { throw CareDocumentError.tooLarge }
            data.append(chunk)
        }
        return data
    }

    // The picker may still be loading while the owner deletes the personal profile.
    func beginImport() -> UInt64 {
        Self.fileLock.withLock { Self.generations[directory, default: 0] }
    }

    func add(_ data: Data, name: String, now: Date = Date(), generation: UInt64? = nil) throws -> CareDocument {
        let initialGeneration = generation ?? beginImport()
        let kind = try Self.validate(data)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let picked = (name as NSString).lastPathComponent.components(separatedBy: .controlCharacters)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = picked.isEmpty ? "Документ." + kind.rawValue : String(picked.prefix(160))
        let metadata = Metadata(name: displayName, kind: kind, imported: now)
        return try Self.fileLock.withLock {
            guard initialGeneration == Self.generations[directory, default: 0] else { throw CancellationError() }
            try createProtectedDirectory(directory)
            let destination = directory.appendingPathComponent(id, isDirectory: true)
            if files.fileExists(atPath: destination.path) { return try read(id) }
            let staging = directory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
            try createProtectedDirectory(staging)
            defer { if files.fileExists(atPath: staging.path) { try? files.removeItem(at: staging) } }
            try data.write(to: original(kind, in: staging), options: writeOptions)
            try write(metadata, in: staging)
            try files.moveItem(at: staging, to: destination)
            return CareDocument(id: id, name: displayName, kind: kind, imported: now, region: nil)
        }
    }

    func originalURL(for document: CareDocument) throws -> URL {
        try Self.fileLock.withLock {
            let stored = try read(document.id)
            let url = original(stored.kind, in: directory.appendingPathComponent(stored.id))
            guard files.isReadableFile(atPath: url.path) else { throw CareDocumentError.unavailable }
            return url
        }
    }

    func pageCount(for document: CareDocument) throws -> Int {
        let url = try originalURL(for: document)
        return try Self.pageCount(kind: document.kind, url: url)
    }

    private static func pageCount(kind: CareDocumentKind, url: URL) throws -> Int {
        guard kind == .pdf else { return 1 }
        guard let pdf = CGPDFDocument(url as CFURL) else { throw CareDocumentError.unavailable }
        return pdf.numberOfPages
    }

    func assign(_ region: Region?, to id: String, ifUnchanged expected: CareDocument? = nil) throws {
        try Self.fileLock.withLock {
            let document = try read(id)
            if let expected, expected != document { throw CareDocumentError.changed }
            let metadata = Metadata(name: document.name, kind: document.kind, imported: document.imported,
                                    regionName: region?.rawValue, evidence: document.evidence)
            try write(metadata, in: directory.appendingPathComponent(id))
        }
    }

    func annotate(_ id: String, studyDate: Date?, page: Int, quote: String) throws {
        try Self.fileLock.withLock {
            let document = try read(id)
            let folder = directory.appendingPathComponent(id)
            let text = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 1000 else { throw CareDocumentError.invalidCitation }
            if !text.isEmpty {
                let count = try Self.pageCount(kind: document.kind, url: original(document.kind, in: folder))
                guard page > 0 && page <= count else { throw CareDocumentError.invalidCitation }
            }
            let date = studyDate.map { CareDocumentEvidence.dateFormatter().string(from: $0) }
            let evidence: CareDocumentEvidence? = text.isEmpty && date == nil ? nil :
                CareDocumentEvidence(studyDate: date, page: text.isEmpty ? nil : page, quote: text.isEmpty ? nil : text)
            try write(Metadata(name: document.name, kind: document.kind, imported: document.imported,
                               regionName: document.region?.rawValue, evidence: evidence), in: folder)
        }
    }

    func remove(_ id: String) throws {
        guard Self.validID(id) else { throw CareDocumentError.unavailable }
        try Self.fileLock.withLock {
            do { try files.removeItem(at: directory.appendingPathComponent(id)) }
            catch where Self.isMissing(error) { return }
        }
    }

    func deleteAll() throws {
        try Self.fileLock.withLock {
            do { try files.removeItem(at: directory) }
            catch where Self.isMissing(error) {}
            Self.generations[directory, default: 0] &+= 1
        }
    }

    private func read(_ id: String) throws -> CareDocument {
        guard Self.validID(id) else { throw CareDocumentError.unavailable }
        let url = directory.appendingPathComponent(id).appendingPathComponent("record.json")
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
        return CareDocument(id: id, name: metadata.name, kind: metadata.kind, imported: metadata.imported,
                            region: metadata.regionName.flatMap(Region.init(rawValue:)), evidence: metadata.evidence)
    }

    private func write(_ metadata: Metadata, in location: URL) throws {
        try JSONEncoder().encode(metadata).write(to: location.appendingPathComponent("record.json"), options: writeOptions)
    }

    private func original(_ kind: CareDocumentKind, in folder: URL) -> URL {
        folder.appendingPathComponent("original." + kind.rawValue)
    }

    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }

    private func createProtectedDirectory(_ location: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try files.createDirectory(at: location, withIntermediateDirectories: true, attributes: attributes)
        var url = location
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try url.setResourceValues(properties)
    }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code)
    }

    private static func validate(_ data: Data) throws -> CareDocumentKind {
        guard !data.isEmpty else { throw CareDocumentError.invalid }
        guard data.count <= pdfLimit else { throw CareDocumentError.tooLarge }
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let source = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(source) else {
                throw CareDocumentError.invalid
            }
            guard !pdf.isEncrypted else { throw CareDocumentError.password }
            guard pdf.numberOfPages > 0 else { throw CareDocumentError.invalid }
            guard pdf.numberOfPages <= pdfPageLimit else { throw CareDocumentError.tooManyPages }
            for page in 1...pdf.numberOfPages where pdf.page(at: page) == nil { throw CareDocumentError.invalid }
            return .pdf
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) else {
            throw CareDocumentError.unsupported
        }
        let kind: CareDocumentKind
        if type.conforms(to: .jpeg) { kind = .jpeg }
        else if type.conforms(to: .png) { kind = .png }
        else if type.conforms(to: .heic) || type.conforms(to: .heif) { kind = .heic }
        else { throw CareDocumentError.unsupported }
        guard data.count <= imageLimit else { throw CareDocumentError.tooLarge }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw CareDocumentError.invalid
        }
        guard width <= 30_000_000 / height else { throw CareDocumentError.imageDimensions }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 64]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw CareDocumentError.invalid }
        return kind
    }
}
