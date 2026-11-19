import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PageReaderChecks {
    private enum Failure: Error { case fixture, invariant }

    private static func picture() throws -> CGImage {
        guard let canvas = CGContext(data: nil, width: 900, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.fixture }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: 900, height: 180))
        canvas.textPosition = CGPoint(x: 24, y: 60)
        let options: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let label = NSAttributedString(string: "SAMPLE CHECK 12345", attributes: options)
        CTLineDraw(CTLineCreateWithAttributedString(label), canvas)
        guard let image = canvas.makeImage() else { throw Failure.fixture }
        return image
    }

    private static func scan(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 900, height: 180)
        guard let consumer = CGDataConsumer(data: data),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.fixture }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return data as Data
    }

    static func run() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("eto-ty-reader-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let archive = CareDocuments(directory: folder.appendingPathComponent("archive"))
        let fixture = PDFDocument()
        for (i, line) in ["Первая страница.", "Вторая страница."].enumerated() {
            guard let page = PDFDocument(data: try VisitPDF.render(line))?.page(at: 0) else { throw Failure.fixture }
            fixture.insert(page, at: i)
        }
        guard let textPDF = fixture.dataRepresentation() else { throw Failure.fixture }
        let stored = try archive.add(textPDF, name: "пример.pdf")
        let source = try archive.originalURL(for: stored)
        let lines = try CarePageReader.candidates(url: source, kind: .pdf, page: 2) { _ in throw Failure.invariant }
        guard lines.joined().contains("Вторая"), !lines.joined().contains("Первая"), !lines.isEmpty,
              try archive.list().first?.evidence == nil else { throw Failure.invariant }
        do {
            _ = try CarePageReader.candidates(url: source, kind: .pdf, page: 3)
            throw Failure.invariant
        } catch is CarePageReader.Failure {}
        try archive.annotate(stored.id, studyDate: nil, page: 2, quote: lines[0])
        guard try archive.list().first?.evidence?.page == 2 else { throw Failure.invariant }

        let image = try picture()
        let png = folder.appendingPathComponent("fixture.png")
        guard let target = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.fixture }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw Failure.fixture }
        let scannedPDF = folder.appendingPathComponent("scanned.pdf")
        try scan(image).write(to: scannedPDF)
        for (file, kind) in [(png, CareDocumentKind.png), (scannedPDF, .pdf)] {
            let candidate = try CarePageReader.candidates(url: file, kind: kind, page: 1) { pageImage in
                guard pageImage.width > pageImage.height, max(pageImage.width, pageImage.height) <= 2200
                else { throw Failure.invariant }
                return "source 12345\n\n   \n" + String(repeating: "a", count: 1100)
            }
            guard candidate.first == "source 12345", candidate.allSatisfy({ !$0.isEmpty && $0.count <= 1000 })
            else { throw Failure.invariant }
            if ProcessInfo.processInfo.environment["ETO_TY_CHECK_DEVICE_OCR"] == "1" {
                let actual = try CarePageReader.candidates(url: file, kind: kind, page: 1)
                guard actual.joined().contains("12345") else { throw Failure.invariant }
            }
        }
    }
}
