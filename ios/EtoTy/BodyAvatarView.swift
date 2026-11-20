#if os(iOS)
import SwiftUI
import SceneKit
import UIKit

struct BodyAvatarView: UIViewRepresentable {
    let selection: Region
    let resetToken: Int
    let onPick: (Region) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        context.coordinator.install(in: view, selection: selection, resetToken: resetToken)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.update(selection: selection, resetToken: resetToken)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPick: (Region) -> Void
        private weak var view: SCNView?
        private let pivot = SCNNode()
        private let camera = SCNNode()
        private var organs: [Region: [SCNNode]] = [:]
        private var selected = Region.heart
        private var lastReset = 0
        private var yaw: Float = 0
        private var zoom: Float = 1
        private var initialYaw: Float = 0
        private var initialZoom: Float = 1
        private let organMask = 2
        private let accent: [Region: UIColor] = [
            .heart: UIColor(red: 1, green: 0.29, blue: 0.28, alpha: 1),
            .liver: UIColor(red: 1, green: 0.62, blue: 0.27, alpha: 1),
            .kidneys: UIColor(red: 0.89, green: 0.42, blue: 0.67, alpha: 1)
        ]

        init(onPick: @escaping (Region) -> Void) { self.onPick = onPick }

        func install(in view: SCNView, selection: Region, resetToken: Int) {
            self.view = view
            selected = selection
            lastReset = resetToken
            view.backgroundColor = .clear
            view.isOpaque = false
            view.antialiasingMode = .multisampling2X
            view.accessibilityIdentifier = "map.avatar"
            view.isAccessibilityElement = true
            view.accessibilityLabel = "Трёхмерная карта тела"
            view.accessibilityTraits = .image
            view.accessibilityHint = "Для выбора области доступны кнопки под фигурой."
            let stage = SCNScene()
            stage.background.contents = UIColor.clear
            view.scene = stage
            stage.rootNode.addChildNode(pivot)
            guard let url = Bundle.main.url(forResource: "BodyAvatar", withExtension: "usdz"),
                  let model = try? SCNScene(url: url, options: [.convertUnitsToMeters: 1]) else {
                let label = UILabel()
                label.text = "3D-модель недоступна. Выбери область ниже."
                label.numberOfLines = 0
                label.textColor = .white
                label.textAlignment = .center
                label.frame = view.bounds
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(label)
                view.accessibilityValue = label.text
                return
            }
            for child in model.rootNode.childNodes { pivot.addChildNode(child) }
            styleMeshes()
            let lens = SCNCamera()
            lens.fieldOfView = 32
            lens.projectionDirection = .vertical
            lens.zNear = 0.01
            lens.zFar = 10
            camera.camera = lens
            stage.rootNode.addChildNode(camera)
            view.pointOfView = camera
            light(.ambient, intensity: 470, color: UIColor(red: 0.80, green: 0.85, blue: 0.97, alpha: 1), at: SCNVector3Zero)
            light(.omni, intensity: 790, color: .white, at: SCNVector3(-1.8, 3.1, 2.2))
            light(.omni, intensity: 430, color: UIColor(red: 0.55, green: 0.81, blue: 1, alpha: 1), at: SCNVector3(1.5, 2, -1.3))

            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
            let tap = UITapGestureRecognizer(target: self, action: #selector(pick(_:)))
            tap.require(toFail: pan)
            view.addGestureRecognizer(tap)
            view.accessibilityCustomActions = [
                action("Повернуть влево") { $0.yaw -= .pi / 6 },
                action("Повернуть вправо") { $0.yaw += .pi / 6 },
                action("Приблизить") { $0.zoom = min(3.2, $0.zoom * 1.5) },
                action("Отдалить") { $0.zoom = max(1, $0.zoom / 1.5) }
            ]
            refreshMaterials()
            frameCamera()
        }

        private func action(_ title: String, change: @escaping (Coordinator) -> Void) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: title) { [weak self] _ in
                guard let self else { return false }
                change(self)
                self.frameCamera()
                return true
            }
        }

        private func styleMeshes() {
            let palette: [(String, UInt32)] = [
                ("Shell", 0x92B5D2), ("Face", 0xCFAD92), ("Hair", 0x63493F), ("Brow", 0x63493F),
                ("Eye", 0xE2DECE), ("Iris", 0x4F6561), ("Pupil", 0x273238),
                ("Heart", 0xAA5656), ("Liver", 0xAB7257), ("Kidney", 0xA46D89),
                ("Lung", 0xA1ABCE), ("Aortic", 0xAF625B), ("Pulmonary", 0x7488AB)
            ]
            pivot.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                var ancestor: SCNNode? = node
                var part: (String, UInt32)?
                while let current = ancestor, current !== self.pivot, part == nil {
                    part = palette.first { current.name?.hasPrefix($0.0) == true }
                    ancestor = current.parent
                }
                guard let (name, rgb) = part else { return }
                let material = SCNMaterial()
                material.lightingModel = .blinn
                material.shininess = 0.28
                material.specular.contents = UIColor(white: 0.32, alpha: 1)
                material.diffuse.contents = UIColor(red: CGFloat(rgb >> 16) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
                material.isDoubleSided = ["Kidney", "Lung", "Brow"].contains(name)
                if name == "Shell" || name == "Lung" {
                    let shell = name == "Shell"
                    material.transparency = shell ? 0.35 : 0.24
                    material.transparencyMode = .singleLayer
                    material.writesToDepthBuffer = false
                    node.renderingOrder = shell ? 10 : 5
                }
                geometry.materials = [material]
                let region: Region
                switch name {
                case "Heart", "Aortic", "Pulmonary": region = .heart
                case "Liver": region = .liver
                case "Kidney": region = .kidneys
                default: return
                }
                node.categoryBitMask = self.organMask
                self.organs[region, default: []].append(node)
            }
        }

        func update(selection: Region, resetToken: Int) {
            guard camera.camera != nil else { return }
            if selection != selected {
                selected = selection
                refreshMaterials()
                frameCamera()
            }
            if resetToken != lastReset {
                lastReset = resetToken
                yaw = 0
                zoom = 1
                frameCamera()
            }
        }

        private func refreshMaterials() {
            for (area, nodes) in organs {
                for node in nodes {
                    let emission = node.geometry?.firstMaterial?.emission
                    emission?.contents = area == selected ? accent[area] : UIColor.black
                    emission?.intensity = area == selected ? 0.65 : 0
                }
            }
        }

        private func light(_ kind: SCNLight.LightType, intensity: CGFloat, color: UIColor, at position: SCNVector3) {
            let node = SCNNode()
            let lamp = SCNLight()
            lamp.categoryBitMask = 1 | organMask
            lamp.type = kind
            lamp.intensity = intensity
            lamp.color = color
            node.light = lamp
            node.position = position
            view?.scene?.rootNode.addChildNode(node)
        }

        private func frameCamera() {
            let target: Float
            switch selected {
            case .heart: target = 1.22
            case .liver: target = 1.11
            case .kidneys: target = 1.05
            }
            let blend = min(1, (zoom - 1) / 1.2)
            pivot.eulerAngles.y = yaw
            camera.position = SCNVector3(0, 0.845 + (target - 0.845) * blend, 3.45 / zoom)
            let angle = (Int((yaw * 180 / .pi).rounded()) % 360 + 360) % 360
            view?.accessibilityValue = "\(selected.rawValue), поворот \(angle)°, масштаб \(Int((zoom * 100).rounded()))%"
            view?.setNeedsDisplay()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view else { return true }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView, let view else { return false }
            return view.isDescendant(of: scroll)
        }

        @objc private func drag(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if gesture.state == .began { initialYaw = yaw }
            yaw = initialYaw + Float(gesture.translation(in: view).x / max(1, view.bounds.width)) * 2 * .pi
            frameCamera()
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { initialZoom = zoom }
            zoom = min(3.2, max(1, initialZoom * Float(gesture.scale)))
            frameCamera()
        }

        @objc private func pick(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [.categoryBitMask: organMask, .backFaceCulling: false,
                                                      .searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let hit = hits.first, let region = organs.first(where: { $0.value.contains(hit.node) })?.key {
                onPick(region)
                return
            }
            var nearest: (Region, CGFloat)?
            for (region, nodes) in organs {
                for node in nodes {
                    let (a, b) = node.boundingBox
                    let center = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
                    let p = view.projectPoint(node.convertPosition(center, to: nil))
                    let distance = hypot(point.x - CGFloat(p.x), point.y - CGFloat(p.y))
                    if distance <= 22 && distance < (nearest?.1 ?? .infinity) { nearest = (region, distance) }
                }
            }
            if let nearest { onPick(nearest.0) }
        }
    }
}
#endif
