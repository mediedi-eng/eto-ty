import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum SourceCitationJourneyChecks {
    private enum Failure: Error { case fixture, invariant }

    static func run() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("eto-ty-citation-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let archive = CareDocuments(directory: root.appendingPathComponent("archive"))

        let pdf = try archive.add(twoPagePDF(), name: "Вымышленное обследование.pdf",
                                  now: Date(timeIntervalSince1970: 1_760_000_000))
        let pdfURL = try archive.originalURL(for: pdf)
        let pdfCandidates = try CarePageReader.candidates(url: pdfURL, kind: .pdf, page: 2)
        guard let kidneyQuote = pdfCandidates.first(where: { $0.contains("УЗИ почек") }),
              let studyDate = CareDocumentEvidence.dateFormatter().date(from: "2026-02-10")
        else { throw Failure.fixture }
        try archive.annotate(pdf.id, studyDate: studyDate, page: 2, quote: kidneyQuote)
        try acceptSuggestedRegion(for: pdf.id, in: archive)

        let photo = try archive.add(png(), name: "Вымышленное фото.png",
                                    now: Date(timeIntervalSince1970: 1_760_000_100))
        let photoURL = try archive.originalURL(for: photo)
        let photoCandidates = try CarePageReader.candidates(url: photoURL, kind: .png, page: 1) { image in
            guard image.width == 32, image.height == 32 else { throw Failure.fixture }
            return "УЗИ сердца"
        }
        guard photoCandidates == ["УЗИ сердца"] else { throw Failure.invariant }
        try archive.annotate(photo.id, studyDate: nil, page: 1, quote: photoCandidates[0])
        try acceptSuggestedRegion(for: photo.id, in: archive)

        let documents = try archive.list()
        guard documents.count == 2,
              let kidney = documents.first(where: { $0.id == pdf.id }), kidney.region == .kidneys,
              kidney.evidence?.page == 2, kidney.evidence?.quote == kidneyQuote,
              let heart = documents.first(where: { $0.id == photo.id }), heart.region == .heart,
              heart.evidence?.page == 1, heart.evidence?.quote == "УЗИ сердца",
              CareMapRegion(.kidneys, documents: documents).documents == [kidney],
              CareMapRegion(.heart, documents: documents).documents == [heart]
        else { throw Failure.invariant }

        let selected = BriefDocumentSelection.chosen(in: documents, selected: [pdf.id, photo.id])
        let brief = PersonalBrief.text(plan: CarePlan(), documents: selected,
                                       includeTopic: false, includeAnswer: false)
        guard let exported = PDFDocument(data: try VisitPDF.render(brief))?.string else { throw Failure.fixture }
        for text in [brief, exported] {
            guard text.contains(pdf.name), text.contains(photo.name),
                  text.contains("УЗИ почек"), text.contains("УЗИ сердца"),
                  text.contains("стр. 2"), text.contains("стр. 1"),
                  text.contains("подтверждённый пользователем")
            else { throw Failure.invariant }
        }
    }

    private static func acceptSuggestedRegion(for id: String, in archive: CareDocuments) throws {
        guard let document = try archive.list().first(where: { $0.id == id }),
              let hint = CareRegionSuggestion.hint(name: document.name,
                                                   quote: document.evidence?.quote,
                                                   page: document.evidence?.page),
              hint.quotePage == document.evidence?.page
        else { throw Failure.invariant }
        try archive.assign(hint.region, to: id, ifUnchanged: document)
    }

    private static func twoPagePDF() throws -> Data {
        let document = PDFDocument()
        for (index, text) in ["Вымышленная первая страница", "УЗИ почек"].enumerated() {
            guard let page = PDFDocument(data: try VisitPDF.render(text))?.page(at: 0)
            else { throw Failure.fixture }
            document.insert(page, at: index)
        }
        guard let data = document.dataRepresentation() else { throw Failure.fixture }
        return data
    }

    private static func png() throws -> Data {
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage()
        else { throw Failure.fixture }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw Failure.fixture }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.fixture }
        return data as Data
    }
}
