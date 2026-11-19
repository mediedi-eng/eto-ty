import Foundation
import ImageIO
import PDFKit
import Vision

/// Returns page-scoped verbatim candidates. Only the user's later confirmation can persist one.
enum CarePageReader {
    enum Failure: Error { case unavailable, unsupportedLanguage }
    private static let resolution = 2200
    private static let candidateLimit = 75

    static func candidates(url: URL, kind: CareDocumentKind, page: Int) throws -> [String] {
        try candidates(url: url, kind: kind, page: page, readImage: recognize)
    }

    static func candidates(url: URL, kind: CareDocumentKind, page: Int,
                           readImage: (CGImage) throws -> String) throws -> [String] {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0 else { throw Failure.unavailable }
        let image: CGImage
        switch kind {
        case .pdf:
            guard size <= 20_000_000, let document = PDFDocument(url: url), !document.isEncrypted,
                  (1...30).contains(document.pageCount), (1...document.pageCount).contains(page),
                  let selected = document.page(at: page - 1) else { throw Failure.unavailable }
            if let text = selected.string {
                let lines = excerpts(from: text)
                if !lines.isEmpty { return lines }
            }
            guard let source = selected.pageRef else { throw Failure.unavailable }
            image = try render(source)
        case .jpeg, .png, .heic:
            guard page == 1, size <= 10_000_000, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw Failure.unavailable
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: resolution]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw Failure.unavailable
            }
            image = thumbnail
        }
        return excerpts(from: try readImage(image))
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Retain literal numbers, units, spellings and abbreviations from the clinical original.
        request.usesLanguageCorrection = false
        let available = try request.supportedRecognitionLanguages()
        let languages = ["ru", "en"].compactMap { prefix in
            available.first { $0.components(separatedBy: "-").first == prefix }
        }
        guard !languages.isEmpty else { throw Failure.unsupportedLanguage }
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func render(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox).standardized
        let quarterTurn = abs(page.rotationAngle % 180) == 90
        let width = quarterTurn ? box.height : box.width
        let height = quarterTurn ? box.width : box.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw Failure.unavailable }
        let longest = max(width, height)
        let pixelsWide = max(1, Int((width / longest * CGFloat(resolution)).rounded()))
        let pixelsHigh = max(1, Int((height / longest * CGFloat(resolution)).rounded()))
        guard let bitmap = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.unavailable
        }
        let bounds = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(bounds)
        bitmap.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        bitmap.drawPDFPage(page)
        guard let image = bitmap.makeImage() else { throw Failure.unavailable }
        return image
    }

    private static func excerpts(from text: String) -> [String] {
        var result = [String]()
        text.enumerateLines { line, stop in
            var remainder = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            while !remainder.isEmpty && result.count < candidateLimit {
                let prefix = remainder.prefix(1000)
                if let end = prefix.lastIndex(where: { $0.isWhitespace }), prefix.endIndex != remainder.endIndex,
                   end > prefix.startIndex {
                    result.append(String(remainder[..<end]))
                    remainder = remainder[remainder.index(after: end)...]
                } else {
                    result.append(String(prefix))
                    remainder = remainder.dropFirst(prefix.count)
                }
            }
            stop = result.count == candidateLimit
        }
        return result
    }
}
