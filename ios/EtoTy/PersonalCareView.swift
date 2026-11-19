import SwiftUI

private typealias ViewState<Value> = State<Value>

private enum CareTab { case chat, level, map }

private enum CareSheet: Hashable, Identifiable {
    case schedule(Date?), documents(Region?), prevention, intent, demo

    var id: Self { self }
}

struct PersonalCareView: View {
    @ObservedObject var session: CareSession
    @ViewState private var tab = CareTab.chat
    @ViewState private var sheet: CareSheet?
    @ViewState private var draft = ""
    @ViewState private var region = Region.heart
    @ViewState private var documents: [CareDocument] = []
    @ViewState private var archiveAvailable = false
    @ViewState private var confirmingDeletion = false
    @FocusState private var composing: Bool
    @Environment(\.colorScheme) private var scheme

    private var accent: Color {
        scheme == .dark ? Color(red: 0.45, green: 0.85, blue: 0.71) : Color(red: 0.06, green: 0.40, blue: 0.32)
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                chat.navigationTitle("Диалог").toolbar { profileMenu }
            }
            .tabItem { Label("Диалог", systemImage: "bubble.left.and.bubble.right") }.tag(CareTab.chat)

            NavigationStack {
                level.navigationTitle("Мой уровень").toolbar { profileMenu }
            }
            .tabItem { Label("Мой уровень", systemImage: "chart.bar") }.tag(CareTab.level)

            NavigationStack {
                bodyMap.navigationTitle("Карта тела").toolbar { profileMenu }
            }
            .tabItem { Label("Карта тела", systemImage: "figure.stand") }.tag(CareTab.map)
        }
        .tint(accent)
        .sheet(item: $sheet, onDismiss: loadDocuments) { destination in
            switch destination {
            case .schedule(let suggestion):
                ContactTimeView(previous: suggestion ?? session.plan.nextContact) { date in
                    session.schedule(at: date)
                }
            case .intent:
                CareIntentView(onChoose: chooseRoute)
            case .prevention:
                CarePreventionView(onChoose: preventionAction)
            case .documents(let scope):
                CareDocumentView(region: scope)
            case .demo:
                VStack(spacing: 0) {
                    HStack {
                        Label("Вымышленный профиль", systemImage: "person.crop.rectangle.stack").font(.headline)
                        Spacer()
                        Button("Закрыть") { sheet = nil }
                            .accessibilityLabel("Вернуться в личный профиль")
                    }
                    .padding()
                    Divider()
                    PilotView()
                }
            }
        }
        .alert("Удалить личный профиль из приложения?", isPresented: $confirmingDeletion) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                session.deleteProfile()
                loadDocuments()
            }
        } message: {
            Text("Будут удалены переписка и сохранённые в приложении документы. Будущее напоминание отменится.")
        }
        .onChange(of: session.plan.messages.first?.id) { _, _ in
            draft = ""
            tab = .chat
        }
        .onChange(of: session.contactSuggestionToken) { _, _ in
            guard let date = session.suggestedContact else { return }
            composing = false
            sheet = .schedule(date)
        }
        .onChange(of: session.openChatToken) { _, _ in
            confirmingDeletion = false
            sheet = nil
            composing = false
            tab = .chat
        }
    }

    private var profileMenu: some View {
        Menu {
            Button { sheet = .intent } label: { Label("Подобрать раздел по фразе", systemImage: "text.magnifyingglass") }
            Button { sheet = .prevention } label: { Label("Справочник профилактики", systemImage: "book") }
            Button { sheet = .documents(nil) } label: { Label("Мои документы", systemImage: "folder") }
                .disabled(session.storageUnavailable)
            Button { sheet = .demo } label: { Label("Посмотреть вымышленный пример", systemImage: "person.crop.rectangle.stack") }
            Divider()
            Button(role: .destructive) { confirmingDeletion = true } label: {
                Label("Удалить личный профиль", systemImage: "trash")
            }
        } label: {
            Image(systemName: "person.crop.circle").font(.title2)
        }.accessibilityLabel("Меню личного профиля")
    }

    private var chat: some View {
        VStack(spacing: 0) {
            Text("Личный план на устройстве · без дежурного врача")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            sessionFeedback
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(session.plan.messages) { message in
                            CareBubble(message: message, accent: accent)
                                .id(message.id)
                        }
                        if !session.plan.isAskingForUrgentHelp && (session.plan.topic == nil || session.plan.isDiscussingPrevention) && !session.storageUnavailable {
                            Button("Что проверить?") { sheet = .prevention }
                                .buttonStyle(.bordered)
                        }
                        if session.plan.topic != nil && !session.plan.isAskingForUrgentHelp {
                            agenda
                        }
                        Color.clear.frame(height: 1).id("latest").accessibilityHidden(true)
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: session.plan.messages.last?.id) { _, _ in
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                Button { composing = false; sheet = .documents(nil) } label: {
                    Image(systemName: "paperclip").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Открыть и добавить документы")
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .focused($composing).lineLimit(1...5)
                    .padding(10).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("care.composer")
                    .accessibilityHint("Можно использовать диктовку клавиатуры.")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Отправить сообщение")
                .accessibilityIdentifier("care.send")
            }
            .disabled(session.storageUnavailable)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    @ViewBuilder private var sessionFeedback: some View {
        if let status = session.statusText {
            HStack {
                Label(status, systemImage: "info.circle").font(.callout)
                if session.storageUnavailable {
                    Button("Повторить") { session.refresh() }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .accessibilityElement(children: .contain)
        }
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Следующий контакт", systemImage: "calendar").font(.headline)
            Text(contactDescription).font(.subheadline)
            if let status = session.notificationStatus, session.plan.nextContact != nil {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if !session.plan.isClosed && !session.storageUnavailable {
                if session.plan.isPaused {
                    Button("Возобновить") { session.resume() }.buttonStyle(.bordered)
                } else {
                    HStack {
                        Button(session.plan.nextContact == nil ? "Выбрать время" : "Перенести") {
                            composing = false
                            sheet = .schedule(nil)
                        }.buttonStyle(.bordered)
                        Menu {
                            if session.plan.nextContact != nil || session.plan.hasDueQuestion {
                                Button("Отменить напоминание") { session.send("Отмени напоминание") }
                            }
                            Button("Поставить на паузу") { session.pause() }
                            Button("Завершить тему") { session.finish() }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Действия с темой")
                    }
                }
                if session.plan.isPaused {
                    Button("Завершить тему") { session.finish() }
                }
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func chooseRoute(_ route: CareIntentRoute) {
        switch route {
        case .documents:
            sheet = .documents(nil)
        case .prevention:
            sheet = .prevention
        case .visitPreparation:
            sheet = nil
            tab = .chat
            if draft.isEmpty { draft = "Подготовить вопросы к приёму" }
            composing = true
        case .reminder:
            if session.plan.topic != nil && !session.plan.isPaused && !session.plan.isClosed {
                sheet = .schedule(nil)
            } else {
                sheet = nil
                tab = .chat
                composing = true
            }
        }
    }

    private var preventionAction: ((String) -> Void)? {
        guard !session.storageUnavailable, session.plan.topic == nil || session.plan.isClosed else { return nil }
        return { goal in
            guard session.plan.topic == nil || session.plan.isClosed else { return }
            session.send(goal)
            tab = .chat
        }
    }

    private var contactDescription: String {
        if session.plan.isClosed { return "Тема завершена. Новый разговор можно начать в диалоге." }
        if session.plan.isPaused { return "Тема на паузе. Следующее время можно выбрать после возобновления." }
        if session.plan.hasDueQuestion { return "Вопрос уже в диалоге. Можно ответить, когда удобно." }
        if let date = session.plan.nextContact {
            return date.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.wide).year().hour().minute())
        }
        return "Время следующего разговора ещё не выбрано."
    }

    private func send() {
        let before = session.plan.messages.last?.id
        session.send(draft)
        if session.plan.messages.last?.id != before {
            draft = ""
            composing = false
        }
    }

    private var level: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sessionFeedback
                if let document = levelEvidence, let area = document.region {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Уровень 2").font(.title.weight(.bold))
                        Text("Есть исходная картина").font(.headline).foregroundStyle(accent)
                        Text("В области «" + area.rawValue + "» есть датированная запись, которую ты сверил с оригиналом.")
                    }
                    Button { sheet = .documents(area) } label: { DocumentSourceRow(document: document) }
                        .buttonStyle(.plain)
                } else if session.plan.topic != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Уровень 1").font(.title.weight(.bold))
                        Text("На связи").font(.headline).foregroundStyle(accent)
                        Text("Ты поручил приложению тему. Её можно продолжить в диалоге.")
                    }
                }
                if let topic = session.plan.topic {
                    Divider()
                    Text("Твоя тема").font(.headline)
                    Text(topic).textSelection(.enabled)
                    if let answer = session.plan.lastAnswer {
                        Text("Последний ответ").font(.headline)
                        Text(answer.text).textSelection(.enabled)
                        Text("Твои слова · " + answer.createdAt.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month().year()))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    agenda
                } else if levelEvidence == nil {
                    ContentUnavailableView {
                        Label("Пока нет темы", systemImage: "bubble.left")
                    } description: {
                        Text("Расскажи в диалоге, к какому вопросу хочешь вернуться. Здесь появится первая договорённость.")
                    } actions: {
                        Button("Начать разговор") { tab = .chat; composing = true }.buttonStyle(.bordered)
                    }
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadDocuments)
    }

    private var levelEvidence: CareDocument? {
        documents.first { doc in
            doc.region != nil && doc.evidence?.studyDate != nil && !(doc.evidence?.quote?.isEmpty ?? true)
        }
    }

    private var bodyMap: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sessionFeedback
                HStack(spacing: 18) {
                    BodyProjection(selected: region, accent: accent)
                        .frame(width: 94, height: 180).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Region.allCases) { item in
                            Button {
                                region = item
                            } label: {
                                HStack {
                                    Text(item.rawValue)
                                    Spacer()
                                    Image(systemName: item == region ? "checkmark.circle.fill" : "circle")
                                }.padding(.horizontal, 12).frame(minHeight: 44)
                                    .background(item == region ? accent.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityAddTraits(item == region ? .isSelected : [])
                        }
                    }
                }
                Divider()
                Text(region.rawValue).font(.title2.weight(.semibold))
                if archiveAvailable {
                    let linked = documents.filter { $0.region == region }
                    if linked.isEmpty {
                        Text("Связанных документов пока нет.").foregroundStyle(.secondary)
                    }
                    ForEach(linked) { document in
                        DocumentSourceRow(document: document)
                    }
                } else {
                    Text("Сведения о документах пока недоступны.").foregroundStyle(.secondary)
                }
                Button { sheet = .documents(region) } label: { Label("Документы этой области", systemImage: "doc") }
                    .buttonStyle(.bordered).disabled(session.storageUnavailable)
                Button("Обсудить в диалоге") {
                    if draft.isEmpty { draft = "Хочу обсудить тему «" + region.rawValue + "»." }
                    tab = .chat
                    composing = true
                }.disabled(session.storageUnavailable)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadDocuments)
    }

    private func loadDocuments() {
        guard !session.storageUnavailable else {
            documents = []
            archiveAvailable = false
            return
        }
        do {
            documents = try CareDocuments().list()
            archiveAvailable = true
        } catch {
            documents = []
            archiveAvailable = false
        }
    }
}

// Anterior, schematic orientation. The highlighted region follows the selection.
private struct BodyProjection: View {
    let selected: Region
    let accent: Color

    var body: some View {
        Canvas { context, size in
            var figure = context.resolve(Image(systemName: "figure.stand"))
            figure.shading = .color(Color.secondary.opacity(0.34))
            context.draw(figure, in: CGRect(origin: .zero, size: size))
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * size.width, y: y * size.height)
            }
            func kidney(at x: CGFloat) -> Path {
                let p = point(x, 0.44)
                return Path(ellipseIn: CGRect(x: p.x, y: p.y, width: size.width * 0.075, height: size.height * 0.066))
            }
            switch selected {
            case .heart:
                var symbol = context.resolve(Image(systemName: "heart.fill"))
                symbol.shading = .color(accent)
                let origin = point(0.49, 0.28)
                context.draw(symbol, in: CGRect(origin: origin, size: CGSize(width: size.width * 0.16, height: size.height * 0.07)))
            case .liver:
                var shape = Path()
                shape.move(to: point(0.34, 0.38))
                shape.addQuadCurve(to: point(0.62, 0.38), control: point(0.44, 0.34))
                shape.addQuadCurve(to: point(0.37, 0.44), control: point(0.53, 0.41))
                shape.addQuadCurve(to: point(0.34, 0.38), control: point(0.31, 0.42))
                context.fill(shape, with: .color(accent))
            case .kidneys:
                context.fill(kidney(at: 0.37), with: .color(accent))
                context.fill(kidney(at: 0.55), with: .color(accent))
            }
        }
    }
}

private struct DocumentSourceRow: View {
    let document: CareDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(document.name, systemImage: "doc.text").font(.headline)
            if let evidence = document.evidence {
                if let quote = evidence.quote { Text(quote).textSelection(.enabled) }
                if let date = evidence.studyDate { Text("Исследование · " + date).font(.subheadline) }
                if let page = evidence.page { Text("Страница " + String(page)).font(.footnote) }
            }
            Text("Добавлено " + document.imported.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month().year()))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CareBubble: View {
    let message: CareMessage
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.fromUser ? "Ты" : "Это ты")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.text).textSelection(.enabled)
        }.padding(12)
            .background(message.fromUser ? accent.opacity(0.13) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(message.fromUser ? "care.message.user" : "care.message.service")
    }
}

private struct ContactTimeView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var date: Date
    @ViewState private var invalidDate = false
    private let minimum: Date
    let save: (Date) -> Void

    init(previous: Date?, save: @escaping (Date) -> Void) {
        let now = Date()
        let earliest = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        let futureChoice = previous.flatMap { $0 > now ? $0 : nil }
        minimum = min(futureChoice ?? earliest, earliest)
        _date = State(initialValue: futureChoice ?? earliest.addingTimeInterval(3600))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Напомнить", selection: $date, in: minimum..., displayedComponents: [.date, .hourAndMinute])
                Text("Местное время · " + TimeZone.current.identifier)
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Сохранить время") {
                    guard date > Date() else { invalidDate = true; return }
                    save(date)
                    dismiss()
                }
                if invalidDate {
                    Text("Выбранное время уже прошло. Выбери более позднее.").foregroundStyle(.secondary)
                }
            }
            .onChange(of: date) { _, _ in invalidDate = false }
            .navigationTitle("Следующий контакт")
            .toolbar { Button("Отмена") { dismiss() } }
        }
    }
}
