import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum DocumentChecks {
    enum Failure: Error { case expectedFailure, fixture, invariant }

    private static func expectRejection(_ action: () throws -> Void) throws {
        do { try action() }
        catch is CareDocumentError { return }
        throw Failure.expectedFailure
    }

    private static func image(_ type: UTType) throws -> Data {
        let imageData = NSMutableData()
        guard let context = CGContext(data: nil, width: 12, height: 10, bitsPerComponent: 8,
                                      bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let sample = context.makeImage(),
              let target = CGImageDestinationCreateWithData(imageData, type.identifier as CFString, 1, nil) else {
            throw Failure.fixture
        }
        CGImageDestinationAddImage(target, sample, nil)
        guard CGImageDestinationFinalize(target) else { throw Failure.fixture }
        return imageData as Data
    }

    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("eto-ty-doc-check-" + UUID().uuidString)
        let store = CareDocuments(directory: root.appendingPathComponent("archive"))
        defer { try? fm.removeItem(at: root) }
        try store.deleteAll()
        guard try store.list().isEmpty else { throw Failure.invariant }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = try VisitPDF.render("Вымышленная одностраничная проверка.")
        let source = root.appendingPathComponent("fixture.pdf")
        try pdf.write(to: source)
        let loaded = try CareDocuments.loadSelectedFile(source)
        let first = try store.add(loaded, name: "../отчёт.pdf", now: Date(timeIntervalSince1970: 100))
        let duplicate = try store.add(pdf, name: "другое имя.pdf")
        guard first == duplicate, first.name == "отчёт.pdf", first.region == nil,
              try Data(contentsOf: store.originalURL(for: first)) == pdf else { throw Failure.invariant }
        try store.assign(.heart, to: first.id)
        let date = CareDocumentEvidence.dateFormatter().date(from: "2025-02-04")!
        try store.annotate(first.id, studyDate: date, page: 1, quote: "  Вымышленная одностраничная проверка. ")
        try expectRejection { try store.annotate(first.id, studyDate: nil, page: 2, quote: "Фрагмент") }
        try expectRejection { try store.annotate(first.id, studyDate: nil, page: 1, quote: String(repeating: "a", count: 1001)) }
        try expectRejection { _ = try store.add(Data("invalid".utf8), name: "fake.pdf") }
        try expectRejection { _ = try store.add(Data("%PDF-broken".utf8), name: "broken.pdf") }
        let passwords = [PDFDocumentWriteOption.userPasswordOption: "sample-only", .ownerPasswordOption: "fixture-owner"]
        guard let protectedPDF = PDFDocument(data: pdf)?.dataRepresentation(options: passwords) else { throw Failure.fixture }
        try expectRejection { _ = try store.add(protectedPDF, name: "protected.pdf") }
        let manyPages = PDFDocument()
        for index in 0..<31 {
            guard let blank = PDFDocument(data: pdf)?.page(at: 0) else { throw Failure.fixture }
            manyPages.insert(blank, at: index)
        }
        guard let longPDF = manyPages.dataRepresentation() else { throw Failure.fixture }
        try expectRejection { _ = try store.add(longPDF, name: "too-many-pages.pdf") }
        guard try store.pageCount(for: first) == 1 else { throw Failure.invariant }
        try expectRejection { _ = try store.add(Data(count: 20_000_001), name: "large.png") }
        try expectRejection { try store.remove("../") }
        let fresh = CareDocuments(directory: root.appendingPathComponent("archive"))
        guard let linked = try fresh.list().first, linked.region == .heart,
              linked.evidence?.studyDate == "2025-02-04", linked.evidence?.page == 1,
              linked.evidence?.quote == "Вымышленная одностраничная проверка." else { throw Failure.invariant }
        try fresh.assign(nil, to: linked.id)
        guard try fresh.list().first?.evidence == linked.evidence else { throw Failure.invariant }
        try fresh.annotate(linked.id, studyDate: nil, page: 1, quote: "")
        guard try fresh.list().first?.evidence == nil else { throw Failure.invariant }
        let jpeg = try store.add(image(.jpeg), name: "photo")
        let png = try store.add(image(.png), name: "file.jpg")
        guard jpeg.kind == .jpeg, png.kind == .png, try store.list().count == 3 else { throw Failure.invariant }
        let path = try store.originalURL(for: first)
        try store.remove(first.id)
        try store.remove(first.id)
        guard !fm.fileExists(atPath: path.path), try store.list().count == 2,
              try Data(contentsOf: source) == pdf else { throw Failure.invariant }
        let pending = store.beginImport()
        try store.deleteAll()
        do {
            _ = try fresh.add(pdf, name: "pending.pdf", generation: pending)
            throw Failure.expectedFailure
        } catch is CancellationError {}
        try store.deleteAll()
        guard try store.list().isEmpty, fm.fileExists(atPath: source.path) else { throw Failure.invariant }
    }
}
