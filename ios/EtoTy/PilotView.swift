import SwiftUI
import UniformTypeIdentifiers

// Use the SwiftUI property-wrapper type on toolchains that also expose a State macro.
private typealias ViewState<Value> = State<Value>

private enum PilotTab { case chat, level, map }

struct PilotView: View {
    @ViewState private var tab = PilotTab.chat
    @ViewState private var profile = PilotProfile()
    @ViewState private var region = Region.kidneys
    @ViewState private var draft = ""
    @ViewState private var showBrief = false
    private let green = Color(red: 0.08, green: 0.38, blue: 0.31)

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { chat.navigationTitle("Диалог") }
                .tabItem { Label("Диалог", systemImage: "bubble.left.and.bubble.right") }.tag(PilotTab.chat)
            NavigationStack { level.navigationTitle("Мой уровень") }
                .tabItem { Label("Мой уровень", systemImage: "chart.bar") }.tag(PilotTab.level)
            NavigationStack { map.navigationTitle("Карта тела") }
                .tabItem { Label("Карта тела", systemImage: "figure.stand") }.tag(PilotTab.map)
        }
        .tint(green)
        .sheet(isPresented: $showBrief) { BriefView(profile: profile, initialRegion: region) }
    }

    private var chat: some View {
        VStack(alignment: .leading) {
            Text("Это ты · вымышленный профиль").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(profile.messages) { line in
                            Text(line.text)
                                .padding(12)
                                .background(line.fromUser ? green.opacity(0.16) : Color.secondary.opacity(0.09),
                                            in: RoundedRectangle(cornerRadius: 15))
                                .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: profile.messages.count) { _, _ in
                    if let id = profile.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack {
                Button("План") { profile.receive("План") }
                Button(profile.paused ? "Возобновить" : "Пауза") {
                    profile.receive(profile.paused ? "Возобновить" : "Пауза")
                }
            }.buttonStyle(.bordered)
            HStack {
                TextField("Сообщение", text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .accessibilityLabel("Отправить").disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding()
    }

    private func send() { profile.receive(draft); draft = "" }

    private var level: some View {
        List {
            Section("Сопровождение темы сна") {
                Text("Уровень " + String(profile.level) + " из 4").font(.title.bold())
                Text(profile.levelReason)
                Text(profile.plan).foregroundStyle(.secondary)
            }
            Section("Основания") {
                ForEach(profile.nights, id: \.date) { night in
                    VStack(alignment: .leading) {
                        Text(night.date + " · " + String(night.minutes) + " мин")
                        Text(night.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if profile.nights.count == 1 {
                    Button("Добавить две записи из примера") { profile.importExampleDiary() }
                }
                if profile.trendEstablished && !profile.trendReviewed && !profile.paused {
                    Button("Записи просмотрены, завершить цикл") { profile.reviewTrend() }
                }
            }
        }
    }

    private var map: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                ZStack {
                    Canvas { context, size in
                        let image = context.resolve(Image(systemName: "figure.stand"))
                        context.draw(image, in: CGRect(x: size.width * 0.25, y: 5,
                                                       width: size.width * 0.5, height: size.height - 10))
                    }.foregroundStyle(.secondary.opacity(0.35)).accessibilityHidden(true)
                    VStack(alignment: .trailing, spacing: 5) {
                        ForEach(Region.allCases) { item in
                            Button { region = item } label: {
                                Label(item.rawValue, systemImage: region == item ? "largecircle.fill.circle" : "circle")
                            }.buttonStyle(.bordered).accessibilityValue(region == item ? "Выбрано" : "")
                        }
                    }.frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(height: 180)
                Text(region.rawValue).font(.title2.bold())
                let materials = profile.materials(for: region)
                if materials.isEmpty { Text("Пока нет связанных материалов.").foregroundStyle(.secondary) }
                ForEach(materials) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.document).font(.headline)
                        Text("Исследование " + record.eventDate + " · добавлено " + record.uploaded).font(.caption)
                        Text("«" + record.quote + "»").textSelection(.enabled)
                        Text("Страница " + String(record.page)).font(.caption)
                        if record.region == .kidneys { Text("Срок пересмотра не указан.").foregroundStyle(.secondary) }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                Button("Обсудить в диалоге") { profile.discuss(region); tab = .chat }
                Button("Собрать сводку врачу") { showBrief = true }.buttonStyle(.borderedProminent)
            }.padding()
        }
    }
}

private struct BriefFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct BriefView: View {
    let profile: PilotProfile
    @ViewState private var scope: Region?
    @ViewState private var file: BriefFile?
    @ViewState private var exporting = false
    @ViewState private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(profile: PilotProfile, initialRegion: Region) {
        self.profile = profile
        _scope = State(initialValue: initialRegion)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Объём", selection: $scope) {
                    Text("Общий профиль").tag(Optional<Region>.none)
                    ForEach(Region.allCases) { item in Text(item.rawValue).tag(Optional(item)) }
                }
                ScrollView { Text(profile.visitSummary(region: scope)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                if let errorText { Text(errorText).foregroundStyle(.red) }
                Button("Сохранить PDF") {
                    do {
                        file = try BriefFile(VisitPDF.render(profile.visitSummary(region: scope)))
                        errorText = nil
                        exporting = true
                    } catch { errorText = "Не удалось сформировать PDF." }
                }.buttonStyle(.borderedProminent)
            }.padding().navigationTitle("К приёму")
                .toolbar { Button("Закрыть") { dismiss() } }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .pdf, defaultFilename: "eto-ty-visit") { result in
            if case .failure(let error) = result { errorText = error.localizedDescription }
        }
    }
}
