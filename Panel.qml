pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "bszwakop.commands"
    ipcTarget: "bszwakop.commands"
    manageIpc: false

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    property var commands: []
    property var rows: []
    property var groupNames: []
    property var groupTabs: ["Wszystkie"]
    property var machineSettings: ({apiBase: "", tokenSet: false, layout: "auto", syncConfigured: false})
    property var currentCommand: null
    property var pendingCommand: null
    property var pendingValues: ({})
    property var pending: []
    property var syncRows: []
    property var syncSummary: ({})
    property var placeholderNames: []
    property var placeholderValues: []
    property var focusIds: []

    property string page: "list"
    property string query: ""
    property string groupFilter: ""
    property string groupOriginal: ""
    property string note: ""
    property string formNote: ""
    property string tipText: "Komendy"
    property string syncToken: ""
    property string editId: ""
    property string askDraft: ""
    property string layoutDraft: "auto"
    property int selectedIndex: 0
    property int quickIndex: 0
    property int wheelIndex: -1
    property int fieldEpoch: 0
    property bool loaded: false
    property bool editPinned: false
    property bool dangerDraft: false
    property bool pendingPaste: false
    property bool quickMenuOpen: false
    property bool saving: false
    property bool applyingAsk: false
    property bool syncQuiet: false

    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color dim: Qt.darker(foreground, 1.55)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property bool wide: {
        var layout = machineSettings.layout || "auto"
        if (layout === "wide") return true
        if (layout === "compact") return false
        return card.availableCardWidth >= Style.space(760)
    }
    readonly property int listCardHeight: Style.space(440) + Style.space(168)
    readonly property string shownTip: {
        var pins = pinnedCommands()
        if (wheelIndex >= 0 && wheelIndex < pins.length) return pins[wheelIndex].title
        return tipText
    }

    function pinnedCommands() {
        var pins = []
        for (var i = 0; i < commands.length; i++)
            if (commands[i].pinned) pins.push(commands[i])
        return pins
    }

    function rebuild() {
        var next = []
        var needle = query.trim().toLowerCase()
        var seen = {}
        var names = []
        var keep = currentCommand ? currentCommand.id : ""
        for (var g = 0; g < groupNames.length; g++) {
            var known = groupNames[g]
            seen[known.toLowerCase()] = true
            names.push(known)
        }
        for (var i = 0; i < commands.length; i++) {
            var command = commands[i]
            var group = command.group || "Ogólne"
            if (!seen[group.toLowerCase()]) {
                seen[group.toLowerCase()] = true
                names.push(group)
            }
            if (groupFilter !== "" && group.toLowerCase() !== groupFilter.toLowerCase()) continue
            if (focusIds.length > 0) {
                var allowed = false
                for (var f = 0; f < focusIds.length; f++)
                    if (focusIds[f] === command.id) allowed = true
                if (!allowed) continue
            }
            var tags = command.tags ? command.tags.join(" ") : ""
            var hay = (command.title + " " + command.command + " " + command.body + " " + tags + " " + group).toLowerCase()
            if (needle !== "" && hay.indexOf(needle) < 0) continue
            next.push(command)
        }
        var found = 0
        for (var j = 0; j < next.length; j++)
            if (next[j].id === keep) found = j
        var filterKnown = groupFilter === ""
        for (var n = 0; n < names.length; n++)
            if (names[n].toLowerCase() === groupFilter.toLowerCase()) filterKnown = true
        if (!filterKnown) groupFilter = ""
        rows = next
        groupTabs = ["Wszystkie"].concat(names)
        var pinned = 0
        for (var k = 0; k < commands.length; k++)
            if (commands[k].pinned) pinned++
        tipText = "Komendy: " + commands.length + "  ·  przypięte: " + pinned
        selectIndex(next.length === 0 ? 0 : found)
    }

    function selectIndex(index) {
        if (rows.length === 0) {
            selectedIndex = 0
            currentCommand = null
            return
        }
        if (index < 0) index = 0
        if (index >= rows.length) index = rows.length - 1
        selectedIndex = index
        currentCommand = rows[index]
        Qt.callLater(function() { root.revealRow(index) })
    }

    function commandPreview(text) {
        var raw = text ? String(text) : ""
        var newline = raw.indexOf("\n")
        if (newline < 0) return raw
        return raw.slice(0, newline) + "  …"
    }

    function revealRow(index) {
        if (!commandColumn || index < 0 || index >= commandColumn.children.length) return
        var item = commandColumn.children[index]
        if (!item) return
        var y = item.y
        if (y < commandList.contentY) commandList.contentY = y
        else if (y + item.height > commandList.contentY + commandList.height)
            commandList.contentY = Math.max(0, y + item.height - commandList.height)
    }

    function move(step) {
        if (rows.length === 0) return
        selectIndex(selectedIndex + step)
    }

    function setGroup(name) {
        focusIds = []
        groupFilter = name
        rebuild()
    }

    function cycleGroup(direction) {
        var tabs = groupTabs
        var current = groupFilter === "" ? "Wszystkie" : groupFilter
        var index = 0
        for (var i = 0; i < tabs.length; i++)
            if (tabs[i] === current) index = i
        var next = (index + direction + tabs.length) % tabs.length
        setGroup(tabs[next] === "Wszystkie" ? "" : tabs[next])
    }

    function applyList(result) {
        commands = result.commands || []
        groupNames = result.groups || []
        if (result.settings) machineSettings = result.settings
        loaded = true
        rebuild()
    }

    function showList() {
        formNote = ""
        page = "list"
        Qt.callLater(function() { searchField.forceActiveFocus() })
    }

    function call(payload) {
        var queued = pending.slice()
        queued.push(payload)
        pending = queued
        pump()
    }

    function pump() {
        if (request.running || pending.length === 0) return
        var payload = pending[0]
        pending = pending.slice(1)
        request.operation = payload.op
        request.payload = JSON.stringify(payload)
        request.running = true
        requestGuard.restart()
    }

    function beginDeliver(command, paste) {
        if (!command) return
        pendingCommand = command
        pendingPaste = paste
        pendingValues = ({})
        if (command.danger) {
            page = "danger"
            if (!opened) open()
            Qt.callLater(function() { keyScope.forceActiveFocus() })
            return
        }
        var names = command.placeholders || []
        if (names.length > 0) {
            placeholderNames = names
            var blanks = []
            for (var i = 0; i < names.length; i++) blanks.push("")
            placeholderValues = blanks
            fieldEpoch++
            page = "fields"
            if (!opened) open()
            return
        }
        sendDeliver({})
    }

    function sendDeliver(values) {
        if (!pendingCommand) return
        pendingValues = values
        var payload = {
            op: "deliver",
            id: pendingCommand.id,
            mode: pendingPaste ? "paste" : "copy",
            values: values,
            confirmDanger: pendingCommand.danger === true
        }
        if (pendingPaste) {
            pasteTimer.payload = JSON.stringify(payload)
            close()
            pasteTimer.start()
        } else {
            call(payload)
        }
    }

    function collectFields() {
        var values = {}
        for (var i = 0; i < placeholderNames.length; i++)
            values[placeholderNames[i]] = placeholderValues[i] || ""
        return values
    }

    function copySelected(paste, dismiss) {
        if (rows.length === 0) return
        var index = selectedIndex
        if (index < 0 || index >= rows.length) index = 0
        selectIndex(index)
        beginDeliver(rows[index], paste)
        if (dismiss && page === "list") close()
    }

    function togglePin(command) {
        if (!command) return
        call({op: "pin", id: command.id, pinned: !command.pinned})
    }

    function newCommand() {
        var seed = askDraft || query.trim()
        editId = ""
        editPinned = false
        dangerDraft = false
        titleField.text = seed
        groupField.text = groupFilter
        tagsField.text = ""
        commandField.text = ""
        bodyField.text = ""
        askDraft = ""
        query = ""
        formNote = ""
        page = "edit"
        Qt.callLater(function() { titleField.forceActiveFocus() })
    }

    function editCurrent() {
        if (!currentCommand) return
        var command = currentCommand
        editId = command.id
        editPinned = command.pinned === true
        dangerDraft = command.danger === true
        titleField.text = command.title
        groupField.text = command.group || ""
        tagsField.text = command.tags ? command.tags.join(", ") : ""
        commandField.text = command.command
        bodyField.text = command.body || ""
        formNote = ""
        page = "edit"
        Qt.callLater(function() { titleField.forceActiveFocus() })
    }

    function saveForm() {
        if (saving) return
        if (titleField.text.trim() === "" || commandField.text.trim() === "") {
            formNote = "Podaj tytuł i komendę."
            return
        }
        saving = true
        formNote = "Zapisuję…"
        var tags = []
        var parts = tagsField.text.split(",")
        for (var i = 0; i < parts.length; i++)
            if (parts[i].trim() !== "") tags.push(parts[i].trim())
        call({op: "save", command: {
            id: editId,
            title: titleField.text,
            group: groupField.text,
            tags: tags,
            command: commandField.text,
            body: bodyField.text,
            danger: dangerDraft,
            pinned: editPinned
        }})
    }

    function openSettings() {
        layoutDraft = machineSettings.layout || "auto"
        apiField.text = machineSettings.apiBase || ""
        tokenField.text = ""
        page = "settings"
        Qt.callLater(function() { apiField.forceActiveFocus() })
    }

    function saveSettings() {
        var payload = {op: "saveSettings", apiBase: apiField.text, layout: layoutDraft}
        if (tokenField.text !== "") payload.token = tokenField.text
        call(payload)
    }

    function submitAsk() {
        var question = askField.text.trim()
        if (question === "") return
        formNote = "Szukam…"
        note = ""
        call({op: "ask", question: question})
    }

    function synchronize(quiet) {
        syncQuiet = quiet === true
        if (!machineSettings.syncConfigured || !machineSettings.tokenSet) {
            syncQuiet = false
            if (quiet === true) return
            note = "W ustawieniach podaj adres i klucz biblioteki."
            noteTimer.restart()
            openSettings()
            return
        }
        if (syncQuiet) {
            call({op: "sync"})
            return
        }
        note = "Synchronizuję…"
        call({op: "sync"})
    }

    function askFromQuery() {
        var question = query.trim()
        if (question === "") {
            formNote = ""
            page = "ask"
            Qt.callLater(function() { askField.forceActiveFocus() })
            return
        }
        note = "Szukam…"
        formNote = ""
        call({op: "ask", question: question})
    }

    function finishAsk(result) {
        askField.text = ""
        applyingAsk = true
        if (result.match) {
            askDraft = ""
            focusIds = []
            query = ""
            groupFilter = ""
            applyingAsk = false
            rebuild()
            for (var i = 0; i < rows.length; i++) {
                if (rows[i].id === result.match.id) selectIndex(i)
            }
            note = "Dopasowano: " + result.match.title
            showList()
        } else if (result.candidates && result.candidates.length > 0) {
            var ids = []
            for (var c = 0; c < result.candidates.length; c++)
                ids.push(result.candidates[c].id)
            askDraft = ""
            query = ""
            groupFilter = ""
            focusIds = ids
            applyingAsk = false
            rebuild()
            selectIndex(0)
            note = "Pasuje kilka komend"
            showList()
        } else {
            applyingAsk = false
            focusIds = []
            askDraft = result.question || ""
            note = "Nie ma jej w katalogu. N doda szkic z tym pytaniem."
            showList()
        }
        noteTimer.restart()
    }

    function openGroups() {
        groupOriginal = ""
        groupNameField.text = ""
        page = "groups"
        Qt.callLater(function() { groupNameField.forceActiveFocus() })
    }

    function saveGroup() {
        var name = groupNameField.text.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
        groupNameField.text = name
        call({op: "saveGroup", name: name, previous: groupOriginal})
    }

    function groupCount(name) {
        var folded = name.toLowerCase()
        var count = 0
        for (var i = 0; i < commands.length; i++)
            if ((commands[i].group || "").toLowerCase() === folded) count++
        return count
    }

    function claimSaveKey(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (!ctrl || (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)) return false
        if (page === "edit") saveForm()
        else if (page === "groups") saveGroup()
        else if (page === "settings") saveSettings()
        else if (page === "fields") sendDeliver(collectFields())
        else return false
        event.accepted = true
        return true
    }

    function formKey(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            if (page === "edit") saveForm()
            else if (page === "groups") saveGroup()
            else if (page === "settings") saveSettings()
            else if (page === "fields") sendDeliver(collectFields())
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Escape) {
            showList()
            event.accepted = true
        }
    }

    function handleListKey(event) {
        var key = event.key
        var text = event.text || ""
        var mods = event.modifiers
        if ((mods & Qt.AltModifier) !== 0) {
            var letter = text.toLowerCase()
            if (key === Qt.Key_N) letter = "n"
            else if (key === Qt.Key_E) letter = "e"
            else if (key === Qt.Key_P) letter = "p"
            else if (key === Qt.Key_A) letter = "a"
            else if (key === Qt.Key_G) letter = "g"
            if (letter === "n") newCommand()
            else if (letter === "e") editCurrent()
            else if (letter === "p") togglePin(currentCommand)
            else if (letter === "g") openGroups()
            else if (letter === "a") {
                formNote = ""
                page = "ask"
                Qt.callLater(function() { askField.forceActiveFocus() })
            } else return false
            return true
        }
        if (searchField.activeFocus) return false
        if ((mods & (Qt.ControlModifier | Qt.MetaModifier)) !== 0) return false
        if (key === Qt.Key_Escape) {
            if (query !== "") query = ""
            else close()
            return true
        }
        if (key === Qt.Key_Backspace) {
            query = query.slice(0, -1)
            return true
        }
        if (key === Qt.Key_Delete) {
            if (query === "" && currentCommand) page = "remove"
            else query = query.slice(0, -1)
            return true
        }
        if (key === Qt.Key_Up) { move(-1); return true }
        if (key === Qt.Key_Down) { move(1); return true }
        if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
            cycleGroup(key === Qt.Key_Backtab ? -1 : 1)
            return true
        }
        if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            copySelected((mods & Qt.ShiftModifier) !== 0, true)
            return true
        }
        if (text.length === 1 && text.trim() !== "") {
            query += text
            Qt.callLater(function() { searchField.forceActiveFocus() })
            return true
        }
        return false
    }

    function handleConfirmKey(event) {
        if (event.key === Qt.Key_Escape) {
            showList()
            return true
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (page === "danger") {
                sendDeliver(pendingValues)
                close()
            }
            else if (page === "remove" && currentCommand) call({op: "delete", id: currentCommand.id})
            if (page === "remove") showList()
            return true
        }
        return false
    }

    function quickItems() {
        var pins = pinnedCommands()
        var items = []
        var limit = Math.min(pins.length, 8)
        for (var i = 0; i < limit; i++)
            items.push({kind: "command", command: pins[i], label: pins[i].title, key: String(i + 1)})
        items.push({kind: "new", label: "Nowa komenda", key: ""})
        items.push({
            kind: "open",
            label: pins.length ? "Otwórz katalog" : "Otwórz katalog",
            key: ""
        })
        return items
    }

    function runQuick(item) {
        quickMenuOpen = false
        if (!item) return
        if (item.kind === "new") {
            newCommand()
            if (!opened) open()
        } else if (item.kind === "open") open()
        else beginDeliver(item.command, false)
    }

    function toggleQuick() {
        if (quickMenuOpen) {
            quickMenuOpen = false
            return
        }
        if (opened) close()
        quickIndex = 0
        quickMenuOpen = true
        Qt.callLater(function() { quickKeys.forceActiveFocus() })
    }

    onQueryChanged: {
        if (!applyingAsk) focusIds = []
        rebuild()
    }
    onOpenedChanged: if (opened) {
        quickMenuOpen = false
        if (!loaded) call({op: "list"})
        if (page === "list") Qt.callLater(function() { searchField.forceActiveFocus() })
        else if (page === "danger" || page === "remove")
            Qt.callLater(function() { keyScope.forceActiveFocus() })
    }
    Component.onCompleted: call({op: "list"})

    Timer {
        id: noteTimer
        interval: 5000
        onTriggered: root.note = ""
    }
    Timer {
        id: requestGuard
        interval: 70000
        onTriggered: request.signal(9)
    }
    Timer {
        id: pasteTimer
        interval: 250
        property string payload: ""
        onTriggered: {
            if (payload !== "") root.call(JSON.parse(payload))
            payload = ""
        }
    }
    Timer {
        id: syncTimer
        interval: 300000
        repeat: true
        triggeredOnStart: true
        running: root.loaded && root.machineSettings.syncConfigured && root.machineSettings.tokenSet
        onTriggered: root.synchronize(true)
    }

    Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        enabled: root.opened && (root.page === "edit" || root.page === "groups" || root.page === "settings" || root.page === "fields")
        context: Qt.ApplicationShortcut
        onActivated: {
            if (root.page === "edit") root.saveForm()
            else if (root.page === "groups") root.saveGroup()
            else if (root.page === "settings") root.saveSettings()
            else if (root.page === "fields") root.sendDeliver(root.collectFields())
        }
    }

    Process {
        id: request
        property string payload: ""
        property string operation: ""
        command: ["python3", root.helperPath]
        stdinEnabled: true
        onStarted: { write(payload + "\n"); payload = "" }
        stdout: StdioCollector { id: requestStdout; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            requestGuard.stop()
            var reply = (requestStdout.text || "").trim()
            var lines = reply === "" ? [] : reply.split("\n")
            var op = operation
            try {
                if (lines.length === 0) throw new Error("Helper nie odpowiedział")
                var result = JSON.parse(lines[lines.length - 1])
                if (!result || result.ok !== true) throw new Error(result && result.error ? result.error : "Błąd katalogu")
                root.handleResult(op, result)
            } catch (error) {
                root.saving = false
                if (op === "sync" && root.syncQuiet) {
                    root.syncQuiet = false
                } else {
                    var message = String(error.message || error)
                    if (root.page === "edit" || root.page === "groups" || root.page === "settings" || root.page === "ask") root.formNote = message
                    root.note = message
                    noteTimer.restart()
                }
            }
            Qt.callLater(root.pump)
        }
    }

    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("helper.py").toString().replace(/^file:\/\//, ""))

    function handleResult(op, result) {
        if (result.commands) applyList(result)
        if (op === "deliver") {
            note = (result.delivered === "paste" ? "Wklejono: " : "Skopiowano: ") + result.message
            noteTimer.restart()
        } else if (op === "previewSync") {
            syncToken = result.token || ""
            syncRows = result.rows || []
            syncSummary = result.summary || {}
            page = "sync"
        } else if (op === "pushSync") {
            note = "Wysłano katalog"
            noteTimer.restart()
        } else if (op === "sync") {
            var added = result.summary && result.summary.added ? result.summary.added : 0
            var updated = result.summary && result.summary.updated ? result.summary.updated : 0
            var quiet = syncQuiet
            syncQuiet = false
            if (quiet && added + updated === 0) return
            note = added + updated === 0
                ? "Zsynchronizowano"
                : "Zsynchronizowano. Nowe: " + added + ", nowsze z serwera: " + updated
            noteTimer.restart()
            if (!quiet) showList()
        } else if (op === "ask") {
            finishAsk(result)
        } else         if (op === "save" || op === "saveSettings") {
            saving = false
            showList()
        } else if (op === "saveGroup") {
            groupFilter = groupNameField.text
            rebuild()
            showList()
        } else if (op === "applySync") {
            note = "Pobrano zmiany"
            noteTimer.restart()
            showList()
        } else if (op === "delete") {
            showList()
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: ""
        tooltipText: root.shownTip
        dimmed: request.running && request.operation === "ask"
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.MiddleButton) root.call({op: "list"})
            else if (buttonCode === Qt.RightButton) root.toggleQuick()
            else { root.quickMenuOpen = false; root.toggle() }
        }
        onWheelMoved: function(delta) {
            var pins = root.pinnedCommands()
            if (pins.length === 0) return
            var step = delta > 0 ? -1 : 1
            var index = root.wheelIndex < 0 ? 0 : root.wheelIndex
            root.wheelIndex = (index + step + pins.length) % pins.length
        }
    }

    QtObject {
        id: quickOwner
        function close() { root.quickMenuOpen = false }
    }

    PopupCard {
        id: quickMenu
        anchorItem: button
        owner: quickOwner
        bar: root.bar
        open: root.quickMenuOpen
        contentWidth: quickMenu.fittedContentWidth(Style.space(280))
        contentHeight: quickMenu.fittedContentHeight(quickColumn.implicitHeight)

        FocusScope {
            id: quickKeys
            anchors.fill: parent
            focus: root.quickMenuOpen
            Keys.onPressed: function(event) {
                var items = root.quickItems()
                if (event.key === Qt.Key_Escape) root.quickMenuOpen = false
                else if (event.key === Qt.Key_Down) root.quickIndex = Math.min(items.length - 1, root.quickIndex + 1)
                else if (event.key === Qt.Key_Up) root.quickIndex = Math.max(0, root.quickIndex - 1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.runQuick(items[root.quickIndex])
                else if (event.text >= "1" && event.text <= "9") {
                    var picked = Number(event.text) - 1
                    if (picked < items.length && items[picked].kind === "command") root.runQuick(items[picked])
                } else return
                event.accepted = true
            }

            ColumnLayout {
                id: quickColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(2)

                Repeater {
                    model: root.quickMenuOpen ? root.quickItems() : []
                    delegate: CursorSurface {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        implicitHeight: Style.space(36)
                        hasCursor: root.quickIndex === index
                        foreground: root.foreground

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(8)
                            anchors.rightMargin: Style.space(8)
                            Text {
                                text: modelData.key || "›"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                Layout.preferredWidth: Style.space(16)
                            }
                            Text {
                                text: modelData.label
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.quickIndex = index
                            onClicked: root.runQuick(modelData)
                        }
                    }
                }
            }
        }
    }

    KeyboardPanel {
        id: card
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: root.page === "list" ? searchField : keyScope
        contentWidth: card.fittedContentWidth(Style.space(root.wide ? 860 : 440))
        contentHeight: card.fittedContentHeight(root.page === "list" ? root.listCardHeight : Style.space(620), Style.space(700))

        FocusScope {
            id: keyScope
            anchors.fill: parent
            focus: root.opened && !root.quickMenuOpen && (root.page === "list" || root.page === "danger" || root.page === "remove")
            Keys.onShortcutOverride: function(event) { root.claimSaveKey(event) }
            Keys.onPressed: function(event) {
                if (root.page === "list") event.accepted = root.handleListKey(event)
                else event.accepted = root.handleConfirmKey(event)
            }

            ColumnLayout {
                anchors.fill: parent
                visible: root.page === "list"
                spacing: Style.space(6)

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(36)
                    color: "transparent"
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: searchField.activeFocus
                            ? Color.accent
                            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
                    }

                    MouseArea {
                        anchors.fill: parent
                        z: -1
                        onClicked: searchField.forceActiveFocus()
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        spacing: Style.space(8)
                        Text {
                            text: "󰍉"
                            color: searchField.activeFocus ? Color.accent : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                        }
                        TextInput {
                            id: searchField
                            Layout.fillWidth: true
                            text: root.query
                            color: root.foreground
                            selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                            selectedTextColor: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            clip: true
                            selectByMouse: true
                            onTextEdited: root.query = text
                            Keys.onPressed: function(event) {
                                var key = event.key
                                if (key === Qt.Key_Down || key === Qt.Key_Up) {
                                    root.move(key === Qt.Key_Down ? 1 : -1)
                                    event.accepted = true
                                } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                                    root.copySelected((event.modifiers & Qt.ShiftModifier) !== 0, true)
                                    event.accepted = true
                                } else if (key === Qt.Key_Escape) {
                                    if (root.query !== "") root.query = ""
                                    else root.close()
                                    event.accepted = true
                                } else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
                                    root.cycleGroup(key === Qt.Key_Backtab ? -1 : 1)
                                    event.accepted = true
                                }
                            }
                            Text {
                                enabled: false
                                visible: searchField.text === ""
                                width: searchField.width
                                text: "Szukaj"
                                color: root.dim
                                font: searchField.font
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            visible: root.query !== ""
                            text: "✕"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.query = ""
                                    searchField.forceActiveFocus()
                                }
                            }
                        }
                        Text {
                            text: "+"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -Style.space(6)
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.newCommand()
                            }
                        }
                    }
                }

                Flickable {
                    visible: root.groupNames.length > 1
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? Style.space(28) : 0
                    contentWidth: tabRow.implicitWidth
                    contentHeight: height
                    flickableDirection: Flickable.HorizontalFlick
                    clip: true
                    Row {
                        id: tabRow
                        spacing: Style.space(2)
                        Repeater {
                            model: root.groupTabs
                            delegate: Button {
                                required property string modelData
                                text: modelData
                                bordered: false
                                fontSize: Style.font.bodySmall
                                horizontalPadding: Style.space(8)
                                verticalPadding: Style.space(2)
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                selected: (modelData === "Wszystkie" && root.groupFilter === "") || modelData === root.groupFilter
                                onClicked: root.setGroup(modelData === "Wszystkie" ? "" : modelData)
                            }
                        }
                        Button {
                            text: "+"
                            bordered: false
                            fontSize: Style.font.bodySmall
                            horizontalPadding: Style.space(8)
                            verticalPadding: Style.space(2)
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.openGroups()
                        }
                    }
                }

                RowLayout {
                    visible: root.rows.length > 0
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: Style.space(12)

                    Flickable {
                        id: commandList
                        Layout.fillWidth: true
                        implicitWidth: keyScope.width
                        Layout.preferredWidth: keyScope.width
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredHeight: Style.space(440)
                        clip: true
                        contentWidth: width
                        contentHeight: commandColumn.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        maximumFlickVelocity: 9000
                        flickDeceleration: 8000
                        interactive: contentHeight > height + 1

                        WheelHandler {
                            orientation: Qt.Vertical
                            blocking: true
                            onWheel: function(event) {
                                var dy = event.pixelDelta.y
                                if (Math.abs(dy) < 1) dy = event.angleDelta.y * 1.4
                                else dy = dy * 2
                                var maxY = Math.max(0, commandList.contentHeight - commandList.height)
                                commandList.contentY = Math.max(0, Math.min(maxY, commandList.contentY - dy))
                            }
                        }

                        ScrollBar.vertical: ScrollBar {
                            policy: commandList.contentHeight > commandList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                        }

                        Column {
                            id: commandColumn
                            width: commandList.width
                            spacing: Style.space(4)

                            Repeater {
                                model: root.rows
                                delegate: CursorSurface {
                                    id: commandRow
                                    required property var modelData
                                    required property int index
                                    readonly property bool picked: root.selectedIndex === commandRow.index
                                    readonly property bool showGroup: root.groupNames.length > 1 && root.groupFilter === "" && commandRow.modelData.group !== ""
                                    width: commandList.width
                                    height: Style.space(52)
                                    clip: true
                                    hasCursor: rowMouse.containsMouse && !picked
                                    current: picked
                                    foreground: root.foreground

                                    Rectangle {
                                        visible: commandRow.picked
                                        width: Style.space(2)
                                        height: parent.height
                                        color: Color.accent
                                    }
                                    Text {
                                        id: groupLabel
                                        visible: commandRow.showGroup
                                        anchors.right: parent.right
                                        anchors.rightMargin: Style.space(12)
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Style.space(100)
                                        horizontalAlignment: Text.AlignRight
                                        text: commandRow.modelData.group || ""
                                        color: root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        id: titleLabel
                                        x: Style.space(14)
                                        y: Style.space(8)
                                        width: Math.max(Style.space(40), commandRow.width - x - Style.space(16) - (commandRow.showGroup ? groupLabel.width + Style.space(8) : 0))
                                        text: (commandRow.modelData.pinned ? "󰐃  " : "") + (commandRow.modelData.danger ? "!  " : "") + commandRow.modelData.title
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }
                                    Text {
                                        x: titleLabel.x
                                        y: titleLabel.y + titleLabel.implicitHeight + Style.space(2)
                                        width: titleLabel.width
                                        text: root.commandPreview(commandRow.modelData.command)
                                        textFormat: Text.PlainText
                                        color: root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.bodySmall
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                        maximumLineCount: 1
                                        clip: true
                                    }
                                    MouseArea {
                                        id: rowMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        preventStealing: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.selectIndex(commandRow.index)
                                        onDoubleClicked: root.copySelected(false)
                                    }
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        visible: root.wide && root.rows.length > 0
                        Layout.preferredWidth: Style.space(320)
                        Layout.alignment: Qt.AlignTop
                        spacing: Style.space(8)
                        Text {
                            Layout.fillWidth: true
                            text: root.currentCommand ? root.currentCommand.title : "Wybierz komendę"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.currentCommand !== null && root.currentCommand.group !== ""
                            text: root.currentCommand ? root.currentCommand.group : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                        Flickable {
                            id: commandView
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(commandText.implicitHeight, Style.space(220))
                            clip: true
                            contentWidth: width
                            contentHeight: commandText.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.VerticalFlick
                            interactive: contentHeight > height + 1

                            Text {
                                id: commandText
                                width: commandView.width
                                visible: root.currentCommand !== null
                                text: root.currentCommand ? root.currentCommand.command : ""
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                wrapMode: Text.Wrap
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.currentCommand && root.currentCommand.body !== ""
                            text: root.currentCommand ? root.currentCommand.body : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            visible: root.currentCommand && root.currentCommand.tags && root.currentCommand.tags.length > 0
                            text: root.currentCommand && root.currentCommand.tags ? root.currentCommand.tags.join("  ") : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }
                }

                Text {
                    visible: !root.wide && root.currentCommand !== null
                    Layout.fillWidth: true
                    text: root.currentCommand ? root.currentCommand.command : ""
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                    maximumLineCount: 8
                    elide: Text.ElideRight
                }

                Column {
                    visible: root.rows.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(24)
                    Layout.bottomMargin: Style.space(12)
                    spacing: Style.space(8)
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: root.query.trim() !== ""
                            ? "Nic nie pasuje do „" + root.query.trim() + "”"
                            : (root.groupFilter !== "" ? "Folder „" + root.groupFilter + "” jest pusty" : "Tu pojawią się twoje komendy")
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                        wrapMode: Text.WordWrap
                    }
                    Item {
                        width: parent.width
                        height: (emptyAsk.visible ? emptyAsk.implicitHeight + Style.space(10) : 0) + emptyAdd.implicitHeight
                        Button {
                            id: emptyAsk
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.top: parent.top
                            visible: root.query.trim() !== ""
                            text: "Zapytaj AI"
                            bordered: true
                            fontSize: Style.font.subtitle
                            horizontalPadding: Style.space(28)
                            verticalPadding: Style.space(12)
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.askFromQuery()
                        }
                        Button {
                            id: emptyAdd
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.top: emptyAsk.visible ? emptyAsk.bottom : parent.top
                            anchors.topMargin: emptyAsk.visible ? Style.space(10) : 0
                            text: root.query.trim() === "" ? "Dodaj komendę" : "Dodaj"
                            bordered: false
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.newCommand()
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Button {
                        visible: root.currentCommand !== null
                        text: "Kopiuj"
                        bordered: false
                        fontSize: Style.font.bodySmall
                        horizontalPadding: Style.space(8)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.copySelected(false)
                    }
                    Button {
                        visible: root.currentCommand !== null
                        text: "Wklej"
                        bordered: false
                        fontSize: Style.font.bodySmall
                        horizontalPadding: Style.space(8)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.copySelected(true)
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        visible: root.currentCommand !== null
                        text: "Edytuj"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.editCurrent()
                    }
                    Button {
                        visible: root.currentCommand !== null
                        text: root.currentCommand && root.currentCommand.pinned ? "Odepnij" : "Przypnij"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.togglePin(root.currentCommand)
                    }
                    Button {
                        visible: root.currentCommand !== null
                        text: "Zapytaj"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: {
                            root.formNote = ""
                            root.page = "ask"
                            Qt.callLater(function() { askField.forceActiveFocus() })
                        }
                    }
                    Button {
                        visible: root.currentCommand !== null
                        text: "Usuń"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: if (root.currentCommand) root.page = "remove"
                    }
                    Button {
                        visible: root.groupNames.length < 2
                        text: "Folder"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.openGroups()
                    }
                    Button {
                        text: "Synchronizuj"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.synchronize(false)
                    }
                    Button {
                        text: "Ustawienia"
                        bordered: false
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.openSettings()
                    }
                }

                Text {
                    visible: root.note !== ""
                    Layout.fillWidth: true
                    text: root.note
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                }
            }

            ColumnLayout {
                anchors.fill: parent
                visible: root.page !== "list"
                spacing: Style.space(8)

                Flickable {
                id: formFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: formColumn.implicitHeight
                clip: true
                flickableDirection: Flickable.VerticalFlick

                ColumnLayout {
                    id: formColumn
                    width: formFlick.width
                    spacing: Style.space(8)

                    ColumnLayout {
                        visible: root.page === "edit"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: root.editId === "" ? "Nowa komenda" : "Edycja"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }
                        TextField {
                            id: titleField
                            Layout.fillWidth: true
                            placeholderText: "Tytuł, np. Pokaż tablicę ARP"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        Text {
                            text: "Folder"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                        Flickable {
                            Layout.fillWidth: true
                            Layout.preferredHeight: groupPickRow.implicitHeight
                            visible: root.groupNames.length > 0
                            contentWidth: groupPickRow.implicitWidth
                            contentHeight: groupPickRow.implicitHeight
                            flickableDirection: Flickable.HorizontalFlick
                            clip: true
                            Row {
                                id: groupPickRow
                                spacing: Style.space(4)
                                Repeater {
                                    model: root.groupNames
                                    delegate: Button {
                                        required property string modelData
                                        text: modelData
                                        foreground: root.foreground
                                        fontFamily: root.fontFamily
                                        selected: groupField.text === modelData
                                        onClicked: groupField.text = modelData
                                    }
                                }
                            }
                        }
                        TextField {
                            id: groupField
                            Layout.fillWidth: true
                            placeholderText: "albo nowy, np. Konfigurowanie Fortineta"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        TextField {
                            id: tagsField
                            Layout.fillWidth: true
                            placeholderText: "Tagi po przecinku"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        TextArea {
                            id: commandField
                            Layout.fillWidth: true
                            Layout.preferredHeight: Style.space(88)
                            placeholderText: "Komenda. Dziury zapisuj jako {{iface}}"
                            color: root.foreground
                            wrapMode: TextEdit.Wrap
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            selectByMouse: true
                            background: Rectangle {
                                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                                radius: Style.cornerRadius
                                border.width: 1
                                border.color: commandField.activeFocus ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                            }
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        TextArea {
                            id: bodyField
                            Layout.fillWidth: true
                            Layout.preferredHeight: Style.space(88)
                            placeholderText: "Kiedy tego użyć"
                            color: root.foreground
                            wrapMode: TextEdit.Wrap
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            selectByMouse: true
                            background: Rectangle {
                                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                                radius: Style.cornerRadius
                                border.width: 1
                                border.color: bodyField.activeFocus ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                            }
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        Toggle {
                            Layout.fillWidth: true
                            label: "Niebezpieczna"
                            description: "Przed skopiowaniem poprosi o potwierdzenie"
                            checked: root.dangerDraft
                            foreground: root.foreground
                            onClicked: root.dangerDraft = !root.dangerDraft
                        }
                    }

                    ColumnLayout {
                        visible: root.page === "groups"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: root.groupOriginal === "" ? "Nowy folder" : "Zmiana nazwy"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Folder może być pusty. Komendy dodasz do niego potem."
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }
                        TextField {
                            id: groupNameField
                            Layout.fillWidth: true
                            placeholderText: "np. Konfigurowanie Fortineta"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            onAccepted: root.saveGroup()
                            Keys.onEscapePressed: root.showList()
                        }
                        RowLayout {
                            Button {
                                text: root.groupOriginal === "" ? "Utwórz" : "Zmień nazwę"
                                active: true
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.saveGroup()
                            }
                            Button {
                                text: "Anuluj"
                                bordered: true
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.showList()
                            }
                        }
                        Repeater {
                            model: root.groupNames
                            delegate: RowLayout {
                                required property string modelData
                                Layout.fillWidth: true
                                spacing: Style.space(8)
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.body
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: root.groupCount(modelData) === 0 ? "pusta" : String(root.groupCount(modelData))
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                }
                                Button {
                                    text: "Zmień"
                                    bordered: true
                                    foreground: root.foreground
                                    fontFamily: root.fontFamily
                                    onClicked: {
                                        root.groupOriginal = modelData
                                        groupNameField.text = modelData
                                        groupNameField.forceActiveFocus()
                                    }
                                }
                                Button {
                                    visible: root.groupCount(modelData) === 0
                                    text: "Usuń"
                                    bordered: true
                                    foreground: root.foreground
                                    fontFamily: root.fontFamily
                                    onClicked: root.call({op: "deleteGroup", name: modelData})
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        visible: root.page === "fields"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: "Uzupełnij komendę"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.pendingCommand ? root.pendingCommand.command : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.Wrap
                        }
                        Repeater {
                            model: root.placeholderNames
                            delegate: TextField {
                                required property string modelData
                                required property int index
                                property int epoch: root.fieldEpoch
                                Layout.fillWidth: true
                                placeholderText: modelData
                                foreground: root.foreground
                                font.family: root.fontFamily
                                onEpochChanged: text = ""
                                onTextChanged: {
                                    var next = root.placeholderValues.slice()
                                    if (next[index] === text) return
                                    next[index] = text
                                    root.placeholderValues = next
                                }
                                Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                            }
                        }
                        Button {
                            text: root.pendingPaste ? "Wstaw i wklej" : "Wstaw i kopiuj"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.sendDeliver(root.collectFields())
                        }
                    }

                    ColumnLayout {
                        visible: root.page === "ask"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: "Co chcesz zrobić?"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Wybiorę komendę z tej listy. Nie wymyślę nowej."
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }
                        TextField {
                            id: askField
                            Layout.fillWidth: true
                            placeholderText: "np. sąsiad nie widzi mojego MAC-a"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            onAccepted: root.submitAsk()
                            Keys.onEscapePressed: root.showList()
                        }
                        Button {
                            text: "Szukaj"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.submitAsk()
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.formNote !== ""
                            text: root.formNote
                            color: root.formNote === "Szukam…" ? root.dim : Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }
                    }

                    ColumnLayout {
                        visible: root.page === "settings"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: "Ustawienia"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }
                        Text {
                            text: "Adres"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                        TextField {
                            id: apiField
                            Layout.fillWidth: true
                            placeholderText: "https://sejfik.xerima.pl"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        Text {
                            text: "Klucz biblioteki"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                        TextField {
                            id: tokenField
                            Layout.fillWidth: true
                            placeholderText: root.machineSettings.tokenSet ? "Klucz zapisany — wpisz, aby zmienić" : "cmd_…"
                            password: true
                            foreground: root.foreground
                            font.family: root.fontFamily
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: function(event) { root.formKey(event) }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Adres bez ścieżki, np. https://sejfik.xerima.pl. Panel sam dopisze /v1/snapshot. Klucz cmd_… bierzesz w Sejfiku: Komendy → biblioteka → Generuj klucz. Widać go raz. Jeden klucz to jedna biblioteka; inna biblioteka to inny klucz. Foldery z Sejfika są tu folderami katalogu. Klucz SSH hostów zostaje w Hostach."
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            Button {
                                text: "Auto"
                                selected: root.layoutDraft === "auto"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.layoutDraft = "auto"
                            }
                            Button {
                                text: "Wąski"
                                selected: root.layoutDraft === "compact"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.layoutDraft = "compact"
                            }
                            Button {
                                text: "Szeroki"
                                selected: root.layoutDraft === "wide"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.layoutDraft = "wide"
                            }
                        }
                        RowLayout {
                            Button {
                                text: "Zapisz"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.saveSettings()
                            }
                            Button {
                                text: "Pobierz"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.call({op: "previewSync"})
                            }
                            Button {
                                text: "Wyślij"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.call({op: "pushSync"})
                            }
                            Button {
                                text: "Usuń klucz"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.call({op: "saveSettings", clearToken: true})
                            }
                        }
                    }

                    ColumnLayout {
                        visible: root.page === "sync"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: "Pobranie z serwera"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.syncRows.length === 0
                                ? "Katalog jest zgodny."
                                : "Nowe: " + (root.syncSummary.added || 0)
                                  + "   nowsze na serwerze: " + (root.syncSummary.updated || 0)
                                  + "   konflikty: " + (root.syncSummary.conflict || 0)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }
                        Repeater {
                            model: root.syncRows
                            delegate: Text {
                                required property var modelData
                                Layout.fillWidth: true
                                text: (modelData.action === "added" ? "nowa" : modelData.action === "updated" ? "nowsza" : "konflikt")
                                    + "  ·  " + modelData.group + "  ·  " + modelData.title
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                elide: Text.ElideRight
                            }
                        }
                        RowLayout {
                            Button {
                                text: "Pobierz bez nadpisywania nowszych"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.call({op: "applySync", token: root.syncToken, policy: "keep"})
                            }
                            Button {
                                text: "Zastąp konflikty"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.call({op: "applySync", token: root.syncToken, policy: "replace"})
                            }
                            Button {
                                text: "Anuluj"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.showList()
                            }
                        }
                    }

                    ColumnLayout {
                        visible: root.page === "danger" || root.page === "remove"
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                            text: root.page === "danger" ? "Komenda jest oznaczona jako niebezpieczna" : "Usunąć komendę?"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.page === "danger"
                                ? (root.pendingCommand ? root.pendingCommand.title : "")
                                : (root.currentCommand ? root.currentCommand.title : "")
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            text: "Esc wraca"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                        RowLayout {
                            Button {
                                text: root.page === "danger"
                                    ? (root.pendingPaste ? "Wklej mimo to" : "Kopiuj mimo to")
                                    : "Usuń"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: {
                                    if (root.page === "danger") root.sendDeliver(root.pendingValues)
                                    else if (root.currentCommand) root.call({op: "delete", id: root.currentCommand.id})
                                }
                            }
                            Button {
                                text: "Anuluj"
                                bordered: true
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.showList()
                            }
                        }
                    }
                }
                }

                RowLayout {
                    visible: root.page === "edit"
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    Button {
                        text: root.editId === "" ? "Dodaj komendę" : "Zapisz"
                        iconText: root.editId === "" ? "+" : ""
                        bordered: true
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.saveForm()
                    }
                    Button {
                        text: "Anuluj"
                        bordered: true
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.showList()
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.formNote !== "" ? root.formNote : "Ctrl+Enter zapisuje"
                        color: root.formNote !== "" ? Color.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
