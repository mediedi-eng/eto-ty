// macOS supplies the dialog and stores the scheduled notification in Reminders.
const project = "Это ты";
const listName = "Это ты · сопровождение";
const timeChoices = ["Через 2 минуты", "Через час", "Завтра в 10:00", "Через неделю в 10:00"];

function nextContact(choice, now) {
    const date = new Date(now.getTime());
    if (choice === timeChoices[0]) return new Date(date.getTime() + 2 * 60000);
    if (choice === timeChoices[1]) return new Date(date.getTime() + 60 * 60000);
    if (choice !== timeChoices[2] && choice !== timeChoices[3]) {
        throw new Error("Выберите срок из списка.");
    }
    date.setDate(date.getDate() + (choice === timeChoices[2] ? 1 : 7));
    date.setHours(10, 0, 0, 0);
    return date;
}

function choose(ui, question, choices) {
    const answer = ui.chooseFromList(choices, {
        withTitle: project, withPrompt: question, okButtonName: "Выбрать",
        cancelButtonName: "Отмена"
    });
    return answer ? answer[0] : null;
}

function checkIn(ui, reminders) {
    const action = choose(ui, "Что хочешь сделать?", ["Поручить вопрос", "Открыть мои договорённости"]);
    if (!action) return;

    const account = reminders.defaultAccount();
    const listRef = account.lists.byName(listName);
    if (action === "Открыть мои договорённости") {
        if (!listRef.exists()) {
            ui.displayAlert("Пока нет договорённостей", {message: "Начни с одного вопроса, к которому хочешь вернуться."});
            return;
        }
        reminders.activate();
        reminders.show(listRef);
        return;
    }

    const answer = ui.displayDialog("Какой вопрос задать тебе, когда придёт время?", {
        withTitle: project, defaultAnswer: "", buttons: ["Отмена", "Дальше"],
        cancelButton: "Отмена", defaultButton: "Дальше"
    });
    const topic = answer.textReturned.trim();
    if (!topic) {
        ui.displayAlert("Нужен текст вопроса", {message: "Например, «На сколько вечеров за неделю мне хватило сил?»"});
        return;
    }
    const choice = choose(ui, "Когда вернуться к этому вопросу?", timeChoices);
    if (!choice) return;
    if (!listRef.exists()) account.lists.push(reminders.List({name: listName}));
    const contact = nextContact(choice, new Date());
    const reminder = reminders.Reminder({
        name: "Это ты · время вернуться к вопросу", body: topic,
        dueDate: contact, remindMeDate: contact
    });
    listRef.reminders.push(reminder);
    ui.displayAlert("Договорились", {message: topic + "\n\nНапоминание сохранено на " +
        contact.toLocaleString("ru-RU") + ". В «Напоминаниях» можно записать ответ, перенести срок или закрыть вопрос."});
}

function run() {
    const ui = Application.currentApplication();
    ui.includeStandardAdditions = true;
    try {
        checkIn(ui, Application("com.apple.reminders"));
    } catch (error) {
        if (error.errorNumber === -128) return;
        const message = error.errorNumber === -1743 ?
            "Разреши терминалу управлять «Напоминаниями» в настройках macOS → Конфиденциальность и безопасность → Автоматизация." :
            "Проверь, что «Напоминания» открываются и настроена учётная запись. Подробности macOS: " + error.message;
        ui.displayAlert("Не удалось завершить действие", {message: message + "\nПроверь список перед повтором."});
    }
}
