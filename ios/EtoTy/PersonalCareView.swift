import SwiftUI
import QuickLook

private typealias ViewState<Value> = State<Value>

private enum CareTab { case chat, level, map }

private enum CareSheet: Hashable, Identifiable {
    case schedule(Date?), documents(Region?), prevention, intent, brief(Region?), demo
    case sourcePDF(URL, String, Int), editSource(String), incoming

    var id: Self { self }
}

struct PersonalCareView: View {
    @ObservedObject var session: CareSession
    @ObservedObject var incoming: CareIncomingDocument
    @ViewState private var tab = CareTab.chat
    @ViewState private var sheet: CareSheet?
    @ViewState private var draft = ""
    @ViewState private var region = Region.heart
    @ViewState private var photoOriginal: URL?
    @ViewState private var sourceIssue: String?
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
        .onAppear { session.refreshDocuments() }
        .sheet(item: $sheet, onDismiss: {
            session.refreshDocuments()
            presentIncomingWhenReady()
        }, content: sheetContent)
        .quickLookPreview($photoOriginal)
        .onChange(of: incoming.offer?.id, initial: true) { _, _ in presentIncomingWhenReady() }
        .onChange(of: photoOriginal) { _, _ in presentIncomingWhenReady() }
        .onChange(of: confirmingDeletion) { _, _ in presentIncomingWhenReady() }
        .alert("Удалить личный профиль из приложения?", isPresented: $confirmingDeletion) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                incoming.dismiss()
                session.deleteProfile()
                sourceIssue = nil
                photoOriginal = nil
            }
        } message: {
            Text("Будут удалены переписка и сохранённые в приложении документы. Будущее напоминание отменится.")
        }
        .onChange(of: session.plan.messages.first?.id) { _, _ in
            draft = ""
            tab = .chat
            sourceIssue = nil
            photoOriginal = nil
            sheet = nil
        }
        .onChange(of: session.contactSuggestionToken) { _, _ in
            guard let date = session.suggestedContact else { return }
            composing = false
            sheet = .schedule(date)
        }
        .onChange(of: session.openChatToken) { _, _ in
            confirmingDeletion = false
            photoOriginal = nil
            if sheet != .incoming { sheet = nil }
            composing = false
            tab = .chat
        }
    }

    private func presentIncomingWhenReady() {
        guard incoming.offer != nil, sheet == nil, photoOriginal == nil, !confirmingDeletion else { return }
        composing = false
        sheet = .incoming
    }

    @ViewBuilder private func sheetContent(_ destination: CareSheet) -> some View {
        switch destination {
        case .incoming:
            CareIncomingDocumentView(incoming: incoming, storageAvailable: !session.storageUnavailable) { document in
                sheet = nil
                if let document { session.didImportExternalDocument(document) }
            }
        case .schedule(let suggestion):
            let repeatContact = session.plan.weeklyContact
            ContactTimeView(previous: suggestion ?? session.plan.nextContact ?? repeatContact?.next(after: Date()),
                            weekly: repeatContact != nil) { date, weekly in
                if session.schedule(at: date, weekly: weekly) { return nil }
                return session.statusText ?? "Не удалось сохранить время. Попробуй ещё раз."
            }
        case .brief(let area):
            PersonalBriefView(session: session, initialArea: area)
        case .intent:
            CareIntentView(onChoose: chooseRoute)
        case .prevention:
            PersonalPreventionView(session: session, onExampleChoose: preventionAction) {
                sheet = nil
                tab = .chat
            }
        case .documents(let scope):
            CareDocumentView(region: scope)
        case .sourcePDF(let url, let name, let page):
            NavigationStack {
                SourcePDFPreview(source: SourcePDFPage(url: url, page: page))
                    .navigationTitle(name)
                    .toolbar { Button("Готово") { sheet = nil } }
            }
        case .editSource(let id):
            if let document = session.archivedDocuments.first(where: { $0.id == id }) {
                DocumentEvidenceEditor(document: document, store: CareDocuments())
            } else {
                VStack {
                    Text("Документ больше недоступен.")
                    Button("К диалогу") { sheet = nil }
                }
            }
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

    private var profileMenu: some View {
        Menu {
            Button { openBrief() } label: { Label("Сводка к приёму", systemImage: "doc.richtext") }
                .disabled(session.storageUnavailable)
            Button { sheet = .intent } label: { Label("Подобрать раздел по фразе", systemImage: "text.magnifyingglass") }
            Button { sheet = .prevention } label: { Label("Подготовиться к профилактическому приёму", systemImage: "book") }
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
                        if !session.plan.isAskingForUrgentHelp && !session.storageUnavailable {
                            Button("Что проверить?") { sheet = .prevention }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("care.preparation.open")
                        }
                        if session.plan.topic != nil && !session.plan.isAskingForUrgentHelp {
                            agenda
                        }
                        if !session.plan.isAskingForUrgentHelp, let query = CareHistoryQuery.latest(in: session.plan) {
                            if session.archiveAvailable {
                                CareHistoryResultsView(query: query, documents: session.archivedDocuments) { document in
                                    openOriginal(id: document.id, page: document.evidence?.page)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Сейчас не удаётся прочитать архив документов.")
                                    Button("Повторить поиск") { session.refresh() }
                                        .accessibilityIdentifier("care.history.retry")
                                }
                            }
                        }
                        if let suggestion = session.documentSuggestion {
                            followUpCard(suggestion)
                        }
                        if let id = session.lastExternalDocumentID, id != session.documentSuggestion?.documentID,
                           let document = session.archivedDocuments.first(where: { $0.id == id }) {
                            VStack(alignment: .leading) {
                                Text("Документ в архиве").font(.headline)
                                sourceButton(id: id, name: document.name, page: document.evidence?.page)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest").accessibilityHidden(true)
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: session.plan.messages.last?.id) { _, _ in
                    proxy.scrollTo("latest", anchor: .bottom)
                }
                .onChange(of: session.documentSuggestion?.id) { _, newID in
                    if newID != nil { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: session.openChatToken) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
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
        if let sourceIssue {
            HStack {
                Label(sourceIssue, systemImage: "doc.badge.ellipsis").font(.callout)
                Button("Закрыть") { self.sourceIssue = nil }
            }.padding(.horizontal)
        }
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
            if let source = session.activeDocumentSource {
                Text("Документ по этой теме").font(.subheadline.weight(.semibold))
                sourceButton(id: source.id, name: source.name, page: source.evidence?.page)
                    .accessibilityIdentifier("care.linkedSource")
                if source.evidence?.quote == nil {
                    reviewButton(id: source.id)
                        .accessibilityIdentifier("care.linkedSource.review")
                }
            }
            Label("Следующий контакт", systemImage: "calendar").font(.headline)
            Text(contactDescription).font(.subheadline)
            if let weekly = session.plan.weeklyContact {
                Label("Каждую неделю · " + weekly.displayText, systemImage: "repeat")
                    .font(.subheadline)
                    .accessibilityIdentifier("care.agenda.weekly")
                if session.plan.hasDueQuestion {
                    Text("После ответа вернёмся к делу в следующий указанный день недели.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Отключить повторение") { session.stopWeeklyContacts() }
                    .accessibilityLabel("Отключить еженедельные вопросы")
                    .accessibilityHint(session.plan.nextContact == nil
                        ? "Новые вопросы по этому расписанию приходить не будут."
                        : "Ближайший назначенный вопрос останется в плане.")
                    .accessibilityIdentifier("care.agenda.stopWeekly")
                    .disabled(session.storageUnavailable)
            }
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
                            Button("Сводка к приёму") { openBrief() }
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

    private func followUpCard(_ suggestion: CareDocumentFollowUp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestion.title).font(.headline)
            if let quote = suggestion.quote {
                Text("«" + quote + "»").font(.callout).textSelection(.enabled)
            }
            if let studyDate = suggestion.studyDate {
                Text("Дата исследования · " + studyDate).font(.footnote).foregroundStyle(.secondary)
            }
            sourceButton(id: suggestion.documentID, name: suggestion.documentName, page: suggestion.page)
                .accessibilityIdentifier("care.suggestion.source")
            Text(suggestion.action)
            if !suggestion.isReviewed {
                reviewButton(id: suggestion.documentID)
                    .accessibilityIdentifier("care.suggestion.review")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { followUpActions(suggestion) }
                VStack(alignment: .leading, spacing: 8) { followUpActions(suggestion) }
            }
        }.padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private func followUpActions(_ suggestion: CareDocumentFollowUp) -> some View {
        Button(session.plan.topic != nil && !session.plan.isClosed ? "Связать с текущим делом" : "Добавить в план") {
            session.acceptDocumentSuggestion(suggestion)
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("care.suggestion.accept")
        Button("Скрыть") { session.dismissDocumentSuggestion(suggestion) }
            .accessibilityIdentifier("care.suggestion.dismiss")
    }

    private func sourceButton(id: String, name: String, page: Int?) -> some View {
        let caption = name + (page.map { " · стр. " + String($0) } ?? "")
        return Button {
            openOriginal(id: id, page: page)
        } label: {
            Label(caption, systemImage: "doc.text.magnifyingglass").multilineTextAlignment(.leading)
        }
        .accessibilityLabel("Открыть оригинал: " + caption)
    }

    private func reviewButton(id: String) -> some View {
        Button("Разобрать страницу") {
            composing = false
            sheet = .editSource(id)
        }
    }

    private func openOriginal(id: String, page: Int?) {
        sourceIssue = nil
        composing = false
        guard let document = session.archivedDocuments.first(where: { $0.id == id }) else {
            sourceIssue = "Оригинал недоступен. Проверь, сохранился ли он в архиве."
            session.refreshDocuments()
            return
        }
        do {
            let url = try session.originalURL(for: document)
            if document.kind == .pdf { sheet = .sourcePDF(url, document.name, page ?? 1) }
            else { photoOriginal = url }
        } catch {
            sourceIssue = "Не удалось открыть оригинал. Попробуй ещё раз после разблокировки устройства."
            session.refreshDocuments()
        }
    }

    private func chooseRoute(_ route: CareIntentRoute) {
        switch route {
        case .documents:
            sheet = .documents(nil)
        case .prevention:
            sheet = .prevention
        case .visitPreparation:
            openBrief()
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

    private var preventionAction: ((String) -> Bool)? {
        guard !session.storageUnavailable, session.plan.canStartPreparationGoal else { return nil }
        return { goal in
            guard session.plan.canStartPreparationGoal else { return false }
            session.send(goal)
            guard session.plan.topic == goal, !session.plan.isClosed else { return false }
            sheet = nil
            tab = .chat
            return true
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
                if session.archiveAvailable {
                    mapProgress
                } else {
                    Label("Архив сейчас недоступен. Уровень изученности обновится после чтения документов.", systemImage: "folder.badge.questionmark")
                    Button("Повторить") { session.refresh() }
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
                } else if session.archiveAvailable && session.archivedDocuments.isEmpty {
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
        .onAppear(perform: session.refreshDocuments)
    }

    private var mapProgress: some View {
        let rows = Region.allCases.map { CareMapRegion($0, documents: session.archivedDocuments) }
        let dated = rows.compactMap(\.latestDatedSource)
        return VStack(alignment: .leading, spacing: 10) {
            if let document = dated.max(by: CareMapRegion.earlierStudy) {
                Text("Уровень 2 · Есть датированный источник").font(.title2.bold())
                Text("Последнее исследование среди сверенных фрагментов")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { openOriginal(id: document.id, page: document.evidence?.page) } label: {
                    DocumentSourceRow(document: document)
                }.buttonStyle(.plain)
            } else if !session.archivedDocuments.isEmpty || session.plan.topic != nil {
                Text("Уровень 1 · Начало истории").font(.title2.bold())
                Text("Для уровня 2 привяжи документ к области карты и сверь в нём фрагмент с датой исследования.")
                    .font(.callout)
            }
            Text("Области со сверенным фрагментом и датой: " + String(dated.count) + " из " + String(rows.count))
                .font(.headline)
            ForEach(rows) { row in
                Button {
                    region = row.area
                    tab = .map
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.area.rawValue)
                            Text(row.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
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
                if session.archiveAvailable {
                    let coverage = CareMapRegion(region, documents: session.archivedDocuments)
                    Text(coverage.summary).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(coverage.documents) { document in
                        Button { openOriginal(id: document.id, page: document.evidence?.page) } label: {
                            DocumentSourceRow(document: document)
                        }.buttonStyle(.plain)
                    }
                } else {
                    Text("Сведения о документах пока недоступны.").foregroundStyle(.secondary)
                }
                Button { sheet = .documents(region) } label: { Label("Документы этой области", systemImage: "doc") }
                    .buttonStyle(.bordered).disabled(session.storageUnavailable)
                Button { openBrief(for: region) } label: { Label("Сводка к приёму", systemImage: "doc.richtext") }
                    .disabled(session.storageUnavailable)
                Button("Обсудить в диалоге") {
                    if draft.isEmpty { draft = "Хочу обсудить тему «" + region.rawValue + "»." }
                    tab = .chat
                    composing = true
                }.disabled(session.storageUnavailable)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: session.refreshDocuments)
    }

    private func openBrief(for area: Region? = nil) {
        composing = false
        session.refreshDocuments()
        sheet = .brief(area)
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
    @ViewState private var weekly: Bool
    @ViewState private var saveIssue: String?
    private let minimum: Date
    let save: (Date, Bool) -> String?

    init(previous: Date?, weekly: Bool, save: @escaping (Date, Bool) -> String?) {
        let now = Date()
        let earliest = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        let futureChoice = previous.flatMap { $0 > now ? $0 : nil }
        minimum = min(futureChoice ?? earliest, earliest)
        _date = State(initialValue: futureChoice ?? earliest.addingTimeInterval(3600))
        _weekly = State(initialValue: weekly)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Напомнить", selection: $date, in: minimum..., displayedComponents: [.date, .hourAndMinute])
                Text("Местное время · " + TimeZone.current.identifier)
                    .font(.footnote).foregroundStyle(.secondary)
                Section {
                    Toggle("Каждую неделю", isOn: $weekly)
                        .accessibilityIdentifier("care.schedule.weekly")
                } footer: {
                    if weekly {
                        let slot = date.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).weekday(.wide).hour().minute())
                        Text("Каждую неделю · " + slot + ". После твоего ответа вернёмся к делу в следующий такой день. Пока ответа нет, приложение подождёт.")
                    } else {
                        Text("Вопрос придёт один раз в выбранное время.")
                    }
                }
                Button("Сохранить время") {
                    guard date > Date() else {
                        saveIssue = "Выбранное время уже прошло. Выбери более позднее."
                        return
                    }
                    saveIssue = save(date, weekly)
                    if saveIssue == nil { dismiss() }
                }
                .accessibilityIdentifier("care.schedule.save")
                if let saveIssue {
                    Text(saveIssue).foregroundStyle(.secondary)
                }
            }
            .onChange(of: date) { _, _ in saveIssue = nil }
            .onChange(of: weekly) { _, _ in saveIssue = nil }
            .navigationTitle("Следующий контакт")
            .toolbar { Button("Отмена") { dismiss() } }
        }
    }
}
