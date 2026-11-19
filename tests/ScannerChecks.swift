import CoreGraphics
import Foundation

enum ScannerChecks {
    enum Failure: Error { case fixture, layout, content, archive, limit }

    private static func sample() throws -> CGImage {
        // Two solid halves let us check page order, rotation and vertical orientation in the final PDF.
        guard let context = CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.fixture }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 600))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 600, width: 2400, height: 600))
        guard let image = context.makeImage() else { throw Failure.fixture }
        return image
    }

    private static func checkFileLimit() throws {
        // Fixed noise resists JPEG compression so a batch can reach the real file limit before 30 pages.
        let edge = 2000
        guard let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                                      bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let words = context.data?.assumingMemoryBound(to: UInt32.self) else { throw Failure.fixture }
        var seed: UInt32 = 42
        for index in 0..<(edge * edge) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            words[index] = seed
        }
        guard let noise = context.makeImage() else { throw Failure.fixture }
        do {
            _ = try CareScanPDF.render(pageCount: CareDocuments.pdfPageLimit) { _ in (noise, .up) }
            throw Failure.limit
        } catch CareDocumentError.tooLarge {}
    }

    private static func verifyPage(_ page: CGPDFPage, size: CGSize, pixels: (Int, Int),
                                   topLeftIsRed: Bool, bottomRightIsRed: Bool) throws {
        let box = page.getBoxRect(.mediaBox)
        guard box.size == size else { throw Failure.layout }
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard let pageDictionary = page.dictionary,
              CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { throw Failure.content }
        var foundDimensions = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var width = 0, height = 0
            if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
               CGPDFDictionaryGetInteger(dictionary, "Height", &height), (width, height) == pixels {
                foundDimensions = true
            }
            return true
        }, nil)
        guard foundDimensions else { throw Failure.layout }
        let width = 40, height = 40, rowBytes = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure.fixture }
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.drawPDFPage(page)
        func matches(x: Int, row: Int, red: Bool) -> Bool {
            let offset = rowBytes * row + x * 4
            return bytes[offset + (red ? 0 : 2)] > 200 && bytes[offset + (red ? 2 : 0)] < 50
        }
        guard matches(x: 8, row: 8, red: topLeftIsRed),
              matches(x: 32, row: 32, red: bottomRightIsRed) else { throw Failure.content }
    }

    static func run() throws {
        let image = try sample()
        for count in [0, CareDocuments.pdfPageLimit + 1] {
            do {
                _ = try CareScanPDF.render(pageCount: count) { _ in throw Failure.limit }
                throw Failure.limit
            } catch CareDocumentError.invalid where count == 0 {
            } catch CareDocumentError.tooManyPages where count > CareDocuments.pdfPageLimit {}
        }
        let bytes = try CareScanPDF.render(pageCount: 2) { index in (image, index == 0 ? .up : .right) }
        guard bytes.starts(with: Data("%PDF-".utf8)), bytes.count <= CareDocuments.pdfLimit,
              let source = CGDataProvider(data: bytes as CFData), let pdf = CGPDFDocument(source),
              pdf.numberOfPages == 2, let first = pdf.page(at: 1), let second = pdf.page(at: 2) else {
            throw Failure.content
        }
        try verifyPage(first, size: CGSize(width: 792, height: 396), pixels: (2200, 1100),
                       topLeftIsRed: false, bottomRightIsRed: true)
        try verifyPage(second, size: CGSize(width: 396, height: 792), pixels: (1100, 2200),
                       topLeftIsRed: true, bottomRightIsRed: false)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = CareDocuments(directory: directory)
        let generation = archive.beginImport()
        let saved = try archive.add(bytes, name: "Скан.pdf", generation: generation)
        guard saved.kind == .pdf, try archive.pageCount(for: saved) == 2,
              try archive.list() == [saved], try Data(contentsOf: archive.originalURL(for: saved)) == bytes else {
            throw Failure.archive
        }
        try archive.deleteAll()
        do {
            _ = try archive.add(bytes, name: "Запоздалый скан.pdf", generation: generation)
            throw Failure.archive
        } catch is CancellationError {}
        guard try archive.list().isEmpty else { throw Failure.archive }
        try checkFileLimit()
    }
}
