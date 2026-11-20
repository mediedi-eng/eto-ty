#if os(iOS)
import SwiftUI
import UIKit

// The synchronized Xcode target discovers the Objective-C implementation without
// a project-specific bridging header. Developers keep their local signing settings.
@objc(ETBodyRendering)
public protocol BodyRendering {
    @objc(renderMesh:length:rgba:regions:width:height:yaw:zoom:selection:)
    static func render(_ mesh: UnsafeRawPointer?, length: Int, rgba: UnsafeMutablePointer<UInt8>?,
                       regions: UnsafeMutablePointer<UInt8>?, width: Int32, height: Int32,
                       yaw: Float, zoom: Float, selection: Int32) -> Int32
}

struct BodyAvatarView: UIViewRepresentable {
    let selection: Region
    let resetToken: Int
    let onPick: (Region) -> Void

    func makeUIView(context: Context) -> AvatarSurface { AvatarSurface() }

    func updateUIView(_ view: AvatarSurface, context: Context) {
        view.onPick = onPick
        view.update(selection: selection, resetToken: resetToken)
    }
}

/// The color image and the organ ID under each pixel are generated from the same triangles.
final class AvatarSurface: UIView, UIGestureRecognizerDelegate {
    var onPick: ((Region) -> Void)?
    private static let renderer = NSClassFromString("ETBodyRenderer") as? BodyRendering.Type
    private static let mesh = Bundle.main.url(forResource: "BodyAvatar", withExtension: "mesh")
        .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
    private var selected = Region.heart
    private var lastReset = 0
    private var yaw: CGFloat = 0
    private var zoom: CGFloat = 1
    private var startYaw: CGFloat = 0
    private var startZoom: CGFloat = 1
    private var moving = false
    private var hitPixels: [UInt8] = []
    private var renderedWidth = 0
    private var renderedHeight = 0

    init() {
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = UIColor(red: 0.05, green: 0.11, blue: 0.17, alpha: 1)
        accessibilityIdentifier = "map.avatar"
        isAccessibilityElement = true
        accessibilityLabel = "Трёхмерная карта тела"
        accessibilityTraits = .image
        accessibilityHint = "Выбери область кнопкой под фигурой или используй действия для изменения ракурса."
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(magnify(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(pick(_:)))
        tap.require(toFail: pan)
        tap.require(toFail: pinch)
        addGestureRecognizer(tap)
        accessibilityCustomActions = [
            action("Повернуть влево") { $0.yaw -= .pi / 6 },
            action("Повернуть вправо") { $0.yaw += .pi / 6 },
            action("Приблизить") { $0.zoom = min(3.2, $0.zoom * 1.5) },
            action("Отдалить") { $0.zoom = max(1, $0.zoom / 1.5) }
        ]
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func action(_ title: String, perform: @escaping (AvatarSurface) -> Void) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: title) { [weak self] _ in
            guard let self else { return false }
            perform(self)
            self.refresh()
            return true
        }
    }

    func update(selection: Region, resetToken: Int) {
        guard selection != selected || resetToken != lastReset else { return }
        selected = selection
        if lastReset != resetToken {
            lastReset = resetToken
            yaw = 0
            zoom = 1
        }
        refresh()
    }

    private func refresh() {
        let angle = (Int((yaw * 180 / .pi).rounded()) % 360 + 360) % 360
        accessibilityValue = "\(selected.rawValue), поворот \(angle)°, масштаб \(Int((zoom * 100).rounded()))%"
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let factor = min(contentScaleFactor, (moving ? 410 : 820) / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * factor).rounded()))
        let height = max(1, Int((bounds.height * factor).rounded()))
        var rgba = Data(count: width * height * 4)
        var ids = [UInt8](repeating: 0, count: width * height)
        let selectionID: Int32
        switch selected { case .heart: selectionID = 1; case .liver: selectionID = 2; case .kidneys: selectionID = 3 }
        let success = Self.mesh?.withUnsafeBytes { (mesh: UnsafeRawBufferPointer) in
            rgba.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                ids.withUnsafeMutableBufferPointer { ids in
                    Self.renderer?.render(mesh.baseAddress, length: mesh.count,
                                          rgba: pixels.bindMemory(to: UInt8.self).baseAddress, regions: ids.baseAddress,
                                          width: Int32(width), height: Int32(height), yaw: Float(yaw),
                                          zoom: Float(zoom), selection: selectionID) ?? 0
                }
            }
        }
        guard success == 1, let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            let message = "Фигура недоступна. Выбери область ниже."
            accessibilityValue = message
            (message as NSString).draw(in: bounds.insetBy(dx: 20, dy: 20), withAttributes: [.foregroundColor: UIColor.white])
            hitPixels = []
            return
        }
        UIImage(cgImage: image).draw(in: bounds)
        hitPixels = ids
        renderedWidth = width
        renderedHeight = height
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard let scroll = other.view as? UIScrollView else { return false }
        return isDescendant(of: scroll)
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { startYaw = yaw }
        yaw = startYaw + gesture.translation(in: self).x / max(1, bounds.width) * 2 * .pi
        moving = gesture.state == .began || gesture.state == .changed
        refresh()
    }

    @objc private func magnify(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { startZoom = zoom }
        zoom = min(3.2, max(1, startZoom * gesture.scale))
        moving = gesture.state == .began || gesture.state == .changed
        refresh()
    }

    @objc private func pick(_ gesture: UITapGestureRecognizer) {
        guard !hitPixels.isEmpty, bounds.width > 0 else { return }
        let point = gesture.location(in: self)
        let scale = CGFloat(renderedWidth) / bounds.width
        let x = Int(point.x * scale)
        let y = Int(point.y / bounds.height * CGFloat(renderedHeight))
        guard (0..<renderedWidth).contains(x), (0..<renderedHeight).contains(y) else { return }
        let radius = Int(16 * scale)
        var nearest = radius * radius + 1
        var selectedID: UInt8 = 0
        for row in max(0, y - radius)...min(renderedHeight - 1, y + radius) {
            for column in max(0, x - radius)...min(renderedWidth - 1, x + radius) {
                let id = hitPixels[row * renderedWidth + column]
                let distance = (column - x) * (column - x) + (row - y) * (row - y)
                if id != 0 && distance < nearest {
                    nearest = distance
                    selectedID = id
                }
            }
        }
        switch selectedID {
        case 1: onPick?(.heart)
        case 2: onPick?(.liver)
        case 3: onPick?(.kidneys)
        default: break
        }
    }
}
#endif
