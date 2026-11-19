import Combine
import Darwin
import Foundation
import SwiftUI

// The URL and its access grant live only while the user decides. The archive owns no bytes until Save.
@MainActor
final class CareIncomingDocument: ObservableObject {
    struct Offer: Identifiable {
        let id = UUID()
        let name: String
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var otherFileNotice: String?
    private let archive: CareDocuments
    private let container: URL
    private let inboxes: Set<String>
    private let start: (URL) -> Bool
    private let stop: (URL) -> Void
    private let readExternal: (URL) throws -> Data
    private var source: Source?
    private var saved: CareDocument?
    private var generation: UInt64 = 0

    init(archive: CareDocuments = CareDocuments(), container: URL = URL(fileURLWithPath: NSHomeDirectory()),
         bundleName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "EtoTy",
         bundleID: String = Bundle.main.bundleIdentifier ?? "eng.mediedi.etoty.pilot",
         start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         readExternal: @escaping (URL) throws -> Data = CareDocuments.coordinatedRead) {
        self.archive = archive
        let home = container.resolvingSymlinksInPath().standardizedFileURL
        self.container = home
        let folders = ["Documents/Inbox", "tmp/" + bundleName + "-Inbox", "tmp/" + bundleID + "-Inbox"]
        self.inboxes = Set(folders.map { home.appendingPathComponent($0).path })
        self.start = start
        self.stop = stop
        self.readExternal = readExternal
    }

    private final class Source {
        let url: URL
        let read: () throws -> Data
        let release: (() -> Void)?
        let removeCopy: (() throws -> Void)?

        init(url: URL, read: @escaping () throws -> Data,
             release: (() -> Void)? = nil, removeCopy: (() throws -> Void)? = nil) {
            self.url = url
            self.read = read
            self.release = release
            self.removeCopy = removeCopy
        }
        deinit { release?() }
    }

    private func source(for url: URL) throws -> Source {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost" else {
            throw CareDocumentError.unsupported
        }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        // Recognize only direct children of the system inboxes inside THIS app's container.
        if inboxes.contains(parent.path) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw CareDocumentError.unavailable
            }
            let device = info.st_dev, inode = info.st_ino
            return Source(url: url, read: { try CareDocuments.boundedRead(url, matching: (device, inode)) }, removeCopy: {
                let currentParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                guard currentParent.path == parent.path else { return }
                var current = stat()
                if lstat(url.path, &current) != 0 {
                    if errno == ENOENT { return }
                    throw CareDocumentError.unavailable
                }
                // A directory, a symlink or a replacement at the same path belongs to someone else.
                guard current.st_mode & S_IFMT == S_IFREG, current.st_ino == inode, current.st_dev == device else { return }
                if unlink(url.path) != 0, errno != ENOENT { throw CareDocumentError.unavailable }
            })
        }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != container.path, !path.hasPrefix(container.path + "/"), start(url) else {
            throw CareDocumentError.unavailable
        }
        let release = stop, read = readExternal
        return Source(url: url, read: { try read(url) }, release: { release(url) })
    }

    func receive(_ url: URL) {
        if offer != nil {
            if let active = source?.url,
               active.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL { return }
            otherFileNotice = "Уже открыт другой файл. Когда закончишь, открой следующий ещё раз."
            // The incoming URL might be a fresh OS-owned copy. Never touch the active source.
            if let other = try? source(for: url) {
                do { try other.removeCopy?() }
                catch { otherFileNotice = "Уже открыт другой файл. Не удалось удалить вторую временную копию." }
            }
            return
        }
        let name = url.lastPathComponent.components(separatedBy: .controlCharacters).joined(separator: " ")
        offer = Offer(name: url.isFileURL ? String(name.prefix(160)) : "Документ")
        generation = archive.beginImport()
        do { source = try source(for: url) }
        catch { self.error = "Не удалось получить доступ к файлу. Его можно выбрать в разделе «Мои документы»." }
    }

    func save() async -> CareDocument? {
        guard let source, offer != nil, !saving, error == nil else { return nil }
        saving = true
        let archive = self.archive, generation = self.generation, url = source.url
        do {
            saved = try await Task.detached {
                let bytes = try source.read()
                return try archive.add(bytes, name: url.lastPathComponent, generation: generation)
            }.value
        } catch is CancellationError {
            error = "Профиль изменился. Файл не добавлен."
        } catch let reason as CareDocumentError {
            error = reason.localizedDescription
        } catch {
            self.error = "Не удалось прочитать файл. Проверь, что он загружен на устройство, и открой его снова."
        }
        saving = false
        if saved != nil { return dismiss() }
        // Remain on the error screen, with no access grant or owned temporary bytes left.
        _ = releaseSource()
        return nil
    }

    @discardableResult
    func dismiss() -> CareDocument? {
        guard !saving, releaseSource() else { return nil }
        let result = saved
        saved = nil
        error = nil
        otherFileNotice = nil
        offer = nil
        return result
    }

    private func releaseSource() -> Bool {
        do { try source?.removeCopy?() }
        catch {
            self.error = (saved == nil ? "" : "Документ сохранён. ") + "Не удалось удалить временную копию. Разблокируй устройство и нажми «Закрыть» ещё раз."
            return false
        }
        source = nil
        return true
    }
}

struct CareIncomingDocumentView: View {
    @ObservedObject var incoming: CareIncomingDocument
    let storageAvailable: Bool
    let finish: (CareDocument?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let offer = incoming.offer {
                    Section { Label(offer.name, systemImage: "doc") }
                    if let error = incoming.error {
                        Section { Text(error) }
                    } else {
                        Section {
                            Text("Сохранить копию в твоём архиве на этом устройстве?")
                            if storageAvailable {
                                Button("Сохранить в архив") {
                                    Task {
                                        let saved = await incoming.save()
                                        if incoming.offer == nil { finish(saved) }
                                    }
                                }
                                .accessibilityIdentifier("care.incoming.save")
                            } else { Text("Личный профиль сейчас недоступен. Открой файл снова после разблокировки.") }
                        }
                    }
                    if let notice = incoming.otherFileNotice { Section { Text(notice) } }
                    if incoming.saving { ProgressView("Сохраняем копию…") }
                }
            }
            .disabled(incoming.saving)
            .navigationTitle("Добавить документ?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(incoming.error == nil ? "Отмена" : "Закрыть") {
                        let saved = incoming.dismiss()
                        if incoming.offer == nil { finish(saved) }
                    }
                    .disabled(incoming.saving)
                    .accessibilityIdentifier("care.incoming.cancel")
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
