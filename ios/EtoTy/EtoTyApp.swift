import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct EtoTyApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CareNotificationBootstrap.self) private var notificationBootstrap
    #endif
    @StateObject private var session = CareSession()
    @StateObject private var incoming = CareIncomingDocument()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PersonalCareView(session: session, incoming: incoming)
                #if os(iOS)
                .background(SnapshotShield().frame(width: 0, height: 0))
                .onOpenURL { url in incoming.receive(url) }
                #endif
                .onAppear { session.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.refresh() }
                }
        }
    }
}


#if os(iOS)
// Place the cover above presented sheets, on the app's window; system permission
// sheets that merely make the scene inactive leave the underlying UI untouched.
private struct SnapshotShield: UIViewRepresentable {
    func makeUIView(context: Context) -> ShieldObserver { ShieldObserver() }
    func updateUIView(_ view: ShieldObserver, context: Context) {}

    final class ShieldObserver: UIView {
        private var cover: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self, name: UIScene.didEnterBackgroundNotification, object: nil)
            center.removeObserver(self, name: UIScene.willEnterForegroundNotification, object: nil)
            uncover()
            guard let scene = window?.windowScene else { return }
            center.addObserver(self, selector: #selector(conceal), name: UIScene.didEnterBackgroundNotification, object: scene)
            center.addObserver(self, selector: #selector(uncover), name: UIScene.willEnterForegroundNotification, object: scene)
            if scene.activationState == .background { conceal() }
        }

        @objc private func conceal() {
            guard cover == nil, let window else { return }
            let panel = UIView(frame: window.bounds)
            panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            panel.backgroundColor = .systemBackground
            panel.isUserInteractionEnabled = false
            window.addSubview(panel)
            cover = panel
        }

        @objc private func uncover() {
            cover?.removeFromSuperview()
            cover = nil
        }
    }
}
#endif
