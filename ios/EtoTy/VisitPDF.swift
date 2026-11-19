import Foundation
import CoreGraphics
import CoreText

enum VisitPDF {
    enum Failure: Error { case context, layout }

    static func render(_ text: String) throws -> Data {
        let output = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: output),
              let pdf = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.context }
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let content = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let setter = CTFramesetterCreateWithAttributedString(content)
        let body = CGPath(rect: bounds.insetBy(dx: 44, dy: 52), transform: nil)
        let length = CFAttributedStringGetLength(content)
        var offset = 0
        repeat {
            pdf.beginPDFPage(nil)
            pdf.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(setter, CFRangeMake(offset, 0), body, nil)
            CTFrameDraw(frame, pdf)
            pdf.endPDFPage()
            let written = CTFrameGetVisibleStringRange(frame).length
            if written == 0 && offset < length { pdf.closePDF(); throw Failure.layout }
            offset += written
        } while offset < length
        pdf.closePDF()
        return output as Data
    }
}
