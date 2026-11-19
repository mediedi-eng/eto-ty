import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CareScanPDF {
    static let maxPixelEdge = 2200
    typealias Page = (image: CGImage, orientation: CGImagePropertyOrientation)

    static func render(pageCount: Int, page: (Int) throws -> Page) throws -> Data {
        guard pageCount > 0 else { throw CareDocumentError.invalid }
        guard pageCount <= CareDocuments.pdfPageLimit else { throw CareDocumentError.tooManyPages }
        let output = NSMutableData()
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output),
              let pdf = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw CareDocumentError.invalid
        }
        var jpegBytes = 0
        do {
            for index in 0..<pageCount {
                try autoreleasepool {
                    let (source, orientation) = try page(index)
                    let jpeg = try compressedPage(source, orientation: orientation)
                    guard jpeg.length <= CareDocuments.pdfLimit - jpegBytes else { throw CareDocumentError.tooLarge }
                    jpegBytes += jpeg.length
                    guard let provider = CGDataProvider(data: jpeg as CFData),
                          let image = CGImage(jpegDataProviderSource: provider, decode: nil,
                                              shouldInterpolate: true, intent: .defaultIntent) else {
                        throw CareDocumentError.invalid
                    }
                    // A consistent physical page length keeps cropped pages readable at normal PDF zoom.
                    let scale = 792.0 / CGFloat(max(image.width, image.height))
                    var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale,
                                     height: CGFloat(image.height) * scale)
                    let bounds = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                    pdf.beginPDFPage([kCGPDFContextMediaBox: bounds] as CFDictionary)
                    pdf.draw(image, in: box)
                    pdf.endPDFPage()
                    guard output.length <= CareDocuments.pdfLimit else { throw CareDocumentError.tooLarge }
                }
            }
        } catch {
            pdf.closePDF()
            throw error
        }
        pdf.closePDF()
        guard output.length <= CareDocuments.pdfLimit else { throw CareDocumentError.tooLarge }
        return output as Data
    }

    private static func compressedPage(_ source: CGImage, orientation: CGImagePropertyOrientation) throws -> NSData {
        let w = CGFloat(source.width), h = CGFloat(source.height)
        guard w > 0, h > 0 else { throw CareDocumentError.invalid }
        // Convert EXIF's display orientation into the bitmap's bottom-left coordinate system.
        let transform: CGAffineTransform
        switch orientation {
        case .up: transform = .identity
        case .upMirrored: transform = .init(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: transform = .init(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: transform = .init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: transform = .init(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: transform = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: transform = .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: transform = .init(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: throw CareDocumentError.invalid
        }
        let original = CGRect(x: 0, y: 0, width: w, height: h)
        let rotated = original.applying(transform)
        let scale = min(1, CGFloat(maxPixelEdge) / max(w, h))
        let width = max(1, Int((rotated.width * scale).rounded()))
        let height = max(1, Int((rotated.height * scale).rounded()))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CareDocumentError.invalid
        }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.interpolationQuality = .high
        bitmap.scaleBy(x: CGFloat(width) / rotated.width, y: CGFloat(height) / rotated.height)
        bitmap.concatenate(transform)
        bitmap.draw(source, in: original)
        let bytes = NSMutableData()
        guard let upright = bitmap.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CareDocumentError.invalid
        }
        CGImageDestinationAddImage(destination, upright,
                                  [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CareDocumentError.invalid }
        return bytes
    }
}

#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

struct CareCameraCapture {
    let scan: VNDocumentCameraScan

    func pdf() throws -> Data {
        try CareScanPDF.render(pageCount: scan.pageCount) { index in
            let page = scan.imageOfPage(at: index)
            guard let image = page.cgImage else { throw CareDocumentError.invalid }
            let orientation: CGImagePropertyOrientation
            switch page.imageOrientation {
            case .up: orientation = .up
            case .upMirrored: orientation = .upMirrored
            case .down: orientation = .down
            case .downMirrored: orientation = .downMirrored
            case .left: orientation = .left
            case .leftMirrored: orientation = .leftMirrored
            case .right: orientation = .right
            case .rightMirrored: orientation = .rightMirrored
            @unknown default: throw CareDocumentError.invalid
            }
            return (image, orientation)
        }
    }
}

struct CareDocumentScanner: UIViewControllerRepresentable {
    enum Outcome {
        case captured(CareCameraCapture), cancelled, failed
    }
    let finish: (Outcome) -> Void

    // Only invoked after the user taps the scan action.
    static func accessMessage() async -> String? {
        guard VNDocumentCameraViewController.isSupported else {
            return "Сканер недоступен на этом устройстве. Можно выбрать фото или файл."
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        return allowed ? nil : "Нет доступа к камере. Выбери фото или файл. Доступ можно изменить в настройках iPhone."
    }

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let finish: (Outcome) -> Void
        init(finish: @escaping (Outcome) -> Void) { self.finish = finish }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            finish(.captured(CareCameraCapture(scan: scan)))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { finish(.cancelled) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            finish(.failed)
        }
    }
}
#endif
