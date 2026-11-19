import Foundation

enum IncomingDocumentChecks {
    enum Failure: Error { case consent, copy, original, grant, validation }

    @MainActor
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("container")
        let inbox = home.appendingPathComponent("Documents/Inbox")
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("Выписка.pdf")
        let pdf = try VisitPDF.render("Вымышленный документ для проверки.")
        try pdf.write(to: external)
        let archive = CareDocuments(directory: home.appendingPathComponent("Library/CareDocuments"))
        var starts = 0, stops = 0
        let incoming = CareIncomingDocument(archive: archive, container: home, start: { url in
            starts += 1
            return url == external
        }, stop: { _ in stops += 1 }, readExternal: CareDocuments.boundedRead)

        incoming.receive(external)
        let firstID = incoming.offer?.id
        guard incoming.offer?.name == "Выписка.pdf", try archive.list().isEmpty, starts == 1, stops == 0 else {
            throw Failure.consent
        }
        let second = inbox.appendingPathComponent("Второй.pdf")
        try pdf.write(to: second)
        incoming.receive(second)
        guard incoming.offer?.id == firstID, incoming.otherFileNotice != nil, !fm.fileExists(atPath: second.path),
              try archive.list().isEmpty else { throw Failure.consent }
        incoming.dismiss()
        guard stops == 1, incoming.offer == nil, try Data(contentsOf: external) == pdf else { throw Failure.original }

        incoming.receive(external)
        guard let saved = await incoming.save(), saved.kind == .pdf, try archive.list() == [saved],
              try Data(contentsOf: archive.originalURL(for: saved)) == pdf, try Data(contentsOf: external) == pdf,
              incoming.offer == nil, starts == 2, stops == 2 else { throw Failure.grant }

        for folder in [inbox, home.appendingPathComponent("tmp/EtoTy-Inbox")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("Сохранить.pdf")
            try pdf.write(to: copy)
            incoming.receive(copy)
            incoming.receive(copy)
            guard fm.fileExists(atPath: copy.path), incoming.otherFileNotice == nil else { throw Failure.copy }
            guard await incoming.save()?.id == saved.id, !fm.fileExists(atPath: copy.path) else { throw Failure.copy }
            try pdf.write(to: copy)
            incoming.receive(copy)
            incoming.dismiss()
            guard !fm.fileExists(atPath: copy.path), starts == 2, stops == 2 else { throw Failure.copy }
        }

        let stale = inbox.appendingPathComponent("Поздний.pdf")
        try pdf.write(to: stale)
        incoming.receive(stale)
        try archive.deleteAll()
        guard await incoming.save() == nil, incoming.error != nil, !fm.fileExists(atPath: stale.path),
              try archive.list().isEmpty else { throw Failure.validation }
        incoming.dismiss()

        try Data("not a PDF".utf8).write(to: stale)
        incoming.receive(stale)
        guard await incoming.save() == nil, incoming.error != nil, !fm.fileExists(atPath: stale.path),
              try archive.list().isEmpty else { throw Failure.validation }
        incoming.dismiss()

        try pdf.write(to: stale)
        incoming.receive(stale)
        let moved = inbox.appendingPathComponent("Переименован.pdf")
        try fm.moveItem(at: stale, to: moved)
        try pdf.write(to: stale)
        guard await incoming.save() == nil, incoming.error != nil else { throw Failure.original }
        incoming.dismiss()
        guard fm.fileExists(atPath: stale.path), fm.fileExists(atPath: moved.path) else { throw Failure.original }

        let link = inbox.appendingPathComponent("Ссылка.pdf")
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        incoming.receive(link)
        guard incoming.error != nil else { throw Failure.validation }
        incoming.dismiss()
        guard fm.fileExists(atPath: link.path), try Data(contentsOf: external) == pdf else { throw Failure.original }

        let privateFile = home.appendingPathComponent("Private.pdf")
        try pdf.write(to: privateFile)
        incoming.receive(privateFile)
        guard incoming.error != nil, starts == 2 else { throw Failure.grant }
        incoming.dismiss()
        guard fm.fileExists(atPath: privateFile.path) else { throw Failure.original }
        incoming.receive(root.appendingPathComponent("Без разрешения.pdf"))
        guard incoming.error != nil, starts == 3, stops == 2 else { throw Failure.grant }
        incoming.dismiss()
    }
}
