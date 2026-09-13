/*
  Panel.qml — the popup UI for the Omarchledger plugin.

  Three tabs:
    1. ADD     — transaction form mirroring `hledger add`: date, description
                 with history autocomplete + "use similar" prefill, any
                 number of postings with account autocomplete and an
                 auto-balanced final posting, optional comment/tags.
    2. BALANCE — structured view of `hledger bs`.
    3. SUMMARY — structured view of `hledger stats`.

  Keys while the form has focus: Tab/Shift+Tab cycle fields, Enter accepts
  the highlighted suggestion or advances (submits on the last amount),
  Escape closes suggestions then the panel. When nothing is focused the
  PanelKeyCatcher handles Escape/Alt-Tab, arrows and 1/2/3 switch tabs.
*/
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "afonsoneto.omarchledger"
  ipcTarget: "afonsoneto.omarchledger"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  /* ---- Theming ---------------------------------------------------------- */
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color mutedForeground: Color.muted
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string monoFontFamily: "monospace"

  /* ---- Settings ---------------------------------------------------------- */
  function applySettings() {
    service.hledgerBinOverride = root.setting("hledgerBin", "")
    service.journalFileOverride = root.setting("journalFile", "")
  }
  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()

  /* ---- Tabs -------------------------------------------------------------- */
  property int currentTab: 0  // 0=ADD, 1=BALANCE, 2=SUMMARY
  readonly property var tabLabels: ["ADD", "BALANCE", "SUMMARY"]

  function switchTab(index) {
    root.currentTab = index
    if (index === 1) service.fetchBalanceSheet()
    else if (index === 2) service.fetchStats()
  }

  /* ---- Quick Add state ---------------------------------------------------- */
  property string fieldDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
  property string fieldDescription: ""
  property string fieldComment: ""
  property bool similarNotice: false

  ListModel {
    id: postingsModel
    ListElement { account: ""; amount: "" }
    ListElement { account: ""; amount: "" }
  }

  readonly property int maxPostings: 6

  function resetPostings() {
    postingsModel.clear()
    postingsModel.append({ account: "", amount: "" })
    postingsModel.append({ account: "", amount: "" })
  }

  /* ---- Autocomplete ------------------------------------------------------- */
  // suggestTarget: -2 = hidden, -1 = description field, >=0 = posting row
  property int suggestTarget: -2
  property string suggestFilter: ""
  property int suggestIndex: 0
  property bool showSuggestions: false

  function filteredSuggestions() {
    var list = root.suggestTarget === -1 ? service.descriptionList : service.accountList
    var f = root.suggestFilter.toLowerCase()
    if (f === "") return list.slice(0, 8)
    var starts = []
    var contains = []
    for (var i = 0; i < list.length && starts.length + contains.length < 8; i++) {
      var item = list[i].toLowerCase()
      if (item.indexOf(f) === 0) starts.push(list[i])
      else if (item.indexOf(f) !== -1) contains.push(list[i])
    }
    return starts.concat(contains)
  }

  function openSuggestions(target, filter) {
    root.suggestTarget = target
    root.suggestFilter = filter
    root.suggestIndex = 0
    root.showSuggestions = root.filteredSuggestions().length > 0
  }

  function applySuggestion(value) {
    root.showSuggestions = false
    if (root.suggestTarget === -1) {
      root.fieldDescription = value
      descInput.text = value
      descInput.forceActiveFocus()
      useSimilar()
    } else if (root.suggestTarget >= 0) {
      var d = postingsRepeater.itemAt(root.suggestTarget)
      if (d) d.applyAccount(value)
    }
  }

  Timer {
    id: hideSuggestTimer
    interval: 200
    onTriggered: root.showSuggestions = false
  }

  function fieldFocusGained(target, text) {
    hideSuggestTimer.stop()
    root.openSuggestions(target, text)
  }

  function fieldFocusLost() {
    hideSuggestTimer.restart()
  }

  function fieldTextChanged(target, text) {
    if (root.suggestTarget === target && root.showSuggestions) {
      root.suggestFilter = text
      root.suggestIndex = 0
      root.showSuggestions = root.filteredSuggestions().length > 0
    }
  }

  /* ---- "Use similar" ------------------------------------------------------ */
  function useSimilar() {
    if (root.fieldDescription.trim() !== "") service.fetchSimilar(root.fieldDescription)
  }

  function applySimilarPrefill() {
    if (!service.similarFound) return
    postingsModel.clear()
    for (var i = 0; i < service.similarPostings.length; i++) {
      postingsModel.append({
        account: service.similarPostings[i].account,
        amount: service.similarPostings[i].amount
      })
    }
    while (postingsModel.count < 2)
      postingsModel.append({ account: "", amount: "" })
    root.similarNotice = true
  }

  /* ---- Form focus tracking (blocks PanelKeyCatcher while typing) ---------- */
  readonly property bool formActive: dateInput.activeFocus || descInput.activeFocus
    || commentInput.activeFocus || postingInputsFocused()

  function postingInputsFocused() {
    for (var i = 0; i < postingsModel.count; i++) {
      var d = postingsRepeater.itemAt(i)
      if (d && d.anyFocused()) return true
    }
    return false
  }

  /* ---- Keyboard flow ------------------------------------------------------- */
  function rowFocusFn(i, which) {
    return function() {
      var d = postingsRepeater.itemAt(i)
      if (d) { if (which === 0) d.focusAccount(); else d.focusAmount() }
    }
  }

  function focusSequence() {
    var seq = [function() { dateInput.forceActiveFocus() },
               function() { descInput.forceActiveFocus() }]
    for (var i = 0; i < postingsModel.count; i++) {
      seq.push(root.rowFocusFn(i, 0))
      seq.push(root.rowFocusFn(i, 1))
    }
    seq.push(function() { commentInput.forceActiveFocus() })
    return seq
  }

  function focusNextField(forward) {
    var seq = root.focusSequence()
    var cur = -1
    if (dateInput.activeFocus) cur = 0
    else if (descInput.activeFocus) cur = 1
    else if (commentInput.activeFocus) cur = seq.length - 1
    else {
      for (var i = 0; i < postingsModel.count; i++) {
        var d = postingsRepeater.itemAt(i)
        if (!d) continue
        if (d.accountHasFocus()) { cur = 2 + i * 2; break }
        if (d.amountHasFocus()) { cur = 3 + i * 2; break }
      }
    }
    if (cur < 0) { dateInput.forceActiveFocus(); return }
    var next = (cur + (forward ? 1 : -1) + seq.length) % seq.length
    seq[next]()
  }

  /*
    Common key handler for form TextInputs. `isLastAmount` submits on Enter.
  */
  function handleFieldKey(event, isLastAmount) {
    if (event.key === Qt.Key_Down && root.showSuggestions) {
      root.suggestIndex = Math.min(root.suggestIndex + 1, root.filteredSuggestions().length - 1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up && root.showSuggestions) {
      root.suggestIndex = Math.max(root.suggestIndex - 1, 0)
      event.accepted = true
    } else if (event.key === Qt.Key_Tab) {
      root.showSuggestions = false
      event.accepted = true
      root.focusNextField(true)
    } else if (event.key === Qt.Key_Backtab) {
      root.showSuggestions = false
      event.accepted = true
      root.focusNextField(false)
    } else if (event.key === Qt.Key_Escape) {
      event.accepted = true
      if (root.showSuggestions) root.showSuggestions = false
      else root.close()
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      if (root.showSuggestions && root.filteredSuggestions().length > 0) {
        root.applySuggestion(root.filteredSuggestions()[root.suggestIndex])
      } else if (isLastAmount) {
        root.submitTransaction()
      } else {
        root.focusNextField(true)
      }
    }
  }

  /* ---- Submit / clear ------------------------------------------------------- */
  function submitTransaction() {
    root.showSuggestions = false
    var postings = []
    for (var i = 0; i < postingsModel.count; i++) {
      var p = postingsModel.get(i)
      var acc = (p.account || "").trim()
      if (acc !== "") postings.push({ account: acc, amount: (p.amount || "").trim() })
    }
    var date = root.fieldDate.trim()
    var desc = root.fieldDescription.trim()
    if (date === "" || desc === "" || postings.length < 2) {
      service.addOk = false
      service.addMessage = "Date, description and at least two postings are required."
      return
    }
    service.addTransaction(service.buildEntry(date, desc, root.fieldComment, postings))
  }

  function clearTransaction() {
    root.fieldDescription = ""
    root.fieldComment = ""
    root.similarNotice = false
    descInput.text = ""
    commentInput.text = ""
    root.resetPostings()
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function launchTerminal() {
    if (!root.bar || typeof root.bar.run !== "function") return
    if (!service.resolved || service.resolveError !== "") return
    root.bar.run("omarchy launch terminal " + shellQuote(service.hledgerBin)
      + " add -f " + shellQuote(service.journalFile))
    root.close()
  }

  /* ---- Stats staleness -------------------------------------------------------- */
  function isStale(key, value) {
    if (key.indexOf("Last txn") !== 0) return false
    var m = value.match(/(\d+)\s+days?\s+ago/)
    return m !== null && parseInt(m[1], 10) > 7
  }

  /* ---- Service ------------------------------------------------------------------ */
  HledgerService {
    id: service

    onResolvedOk: {
      root.fetchReferenceData()
      if (root.currentTab === 1) service.fetchBalanceSheet()
      else if (root.currentTab === 2) service.fetchStats()
    }
    onSimilarReady: function(found) {
      if (found) root.applySimilarPrefill()
      else root.similarNotice = false
    }
    onAddFinished: function(ok) {
      if (ok) {
        root.clearTransaction()
        keyCatcher.forceActiveFocus()
      }
      if (root.currentTab === 1) service.fetchBalanceSheet()
      if (root.currentTab === 2) service.fetchStats()
    }
    onUndoFinished: function(ok) {
      if (root.currentTab === 1) service.fetchBalanceSheet()
      if (root.currentTab === 2) service.fetchStats()
    }
  }

  function fetchReferenceData() {
    service.fetchAccounts()
    service.fetchDescriptions()
    service.fetchCommodities()
  }

  /* ---- Lifecycle ------------------------------------------------------------------ */
  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) service.resolve()
    })
  }

  function close() {
    root.showSuggestions = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  /* ================================================================================== */
  /* UI                                                                                 */
  /* ================================================================================== */
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(20))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.formActive
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx > 0) root.switchTab(Math.min(2, root.currentTab + 1))
        else if (dx < 0) root.switchTab(Math.max(0, root.currentTab - 1))
      }
      onReturnRequested: { dateInput.forceActiveFocus() }
      onTextKey: function(t) {
        if (t === "1") root.switchTab(0)
        else if (t === "2") root.switchTab(1)
        else if (t === "3") root.switchTab(2)
        else if (t === "r" && root.currentTab === 1) service.fetchBalanceSheet()
        else if (t === "r" && root.currentTab === 2) service.fetchStats()
        else if (t === "u" && service.canUndo) service.undoLastAdd()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        /* ---- Header --------------------------------------------------- */
        Item {
          width: parent.width
          height: Math.max(headerText.implicitHeight, terminalBtn.height)

          Text {
            id: headerText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "OMARCHLEDGER"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            font.letterSpacing: 1
          }

          Rectangle {
            id: terminalBtn
            visible: root.bar && typeof root.bar.run === "function"
              && service.resolved && service.resolveError === ""
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: terminalLabel.width + Style.space(16)
            height: Style.space(26)
            radius: Style.cornerRadius
            color: terminalMouse.containsMouse
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

            Text {
              id: terminalLabel
              anchors.centerIn: parent
              text: "⌨ TERMINAL"
              color: terminalMouse.containsMouse ? Color.accent : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            MouseArea {
              id: terminalMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launchTerminal()
            }
          }
        }

        /* ---- Journal indicator / resolution error ---------------------- */
        Text {
          width: parent.width
          visible: service.resolveError === ""
          text: service.resolved ? ("📄 " + service.journalFile) : "Resolving journal…"
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
        Text {
          width: parent.width
          visible: service.resolveError !== ""
          text: service.resolveError
          color: Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        /* ---- Tab bar ----------------------------------------------------- */
        Row {
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.tabLabels

            Rectangle {
              required property int index
              required property string modelData
              width: (contentColumn.width - Style.space(4)) / 3
              height: Style.space(30)
              radius: Style.cornerRadius
              color: root.currentTab === index
                ? Color.accent
                : tabMouse.containsMouse
                  ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
                  : "transparent"

              Text {
                anchors.centerIn: parent
                text: modelData
                color: root.currentTab === index
                  ? Color.background
                  : tabMouse.containsMouse
                    ? Color.accent
                    : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.5
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchTab(index)
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
        }

        /* ================================================================== */
        /* TAB 0: ADD                                                         */
        /* ================================================================== */
        Column {
          id: addTab
          visible: root.currentTab === 0
          width: parent.width
          spacing: Style.space(10)

          /* ---- "use similar" prefill notice ------------------------------ */
          Rectangle {
            width: parent.width
            visible: root.similarNotice
            height: similarNoticeText.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)

            Text {
              id: similarNoticeText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: similarNoticeClose.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: "Prefilled from " + service.similarDate + " — " + service.similarDescription
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: similarNoticeClose
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.similarNotice = false
                  root.resetPostings()
                }
              }
            }
          }

          /* ---- Date ------------------------------------------------------- */
          Column {
            width: parent.width
            spacing: Style.space(3)

            Text {
              text: "Date"
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: Style.cornerRadius
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
              border.color: dateInput.activeFocus
                ? Color.accent
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)
              border.width: 1

              TextInput {
                id: dateInput
                anchors.fill: parent
                anchors.margins: Style.space(8)
                verticalAlignment: TextInput.AlignVCenter
                color: root.contentForeground
                font.family: root.monoFontFamily
                font.pixelSize: Style.font.body
                text: root.fieldDate
                onTextChanged: root.fieldDate = text
                selectByMouse: true
                Keys.onPressed: function(event) { root.handleFieldKey(event, false) }
              }
            }
          }

          /* ---- Description ---------------------------------------------- */
          Column {
            width: parent.width
            spacing: Style.space(3)

            Text {
              text: "Description"
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Rectangle {
                width: parent.width - similarBtn.width - Style.space(6)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
                border.color: descInput.activeFocus
                  ? Color.accent
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)
                border.width: 1

                TextInput {
                  id: descInput
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  selectByMouse: true
                  onActiveFocusChanged: {
                    if (activeFocus) root.fieldFocusGained(-1, text)
                    else root.fieldFocusLost()
                  }
                  onTextChanged: {
                    root.fieldDescription = text
                    root.fieldTextChanged(-1, text)
                  }
                  Keys.onPressed: function(event) { root.handleFieldKey(event, false) }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: descInput.text === "" && !descInput.activeFocus
                    text: "e.g. Groceries — Tab completes from history"
                    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.3)
                    font: descInput.font
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }
              }

              Rectangle {
                id: similarBtn
                width: similarLabel.width + Style.space(14)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: similarMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
                opacity: root.fieldDescription.trim() !== "" ? 1 : 0.4

                Text {
                  id: similarLabel
                  anchors.centerIn: parent
                  text: service.busySimilar ? "…" : "SIMILAR"
                  color: similarMouse.containsMouse ? Color.accent : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: similarMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: root.fieldDescription.trim() !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.useSimilar()
                }
              }
            }
          }

          /* ---- Postings --------------------------------------------------- */
          Column {
            width: parent.width
            spacing: Style.space(3)

            Row {
              width: parent.width

              Text {
                text: "Postings"
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                anchors.right: parent.right
                text: "last empty amount = auto-balance"
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.35)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.italic: true
              }
            }

            Repeater {
              id: postingsRepeater
              model: postingsModel

              delegate: Rectangle {
                id: postingRow
                required property int index
                required property string account
                required property string amount

                width: addTab.width
                height: Style.space(32)
                radius: Style.cornerRadius
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
                border.color: accInput.activeFocus || amtInput.activeFocus
                  ? Color.accent
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)
                border.width: 1

                function anyFocused() { return accInput.activeFocus || amtInput.activeFocus }
                function accountHasFocus() { return accInput.activeFocus }
                function amountHasFocus() { return amtInput.activeFocus }
                function focusAccount() { accInput.forceActiveFocus() }
                function focusAmount() { amtInput.forceActiveFocus() }
                function applyAccount(value) {
                  accInput.text = value
                  postingsModel.setProperty(postingRow.index, "account", value)
                  amtInput.forceActiveFocus()
                }

                TextInput {
                  id: accInput
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.leftMargin: Style.space(8)
                  anchors.topMargin: Style.space(6)
                  anchors.bottomMargin: Style.space(6)
                  width: parent.width - amtInput.width - removeBtn.width - Style.space(24)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.contentForeground
                  font.family: root.monoFontFamily
                  font.pixelSize: Style.font.body
                  text: postingRow.account
                  selectByMouse: true
                  clip: true

                  onActiveFocusChanged: {
                    if (activeFocus) root.fieldFocusGained(postingRow.index, text)
                    else root.fieldFocusLost()
                  }
                  onTextChanged: {
                    if (text !== postingRow.account)
                      postingsModel.setProperty(postingRow.index, "account", text)
                    root.fieldTextChanged(postingRow.index, text)
                  }
                  Keys.onPressed: function(event) { root.handleFieldKey(event, false) }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: accInput.text === "" && !accInput.activeFocus
                    text: postingRow.index === 0 ? "account, e.g. expenses:food" : "account"
                    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.3)
                    font: accInput.font
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Text {
                  id: autoHint
                  anchors.right: amtInput.left
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: postingRow.index === postingsModel.count - 1
                    && amtInput.text === "" && !amtInput.activeFocus
                    && accInput.text !== ""
                    && postingsModel.count > 1
                  text: "auto"
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.35)
                  font.family: root.monoFontFamily
                  font.pixelSize: Style.font.caption
                  font.italic: true
                }

                TextInput {
                  id: amtInput
                  anchors.right: removeBtn.left
                  anchors.rightMargin: Style.space(4)
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.topMargin: Style.space(6)
                  anchors.bottomMargin: Style.space(6)
                  width: Style.space(105)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.contentForeground
                  font.family: root.monoFontFamily
                  font.pixelSize: Style.font.body
                  text: postingRow.amount
                  selectByMouse: true

                  onActiveFocusChanged: {
                    if (activeFocus) {
                      root.showSuggestions = false
                      root.suggestTarget = -2
                    }
                  }
                  onTextChanged: {
                    if (text !== postingRow.amount)
                      postingsModel.setProperty(postingRow.index, "amount", text)
                  }
                  Keys.onPressed: function(event) {
                    root.handleFieldKey(event, postingRow.index === postingsModel.count - 1)
                  }

                  Text {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    visible: amtInput.text === "" && !amtInput.activeFocus
                    text: postingRow.index === 0 ? "amount" : ""
                    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.3)
                    font: amtInput.font
                  }
                }

                Text {
                  id: removeBtn
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: postingsModel.count > 2
                  text: "✕"
                  color: removeMouse.containsMouse ? Color.urgent : root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: removeMouse
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var wasLast = postingRow.index === postingsModel.count - 1
                      postingsModel.remove(postingRow.index, 1)
                      if (wasLast) {
                        var d = postingsRepeater.itemAt(postingsModel.count - 1)
                        if (d) d.focusAmount()
                      }
                    }
                  }
                }
              }
            }

            /* ---- split control -------------------------------------------- */
            Rectangle {
              visible: postingsModel.count < root.maxPostings
              width: splitLabel.width + Style.space(14)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: splitMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                id: splitLabel
                anchors.centerIn: parent
                text: "+ SPLIT"
                color: splitMouse.containsMouse ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: splitMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  postingsModel.append({ account: "", amount: "" })
                  Qt.callLater(function() {
                    var d = postingsRepeater.itemAt(postingsModel.count - 1)
                    if (d) d.focusAccount()
                  })
                }
              }
            }
          }

          /* ---- Comment / tags ---------------------------------------------- */
          Column {
            width: parent.width
            spacing: Style.space(3)

            Text {
              text: "Comment / tags (optional)"
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: Style.cornerRadius
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
              border.color: commentInput.activeFocus
                ? Color.accent
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)
              border.width: 1

              TextInput {
                id: commentInput
                anchors.fill: parent
                anchors.margins: Style.space(8)
                verticalAlignment: TextInput.AlignVCenter
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                selectByMouse: true
                onTextChanged: root.fieldComment = text
                Keys.onPressed: function(event) { root.handleFieldKey(event, false) }

                Text {
                  anchors.fill: parent
                  verticalAlignment: Text.AlignVCenter
                  visible: commentInput.text === "" && !commentInput.activeFocus
                  text: "e.g. fixed:monthly"
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.3)
                  font: commentInput.font
                }
              }
            }
          }

          /* ---- Autocomplete suggestions ------------------------------------ */
          Rectangle {
            width: parent.width
            visible: root.showSuggestions && root.filteredSuggestions().length > 0
            height: visible ? suggestColumn.implicitHeight : 0
            radius: Style.cornerRadius
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
            border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            border.width: 1
            clip: true

            Column {
              id: suggestColumn
              width: parent.width

              Repeater {
                model: root.showSuggestions ? root.filteredSuggestions() : []

                delegate: Rectangle {
                  required property string modelData
                  required property int index
                  width: suggestColumn.width
                  height: Style.space(28)
                  color: root.suggestIndex === index
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : suggestMouse.containsMouse
                      ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
                      : "transparent"

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(16)
                    text: modelData
                    color: root.suggestIndex === index || suggestMouse.containsMouse
                      ? Color.accent : root.contentForeground
                    font.family: root.suggestTarget === -1
                      ? root.contentFontFamily : root.monoFontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: suggestMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.suggestIndex = index
                    onClicked: root.applySuggestion(modelData)
                  }
                }
              }
            }
          }

          /* ---- Action buttons ----------------------------------------------- */
          Row {
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              id: submitBtn
              readonly property bool ready: root.fieldDate.trim() !== "" && root.fieldDescription.trim() !== ""
              width: (parent.width - Style.space(8)) * 0.6
              height: Style.space(34)
              radius: Style.cornerRadius
              color: {
                if (!ready) return Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
                return submitMouse.containsMouse ? Qt.darker(Color.accent, 1.15) : Color.accent
              }
              opacity: ready ? 1 : 0.55

              Text {
                anchors.centerIn: parent
                text: service.busyAdd ? "ADDING…" : "ADD TRANSACTION"
                color: submitBtn.ready ? Color.background : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 0.5
              }

              MouseArea {
                id: submitMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.submitTransaction()
              }
            }

            Rectangle {
              width: (parent.width - Style.space(8)) * 0.4
              height: Style.space(34)
              radius: Style.cornerRadius
              color: clearMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                anchors.centerIn: parent
                text: "CLEAR"
                color: clearMouse.containsMouse ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 0.5
              }

              MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.clearTransaction()
                  service.addMessage = ""
                }
              }
            }
          }

          /* ---- Result / error + undo ---------------------------------------- */
          Row {
            width: parent.width
            visible: service.addMessage !== ""
            spacing: Style.space(8)

            Text {
              width: parent.width - undoBtn.width - Style.space(8)
              text: service.addMessage
              color: service.addOk ? Color.accent : Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
              id: undoBtn
              visible: service.canUndo && !service.busyAdd
              width: undoLabel.width + Style.space(14)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: undoMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: undoLabel
                anchors.centerIn: parent
                text: "UNDO"
                color: undoMouse.containsMouse ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: undoMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: service.undoLastAdd()
              }
            }
          }
        }

        /* ================================================================== */
        /* TAB 1: BALANCE                                                     */
        /* ================================================================== */
        Column {
          id: balanceTab
          visible: root.currentTab === 1
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: bsTitleText.implicitHeight

            Text {
              id: bsTitleText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: service.bsReportDate !== "" ? ("Balance Sheet — " + service.bsReportDate) : "Balance Sheet"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: refreshBsLabel.width + Style.space(14)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: refreshBsMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                id: refreshBsLabel
                anchors.centerIn: parent
                text: service.busyBs ? "…" : "REFRESH"
                color: refreshBsMouse.containsMouse ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              MouseArea {
                id: refreshBsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: service.fetchBalanceSheet()
              }
            }
          }

          Text {
            width: parent.width
            visible: service.bsError !== ""
            text: service.bsError
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: service.bsSections.length === 0 && !service.busyBs && service.bsError === ""
            text: "Nothing to show — click REFRESH"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            visible: service.busyBs
            text: "Loading…"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Flickable {
            width: parent.width
            height: Math.min(bsContent.implicitHeight, Style.space(400))
            contentHeight: bsContent.implicitHeight
            clip: true
            visible: service.bsSections.length > 0
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: bsContent
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: service.bsSections

                delegate: Column {
                  required property var modelData
                  required property int index
                  width: bsContent.width
                  spacing: 0

                  Rectangle {
                    width: parent.width
                    height: Style.space(30)
                    radius: Style.cornerRadius
                    color: modelData.name === "Net"
                      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                      : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.name.toUpperCase()
                      color: modelData.name === "Net" ? Color.accent : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.5
                    }

                    Text {
                      visible: modelData.name === "Net"
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.total
                      color: Color.accent
                      font.family: root.monoFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }

                  Repeater {
                    model: modelData.rows

                    delegate: Item {
                      required property var modelData
                      required property int index
                      width: bsContent.width
                      height: Style.space(26)

                      Rectangle {
                        anchors.fill: parent
                        color: index % 2 === 1
                          ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
                          : "transparent"
                      }

                      Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.account
                        color: root.contentForeground
                        font.family: root.monoFontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                        width: parent.width * 0.55
                      }

                      Text {
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.balance
                        color: modelData.isNegative ? Color.urgent : root.contentForeground
                        font.family: root.monoFontFamily
                        font.pixelSize: Style.font.bodySmall
                        horizontalAlignment: Text.AlignRight
                      }
                    }
                  }

                  Item {
                    visible: modelData.name !== "Net" && modelData.total !== ""
                    width: bsContent.width
                    height: visible ? Style.space(30) : 0

                    Rectangle {
                      anchors.top: parent.top
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      height: 1
                      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)
                    }

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Total"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.total
                      color: modelData.isNegative ? Color.urgent : root.contentForeground
                      font.family: root.monoFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      horizontalAlignment: Text.AlignRight
                    }
                  }
                }
              }
            }
          }
        }

        /* ================================================================== */
        /* TAB 2: SUMMARY                                                     */
        /* ================================================================== */
        Column {
          id: summaryTab
          visible: root.currentTab === 2
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: statsTitleText.implicitHeight

            Text {
              id: statsTitleText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Statistics"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: refreshStatsLabel.width + Style.space(14)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: refreshStatsMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                id: refreshStatsLabel
                anchors.centerIn: parent
                text: service.busyStats ? "…" : "REFRESH"
                color: refreshStatsMouse.containsMouse ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              MouseArea {
                id: refreshStatsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: service.fetchStats()
              }
            }
          }

          Text {
            width: parent.width
            visible: service.statsError !== ""
            text: service.statsError
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: service.statsEntries.length === 0 && !service.busyStats && service.statsError === ""
            text: "Nothing to show — click REFRESH"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            visible: service.busyStats
            text: "Loading…"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            width: parent.width
            visible: service.statsEntries.length > 0
            spacing: 0

            Repeater {
              model: service.statsEntries

              delegate: Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: Style.space(34)
                radius: index === 0 || index === service.statsEntries.length - 1 ? Style.cornerRadius : 0
                color: index % 2 === 0
                  ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.04)
                  : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.key
                  color: root.isStale(modelData.key, modelData.value) ? Color.urgent : root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.isStale(modelData.key, modelData.value)
                  width: parent.width * 0.42
                  elide: Text.ElideRight
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.value
                  color: root.isStale(modelData.key, modelData.value) ? Color.urgent : root.contentForeground
                  font.family: root.monoFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.isStale(modelData.key, modelData.value)
                  horizontalAlignment: Text.AlignRight
                  width: parent.width * 0.53
                  elide: Text.ElideLeft
                }
              }
            }
          }
        }
      }
    }
  }
}
