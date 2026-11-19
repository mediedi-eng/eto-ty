ObjC.import("Foundation");

function run(argv) {
    const raw = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (!raw || !raw.js) throw new Error("Source file missing");
    const api = Function(raw.js + "\nreturn { nextContact, timeChoices, checkIn };")();
    let checks = 0;
    function assert(condition, message) {
        if (!condition) throw new Error(message);
        checks++;
    }
    const now = new Date(2026, 0, 31, 23, 59);
    assert(api.nextContact(api.timeChoices[0], now) - now === 120000, "two minutes");
    assert(api.nextContact(api.timeChoices[1], now) - now === 3600000, "one hour");
    assert(+api.nextContact(api.timeChoices[2], now) === +new Date(2026, 1, 1, 10), "tomorrow");
    assert(+api.nextContact(api.timeChoices[3], now) === +new Date(2026, 1, 7, 10), "next week");
    assert(now.getMonth() === 0, "input date unchanged");

    const saved = [], alerts = [];
    let listCount = 0, opened = 0, choices = [], input = "";
    const list = {exists: () => listCount > 0, reminders: {push: row => saved.push(row)}};
    const lists = {byName: () => list, push: () => listCount++};
    const reminders = {defaultAccount: () => ({lists}), List: x => x, Reminder: x => x,
        activate: () => {}, show: () => opened++};
    const ui = {chooseFromList: () => choices.shift(), displayDialog: () => ({textReturned: input}),
        displayAlert: title => alerts.push(title)};
    function exercise(answers, topic) {
        choices = answers;
        input = topic;
        api.checkIn(ui, reminders);
    }
    exercise([false], "");
    exercise([["Открыть мои договорённости"]], "");
    exercise([["Поручить вопрос"]], "  ");
    exercise([["Поручить вопрос"], false], "test");
    assert(!saved.length && !listCount, "cancel and empty paths do not create data");
    assert(opened === 0, "absent list");
    const start = Date.now();
    exercise([["Поручить вопрос"], [api.timeChoices[0]]], "  example? ");
    assert(saved[0].body === "example?", "persisted question");
    assert(+saved[0].dueDate >= start + 120000 && +saved[0].dueDate === +saved[0].remindMeDate, "alarm and due date");
    exercise([["Поручить вопрос"], [api.timeChoices[1]]], "another?");
    assert(listCount === 1 && saved.length === 2, "reuse list");
    exercise([["Открыть мои договорённости"]], "");
    assert(opened === 1 && saved.length === 2, "open existing list");
    return checks + " checks passed";
}
