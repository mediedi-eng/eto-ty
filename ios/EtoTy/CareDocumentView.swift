import SwiftUI
import PDFKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

private typealias DocumentState<Value> = State<Value>

// File transfers let us inspect the actual size before retaining a photo in memory.
private struct SelectedPhoto: Transferable {
    let bytes: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { transfer in
            SelectedPhoto(bytes: try CareDocuments.boundedRead(transfer.file))
        }
    }
}

struct CareDocumentView: View {
    let region: Region?
    @Environment(\.dismiss) private var dismiss
    @DocumentState private var documents: [CareDocument] = []
    @DocumentState private var query = ""
    @DocumentState private var picker = false
    @DocumentState private var photo: PhotosPickerItem?
    @DocumentState private var working = false
    @DocumentState private var preview: URL?
    @DocumentState private var pendingDelete: CareDocument?
    @DocumentState private var selected: CareDocument?
    @DocumentState private var editing: CareDocument?
    @DocumentState private var notice: String?
    private let store = CareDocuments()

    init(region: Region? = nil) { self.region = region }

    private var matches: [CareDocument] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return documents }
        return documents.filter { document in
            [document.name, document.region?.rawValue, document.evidence?.quote, document.evidence?.studyDate]
                .compactMap { $0 }.contains { $0.localizedStandardContains(term) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let notice {
                    Section {
                        Text(notice).font(.callout)
                    }
                }
                if working { ProgressView("Подготавливаем оригинал…") }
                Section {
                    Button { picker = true } label: { Label("Выбрать файл", systemImage: "folder") }
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                        Label("Выбрать фото", systemImage: "photo")
                    }
                } footer: {
                    Text("PDF до 20 МБ и 30 страниц. JPEG, PNG и HEIC до 10 МБ и 30 Мп. Оригиналы сохраняются на этом устройстве.")
                }.disabled(working)
                Section(region.map { "Отмечено тобой · " + $0.rawValue } ?? "Сохранённые оригиналы") {
                    if documents.isEmpty {
                        Text(region == nil ? "Здесь появится первый добавленный документ." : "Пока нет файлов с этой меткой.")
                            .foregroundStyle(.secondary)
                    }
                    else if matches.isEmpty { Text("Совпадений нет. Попробуй другое слово или дату.").foregroundStyle(.secondary) }
                    ForEach(matches) { document in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                do { preview = try store.originalURL(for: document) }
                                catch { show(error) }
                            } label: {
                                Label {
                                    Text(document.name).multilineTextAlignment(.leading)
                                } icon: {
                                    Image(systemName: document.kind == .pdf ? "doc.richtext" : "photo")
                                }
                            }.buttonStyle(.borderless)
                            Text("Добавлен " + document.imported.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = document.evidence?.studyDate {
                                Text("Дата исследования со слов пользователя: " + date).font(.caption)
                            }
                            if let evidence = document.evidence, let quote = evidence.quote, let page = evidence.page {
                                Text("Подтверждённый фрагмент, стр. " + String(page) + ": «" + quote + "»").font(.callout)
                            }
                            if document.region == nil, let suggestion = CareRegionSuggestion.fromTitle(document.name) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Предложено по названию: " + suggestion.rawValue)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Связать") { assign(suggestion, to: document) }
                                        .buttonStyle(.borderless).font(.callout)
                                        .accessibilityLabel("Связать " + document.name + " с областью " + suggestion.rawValue)
                                }
                            }
                            HStack(spacing: 16) {
                                Menu {
                                    Button("Без метки") { assign(nil, to: document) }
                                    ForEach(Region.allCases) { item in
                                        Button(item.rawValue) { assign(item, to: document) }
                                    }
                                } label: {
                                    Label(document.region?.rawValue ?? "Связать с областью", systemImage: "tag")
                                        .font(.caption)
                                }.buttonStyle(.borderless)
                                Button { editing = document } label: {
                                    Label("Выписка", systemImage: "square.and.pencil").font(.caption)
                                }.buttonStyle(.borderless)
                                Button(role: .destructive) { pendingDelete = document } label: {
                                    Image(systemName: "trash")
                                }.accessibilityLabel("Удалить " + document.name).buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if !documents.isEmpty {
                    Text("Открой выписку, чтобы перенести дату исследования и сверить текст с оригиналом.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Имя, метка, цитата или дата")
            .navigationTitle(region?.rawValue ?? "Мои документы")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }.disabled(working)
                }
            }
        }
        .interactiveDismissDisabled(working)
        .onAppear { reload() }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.pdf, .jpeg, .png, .heic, .heif]) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { show(error) }
                return
            }
            importFile(url)
        }
        .task(id: photo) {
            guard let chosen = photo else { return }
            working = true
            defer { working = false; photo = nil }
            let generation = store.beginImport()
            do {
                guard let item = try await chosen.loadTransferable(type: SelectedPhoto.self) else {
                    throw CareDocumentError.unsupported
                }
                try Task.checkCancellation()
                let archive = store
                let document = try await Task.detached { try archive.add(item.bytes, name: "Фото документа", generation: generation) }.value
                finishedImport(document)
            } catch { if !Task.isCancelled { show(error) } }
        }
        .sheet(item: $editing, onDismiss: reload) { document in DocumentEvidenceEditor(document: document, store: store) }
        .quickLookPreview($preview)
        .confirmationDialog("Удалить сохранённую копию?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { document in
            Button("Удалить копию", role: .destructive) {
                do {
                    try store.remove(document.id)
                    notice = "Копия удалена с этого устройства."
                    reload()
                } catch { show(error) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { document in Text(document.name) }
        .confirmationDialog("Добавить метку области?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), presenting: selected) { document in
            if let region {
                Button("Связать: " + region.rawValue) { assign(region, to: document) }
            }
            Button("Оставить как есть", role: .cancel) {}
        } message: { document in Text(document.name) }
    }

    private func importFile(_ url: URL) {
        guard !working else { return }
        working = true
        let generation = store.beginImport()
        Task {
            defer { working = false }
            do {
                let archive = store
                let document = try await Task.detached {
                    let bytes = try CareDocuments.loadSelectedFile(url)
                    return try archive.add(bytes, name: url.lastPathComponent, generation: generation)
                }.value
                finishedImport(document)
            } catch { show(error) }
        }
    }

    private func finishedImport(_ document: CareDocument) {
        notice = "Оригинал сохранён. Повторная загрузка сохраняет одну копию."
        reload()
        if let region, region != document.region { selected = document }
    }

    private func assign(_ region: Region?, to document: CareDocument) {
        do {
            try store.assign(region, to: document.id)
            notice = region.map { "Твоя метка: " + $0.rawValue } ?? "Метка снята."
            reload()
        } catch { show(error) }
    }

    private func reload() {
        do { documents = try store.list().filter { region == nil || $0.region == region } }
        catch { documents = []; show(error) }
    }

    private func show(_ error: Error) {
        notice = (error as? CareDocumentError)?.errorDescription ?? "Операция не выполнена. Проверь доступ к файлам и повтори."
    }
}

private struct DocumentEvidenceEditor: View {
    let document: CareDocument
    let store: CareDocuments
    @Environment(\.dismiss) private var dismiss
    @DocumentState private var hasDate: Bool
    @DocumentState private var date: Date
    @DocumentState private var page: Int
    @DocumentState private var quote: String
    @DocumentState private var readPage: Int
    @DocumentState private var readRequest: UUID?
    @DocumentState private var candidates = [String]()
    @DocumentState private var readStatus: String?
    @DocumentState private var reading = false
    @DocumentState private var pageCount = 1
    @DocumentState private var preview: URL?
    @DocumentState private var pdfPage: SourcePDFPage?
    @DocumentState private var errorText: String?

    init(document: CareDocument, store: CareDocuments) {
        self.document = document
        self.store = store
        let studyDate = document.evidence?.studyDate.flatMap { CareDocumentEvidence.dateFormatter().date(from: $0) }
        _hasDate = DocumentState(initialValue: studyDate != nil)
        _date = DocumentState(initialValue: studyDate ?? Date())
        _page = DocumentState(initialValue: document.evidence?.page ?? 1)
        _readPage = DocumentState(initialValue: document.evidence?.page ?? 1)
        _quote = DocumentState(initialValue: document.evidence?.quote ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Открыть оригинал") { openOriginal(at: readPage) }
                    Toggle("Указать дату исследования", isOn: $hasDate)
                    if hasDate { DatePicker("Исследование", selection: $date, displayedComponents: .date) }
                } header: { Text(document.name) }
                Section {
                    if document.kind == .pdf && pageCount > 1 {
                        Stepper("Прочитать страницу " + String(readPage) + " из " + String(pageCount),
                                value: $readPage, in: 1...pageCount)
                            .onChange(of: readPage) { _, _ in
                                readRequest = nil
                                reading = false
                                candidates = []
                                readStatus = nil
                            }
                    }
                    Button {
                        candidates = []
                        readStatus = nil
                        reading = true
                        readRequest = UUID()
                    } label: {
                        Label("Найти текст на странице", systemImage: "text.viewfinder")
                    }.disabled(reading)
                    if reading { ProgressView("Читаем на устройстве…") }
                    if let readStatus { Text(readStatus).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                        Button {
                            quote = candidate
                            page = readPage
                            candidates = []
                            readStatus = "Фрагмент в черновике. Теперь его можно исправить и сверить с оригиналом."
                            errorText = nil
                        } label: {
                            Text(candidate).multilineTextAlignment(.leading)
                        }.accessibilityHint("Перенести этот фрагмент в черновик")
                    }
                } header: { Text("Текст оригинала") }
                Section {
                    TextField("Точная фраза из документа", text: $quote, axis: .vertical)
                        .lineLimit(2...7)
                    if document.kind == .pdf && !quote.isEmpty {
                        Stepper("Страница " + String(page), value: $page, in: 1...max(pageCount, page))
                    }
                    if !quote.isEmpty {
                        Button("Сверить с оригиналом, стр. " + String(page)) { openOriginal(at: page) }
                    }
                } header: { Text("Твой черновик") }
                footer: { Text("Сверь цифры, слова и страницу с оригиналом. Пустая строка удаляет прежнюю цитату.") }
                if let errorText { Text(errorText).foregroundStyle(.secondary) }
            }
            .navigationTitle("Выписка из документа")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Подтвердить") {
                        do {
                            try store.annotate(document.id, studyDate: hasDate ? date : nil, page: page, quote: quote)
                            dismiss()
                        } catch {
                            errorText = (error as? CareDocumentError)?.errorDescription ?? "Не удалось сохранить выписку."
                        }
                    }
                }
            }
        }
        .task {
            let archive = store
            let original = document
            do {
                pageCount = try await Task.detached { try archive.pageCount(for: original) }.value
            } catch { errorText = "Не удалось открыть оригинал." }
        }
        .task(id: readRequest) {
            guard let request = readRequest else { return }
            let archive = store
            let original = document
            let selectedPage = readPage
            do {
                let result = try await Task.detached {
                    let url = try archive.originalURL(for: original)
                    return try CarePageReader.candidates(url: url, kind: original.kind, page: selectedPage)
                }.value
                guard !Task.isCancelled, request == readRequest, selectedPage == readPage else { return }
                candidates = result
                readStatus = candidates.isEmpty ? "Разборчивый фрагмент не найден. Можно переписать его вручную." :
                    "Выбери фрагмент. Он появится в черновике для сверки."
                reading = false
            } catch {
                guard !Task.isCancelled, request == readRequest else { return }
                readStatus = "Не удалось прочитать страницу. Открой оригинал или перенеси фразу вручную."
                reading = false
            }
        }
        .sheet(item: $pdfPage) { source in
            NavigationStack {
                SourcePDFPreview(source: source)
                    .navigationTitle("Оригинал · стр. " + String(source.page))
                    .toolbar { Button("К выписке") { pdfPage = nil } }
            }
        }
        .quickLookPreview($preview)
    }
    private func openOriginal(at page: Int) {
        do {
            let url = try store.originalURL(for: document)
            if document.kind == .pdf { pdfPage = SourcePDFPage(url: url, page: page) }
            else { preview = url }
        } catch { errorText = "Не удалось открыть оригинал." }
    }

}

private struct SourcePDFPage: Identifiable {
    let url: URL
    let page: Int
    var id: Int { page }

    @MainActor func makeView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.document = PDFDocument(url: url)
        if let current = view.document?.page(at: page - 1) { view.go(to: current) }
        return view
    }
}

#if os(iOS)
private struct SourcePDFPreview: UIViewRepresentable {
    let source: SourcePDFPage
    func makeUIView(context: Context) -> PDFView { source.makeView() }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#elseif os(macOS)
private struct SourcePDFPreview: NSViewRepresentable {
    let source: SourcePDFPage
    func makeNSView(context: Context) -> PDFView { source.makeView() }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif
