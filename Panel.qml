import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Disk space bar widget. The bar shows free space on /; the panel lists every
// cleanup target from bin/space-clean with its size. Safe targets come
// pre-ticked; review targets start unticked and expand into their folders so
// you can pick, open or ignore each one. All deleting happens in the script,
// which re-discovers every path itself — this file only names what to remove.
Panel {
  id: root
  moduleName: "zakarch.space"
  ipcTarget: "zakarch.space"
  manageIpc: false

  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("bin/space-clean")).replace(/^file:\/\//, ""))
  readonly property string logPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/space-clean/clean.log"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool showFreeSpace: String(setting("showFreeSpace", "On")) !== "Off"
  readonly property int warnFreeGB: Math.max(1, parseInt(setting("warnFreeGB", 10), 10) || 10)
  readonly property int staleDays: Math.max(7, parseInt(setting("staleDays", 30), 10) || 30)
  readonly property string scanRoots: String(setting("scanRoots", "~") || "~")

  // Below this a target is leftover metadata, not worth a row.
  readonly property int minKb: 1024

  // Disk state from `df`, in bytes. Binary units, like `df -h` and btrfs.
  readonly property double gib: 1024 * 1024 * 1024
  property double diskSize: 0
  property double diskUsed: 0
  property double diskAvail: 0
  readonly property bool low: diskSize > 0 && diskAvail < warnFreeGB * gib
  property bool warned: false

  // Scan state.
  property var targets: []
  property int ignoredCount: 0
  property double scannedAt: 0
  // Selection keys: "<id>" for whole targets, "<id>\n<path>" for items.
  property var sel: ({})
  property var expanded: ({})
  property int cursor: -1

  // Clean progress and result.
  property bool confirmOpen: false
  property var cleanQueue: []
  property int cleanDone: 0
  property string cleanCurrent: ""
  property double freedKb: 0
  property string resultText: ""
  property bool resultIsError: false

  readonly property bool scanning: scanProc.running
  readonly property bool cleaning: cleanProc.running
  readonly property bool busy: scanning || cleaning || ignoreProc.running

  readonly property var visibleTargets: targets.filter(function(t) { return t.kb >= minKb })
  readonly property var safeTargets: visibleTargets.filter(function(t) { return t.tier === "safe" })
  readonly property var reviewTargets: visibleTargets.filter(function(t) { return t.tier === "review" })
  readonly property double maxKb: visibleTargets.reduce(function(m, t) { return Math.max(m, t.kb) }, 1)

  readonly property double selectedKb: {
    var total = 0
    var counted = {}
    for (var i = 0; i < visibleTargets.length; i++) {
      var t = visibleTargets[i]
      if (!t.selectable) { if (sel[t.id]) total += t.kb; continue }
      for (var j = 0; j < t.items.length; j++) {
        var it = t.items[j]
        if (sel[itemKey(t, it)] && !counted[it.path]) { counted[it.path] = true; total += it.kb }
      }
    }
    return total
  }
  readonly property var cleanArgs: {
    var args = []
    for (var i = 0; i < visibleTargets.length; i++) {
      var t = visibleTargets[i]
      if (t.selectable) {
        for (var j = 0; j < t.items.length; j++)
          if (sel[itemKey(t, t.items[j])]) args.push(t.id + "=" + t.items[j].path)
      } else if (sel[t.id]) {
        args.push(t.id)
      }
    }
    return args
  }
  readonly property var pickedTargets: visibleTargets.filter(function(t) { return pickedKb(t) > 0 })
  readonly property var pickedLost: pickedTargets.filter(function(t) { return t.rebuilds === false })

  // Flattened rows for the list and the keyboard cursor.
  readonly property var rows: {
    var out = []
    function section(tier, title, list) {
      if (list.length === 0) return
      out.push({ kind: "header", tier: tier, title: title, list: list })
      for (var i = 0; i < list.length; i++) {
        var t = list[i]
        out.push({ kind: "target", target: t })
        if (expanded[t.id]) {
          for (var j = 0; j < t.items.length; j++) out.push({ kind: "item", target: t, item: t.items[j] })
          if (t.count > t.items.length) out.push({ kind: "more", target: t })
        }
      }
    }
    section("safe", "Safe to clean", safeTargets)
    section("review", "Review first", reviewTargets)
    return out
  }

  // ---------------------------------------------------------------------
  // Formatting

  function human(kb) {
    if (kb >= 1024 * 1024 * 1024) return (kb / (1024 * 1024 * 1024)).toFixed(1) + " TB"
    if (kb >= 1024 * 1024) return (kb / (1024 * 1024)).toFixed(1) + " GB"
    if (kb >= 1024) return Math.round(kb / 1024) + " MB"
    if (kb > 0) return Math.round(kb) + " KB"
    return "0 MB"
  }

  function gb(bytes) {
    return bytes >= 100 * gib ? Math.round(bytes / gib) : Math.round(bytes / gib * 10) / 10
  }

  function plural(n, word) { return n + " " + word + (n === 1 ? "" : "s") }

  // ---------------------------------------------------------------------
  // Selection

  function itemKey(t, item) { return t.id + "\n" + item.path }

  function pickedKb(t) {
    if (!t.selectable) return sel[t.id] ? t.kb : 0
    var total = 0
    for (var j = 0; j < t.items.length; j++)
      if (sel[itemKey(t, t.items[j])]) total += t.items[j].kb
    return total
  }

  function pickedCount(t) {
    var n = 0
    for (var j = 0; j < t.items.length; j++) if (sel[itemKey(t, t.items[j])]) n++
    return n
  }

  // "all" | "some" | "none"
  function checkState(t) {
    if (!t.selectable) return sel[t.id] ? "all" : "none"
    var n = pickedCount(t)
    return n === 0 ? "none" : (n === t.items.length ? "all" : "some")
  }

  function setTargets(list, on) {
    if (cleaning) return
    var next = Object.assign({}, sel)
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (t.selectable) for (var j = 0; j < t.items.length; j++) next[itemKey(t, t.items[j])] = on
      else next[t.id] = on
    }
    sel = next
  }

  function toggleTarget(t) { setTargets([t], checkState(t) !== "all") }

  function toggleItem(t, item) {
    if (cleaning) return
    var next = Object.assign({}, sel)
    var key = itemKey(t, item)
    next[key] = !next[key]
    sel = next
  }

  function sectionAllPicked(list) {
    for (var i = 0; i < list.length; i++) if (checkState(list[i]) !== "all") return false
    return list.length > 0
  }

  function toggleExpanded(t) {
    var next = Object.assign({}, expanded)
    next[t.id] = !next[t.id]
    expanded = next
  }

  // ---------------------------------------------------------------------
  // Actions

  function commonArgs() {
    return ["--stale-days", String(staleDays), "--roots", scanRoots]
  }

  function refreshDisk() {
    if (!dfProc.running) dfProc.running = true
  }

  function scan() {
    if (scanProc.running || cleanProc.running) return
    scanProc.command = ["bash", script, "scan", "--json"].concat(commonArgs())
    scanProc.running = true
  }

  function applyScan(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) {
      showResult("Scan failed: " + (String(scanErr.text).trim() || "bad output"), true)
      return
    }
    // Keep earlier ticks for things still there; new things get the tier default.
    var next = {}
    for (var i = 0; i < data.targets.length; i++) {
      var t = data.targets[i]
      var on = t.tier === "safe"
      if (t.selectable) {
        for (var j = 0; j < t.items.length; j++) {
          var key = itemKey(t, t.items[j])
          next[key] = sel[key] !== undefined ? sel[key] : on
        }
      } else {
        next[t.id] = sel[t.id] !== undefined ? sel[t.id] : on
      }
    }
    sel = next
    targets = data.targets
    ignoredCount = data.ignored || 0
    scannedAt = Date.now()
    if (cursor >= rows.length) cursor = rows.length - 1
    applyDisk(data.disk)
  }

  function applyDisk(d) {
    if (!d) return
    diskSize = d.size
    diskUsed = d.used
    diskAvail = d.avail
    if (low && !warned) {
      warned = true
      Quickshell.execDetached(["notify-send", "-u", "critical", "-a", "Disk Space", "Disk almost full",
        "Only " + gb(diskAvail) + " GB free. Click the disk icon in the bar to clean up."])
    } else if (diskAvail > (warnFreeGB + 2) * gib) {
      warned = false
    }
  }

  function showResult(text, isError) {
    resultText = text
    resultIsError = isError
  }

  function askClean() {
    if (busy || cleanArgs.length === 0) return
    confirm.selectedIndex = 1
    confirmOpen = true
  }

  function clean() {
    confirmOpen = false
    if (busy || cleanArgs.length === 0) return
    var queue = []
    for (var i = 0; i < pickedTargets.length; i++) queue.push(pickedTargets[i].id)
    cleanQueue = queue
    cleanDone = 0
    cleanCurrent = ""
    freedKb = 0
    showResult("", false)
    cleanProc.command = ["bash", script, "clean"].concat(commonArgs()).concat(cleanArgs)
    cleanProc.running = true
  }

  function labelOf(id) {
    for (var i = 0; i < targets.length; i++) if (targets[i].id === id) return targets[i].label
    return id
  }

  function parentDir(path) { return String(path).replace(/\/[^\/]+\/?$/, "") }

  function isProjectTarget(t) { return t.id === "build-caches" || t.id === "stale-deps" || t.id === "stale-venvs" }

  function openItem(t, item) {
    var dir = isProjectTarget(t) ? parentDir(item.path) : item.path
    if (t.id === "trash-old" || t.id === "trash-all") dir = "trash:///"
    Quickshell.execDetached(["xdg-open", dir])
  }

  function ignoreItem(t, item) {
    if (!isProjectTarget(t) || busy) return
    ignoreProc.command = ["bash", script, "ignore", parentDir(item.path)]
    ignoreProc.running = true
  }

  function unignoreAll() {
    if (busy) return
    ignoreProc.command = ["bash", script, "unignore", "--all"]
    ignoreProc.running = true
  }

  function systemCleanup() {
    close()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "bash '" + script.replace(/'/g, "'\\''") + "' system"])
  }

  function openLog() {
    Quickshell.execDetached(["xdg-open", logPath])
  }

  // ---------------------------------------------------------------------
  // Keyboard cursor over target and item rows (headers are skipped).

  function moveCursor(dy) {
    if (rows.length === 0) return
    var i = cursor < 0 ? (dy > 0 ? -1 : rows.length) : cursor
    do { i += dy } while (i >= 0 && i < rows.length && (rows[i].kind === "header" || rows[i].kind === "more"))
    if (i >= 0 && i < rows.length) cursor = i
    scrollToCursor()
  }

  function scrollToCursor() {
    Qt.callLater(function() {
      var item = rowRepeater.itemAt(cursor)
      if (!item) return
      var y = item.y
      if (y < flick.contentY) flick.contentY = Math.max(0, y - Style.space(8))
      else if (y + item.height > flick.contentY + flick.height)
        flick.contentY = Math.min(flick.contentHeight - flick.height, y + item.height - flick.height + Style.space(8))
    })
  }

  function cursorRow() { return cursor >= 0 && cursor < rows.length ? rows[cursor] : null }

  function activateCursor() {
    var r = cursorRow()
    if (!r) return
    if (r.kind === "target") toggleTarget(r.target)
    else if (r.kind === "item" && r.target.selectable) toggleItem(r.target, r.item)
  }

  function expandCursor(open) {
    var r = cursorRow()
    if (!r) return
    if (r.kind === "target") {
      if (r.target.items.length > 0 && !!expanded[r.target.id] !== open) toggleExpanded(r.target)
    } else if (r.kind === "item" && !open) {
      // Collapse from inside a folder list: jump back to its target row.
      for (var i = cursor; i >= 0; i--) if (rows[i].kind === "target") { cursor = i; break }
      toggleExpanded(r.target)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursor = -1
    confirmOpen = false
    refreshDisk()
    // Scanning walks your projects, so only redo it when the result is old.
    if (Date.now() - scannedAt > 10 * 60 * 1000) scan()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: dfProc
    command: ["df", "-B1", "--output=size,used,avail", "/"]
    stdout: StdioCollector {
      onStreamFinished: {
        var line = String(text).trim().split("\n").pop().trim().split(/\s+/)
        if (line.length === 3)
          root.applyDisk({ size: Number(line[0]), used: Number(line[1]), avail: Number(line[2]) })
      }
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector { id: scanOut }
    stderr: StdioCollector { id: scanErr }
    onExited: function(code) {
      if (code === 0) root.applyScan(scanOut.text)
      else root.showResult("Scan failed: " + (String(scanErr.text).trim() || ("exit " + code)), true)
    }
  }

  Process {
    id: cleanProc
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line).trim().split(/\s+/)
        if (parts[0] === "start") root.cleanCurrent = root.labelOf(parts[1])
        else if (parts[0] === "cleaned" || parts[0] === "failed") root.cleanDone++
        else if (parts[0] === "total") root.freedKb = Number(parts[1]) || 0
      }
    }
    stderr: StdioCollector { id: cleanErr }
    onExited: function(code) {
      var err = String(cleanErr.text).trim()
      var last = err.split("\n").pop()
      if (code === 0)
        root.showResult("Freed " + root.human(root.freedKb) + (last !== "" ? ". " + last : ""), false)
      else
        root.showResult("Freed " + root.human(root.freedKb) + ", but some items failed: " + (last || ("exit " + code)), true)
      root.cleanCurrent = ""
      root.refreshDisk()
      // The process still reports running inside its own exit handler.
      Qt.callLater(root.scan)
    }
  }

  Process {
    id: ignoreProc
    onExited: Qt.callLater(root.scan)
  }

  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDisk()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function scan(): string { root.scan(); return "ok" }
    function status(): string {
      return JSON.stringify({ size: root.diskSize, used: root.diskUsed, avail: root.diskAvail, low: root.low,
        scanning: root.scanning, cleaning: root.cleaning, opened: root.opened, cursor: root.cursor,
        selectedKb: root.selectedKb, args: root.cleanArgs, result: root.resultText })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool withLabel: root.showFreeSpace && !(root.bar && root.bar.vertical) && root.diskSize > 0
    text: withLabel ? "󰋊 " + root.gb(root.diskAvail) + "G" : "󰋊"
    foreground: root.low ? root.urgent : root.barForeground
    tooltipText: root.diskSize > 0 ? root.gb(root.diskAvail) + " GB free of " + root.gb(root.diskSize) + " GB" : "Disk space"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refreshDisk()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          if (dx !== 0) confirm.selectedIndex = confirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dy !== 0) root.moveCursor(dy)
        else root.expandCursor(dx > 0)
      }
      onActivateRequested: {
        if (root.confirmOpen) {
          if (confirm.selectedIndex === 1) root.clean()
          else root.confirmOpen = false
        } else {
          root.activateCursor()
        }
      }
      onCloseRequested: {
        if (root.confirmOpen) root.confirmOpen = false
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.confirmOpen) confirm.selectedIndex = confirm.selectedIndex === 0 ? 1 : 0
        else root.switchPanel(direction)
      }
      onTextKey: function(t) {
        if (root.confirmOpen) return
        var r = root.cursorRow()
        if (t === "r" || t === "R") root.scan()
        else if (t === "c" || t === "C") root.askClean()
        else if (t === "s" || t === "S") root.systemCleanup()
        else if ((t === "o" || t === "O") && r && r.kind === "item") root.openItem(r.target, r.item)
        else if ((t === "i" || t === "I") && r && r.kind === "item") root.ignoreItem(r.target, r.item)
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // ── Disk summary ───────────────────────────────────────────────
        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          Text {
            id: freeText
            text: root.diskSize > 0 ? root.gb(root.diskAvail) + " GB" : "…"
            color: root.low ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignBaseline
            text: root.diskSize > 0 ? "free of " + root.gb(root.diskSize) + " GB" : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          PanelActionButton {
            iconText: "󰑐"
            tooltipText: "Rescan (r)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.busy
            opacity: enabled ? 1 : 0.4
            onClicked: root.scan()
          }
          PanelActionButton {
            iconText: "󰒓"
            tooltipText: "System cleanup (s): journal, crash dumps, package cache, Docker, snapshots. Opens a terminal and asks before each step"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.systemCleanup()
          }
        }

        // used | selected to free | free
        Item {
          width: parent.width
          height: Style.space(10)
          readonly property real usedFrac: root.diskSize > 0 ? Math.min(1, root.diskUsed / root.diskSize) : 0
          readonly property real freeingFrac: root.diskSize > 0 ? Math.min(usedFrac, root.selectedKb * 1024 / root.diskSize) : 0

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Util.alpha(root.foreground, 0.1)
          }
          Rectangle {
            height: parent.height
            width: parent.width * parent.usedFrac
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: root.low ? root.urgent : Util.alpha(root.foreground, 0.7)
            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
          }
          Rectangle {
            visible: parent.freeingFrac > 0
            height: parent.height
            width: Math.max(Style.space(3), parent.width * parent.freeingFrac)
            x: parent.width * parent.usedFrac - width
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: root.accent
            Behavior on width { NumberAnimation { duration: 250 } }
          }
        }

        Row {
          spacing: Style.space(14)
          Legend { swatch: Util.alpha(root.foreground, 0.7); label: "Used " + root.gb(root.diskUsed) + " GB" }
          Legend { swatch: root.accent; label: "Selected " + root.human(root.selectedKb); visible: root.selectedKb > 0 }
          Legend { swatch: Util.alpha(root.foreground, 0.2); label: "Free " + root.gb(root.diskAvail) + " GB" }
        }

        // ── Primary action and status ─────────────────────────────────
        Button {
          width: parent.width
          bordered: true
          active: enabled
          enabled: !root.busy && root.cleanArgs.length > 0
          opacity: enabled || root.cleaning ? 1 : 0.5
          iconText: root.cleaning ? "󰑐" : "󰃢"
          iconSpinning: root.cleaning
          text: root.cleaning
            ? "Cleaning " + (root.cleanCurrent || "…") + "  " + Math.min(root.cleanDone + 1, root.cleanQueue.length) + "/" + root.cleanQueue.length
            : root.scanning ? "Scanning…"
            : root.cleanArgs.length > 0 ? "Free up " + root.human(root.selectedKb) : "Nothing selected"
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          tooltipText: "Delete the ticked items (c)"
          onClicked: root.askClean()
        }

        Text {
          textFormat: Text.PlainText
          visible: root.resultText !== ""
          width: parent.width
          text: (root.resultIsError ? "󰀦  " : "󰄬  ") + root.resultText
          color: root.resultIsError ? root.urgent : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ── Target list ───────────────────────────────────────────────
        Flickable {
          id: flick
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(440))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: flick.width - (flick.interactive ? Style.space(10) : 0)
            spacing: Style.space(3)

            Text {
              textFormat: Text.PlainText
              visible: root.targets.length === 0
              width: parent.width
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
              text: root.scanning ? "Scanning caches and projects…" : "Open the panel to scan."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              id: rowRepeater
              model: root.rows
              Loader {
                id: rowLoader
                required property var modelData
                required property int index
                width: listColumn.width
                sourceComponent: modelData.kind === "header" ? headerComp
                  : modelData.kind === "target" ? targetComp
                  : modelData.kind === "more" ? moreComp : itemComp

                Component { id: headerComp; SectionHeader { row: rowLoader.modelData } }
                Component { id: targetComp; TargetRow { row: rowLoader.modelData; rowIndex: rowLoader.index } }
                Component { id: itemComp; ItemRow { row: rowLoader.modelData; rowIndex: rowLoader.index } }
                Component { id: moreComp; MoreRow { row: rowLoader.modelData } }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.targets.length > 0 && root.visibleTargets.length === 0
              width: parent.width
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
              text: "󰄬  Nothing worth cleaning right now."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

        // ── Footer ────────────────────────────────────────────────────
        PanelSeparator { foreground: root.foreground }

        RowLayout {
          width: parent.width
          spacing: Style.space(14)

          LinkText {
            visible: root.ignoredCount > 0
            text: "󰈉 " + root.plural(root.ignoredCount, "hidden project") + " · show"
            onClicked: root.unignoreAll()
          }
          LinkText {
            text: "󰦪 Log"
            onClicked: root.openLog()
          }
          Item { Layout.fillWidth: true }
          Text {
            text: "space pick · → expand · c clean"
            color: Util.alpha(root.foreground, 0.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Free up " + root.human(root.selectedKb) + " from " + root.plural(root.pickedTargets.length, "target") + "?"
          + (root.pickedLost.length > 0
            ? " Can't be undone, and won't come back by itself: "
              + root.pickedLost.map(function(t) { return t.label }).join(", ") + "."
            : " Everything picked rebuilds itself.")
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.confirmOpen = false
        onConfirmed: root.clean()
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────
  // Row components

  component Legend: Row {
    id: legend
    property color swatch: root.foreground
    property string label: ""
    spacing: Style.space(5)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7); height: width
      radius: Style.cornerRadius > 0 ? width / 2 : 0
      color: legend.swatch
    }
    Text {
      text: legend.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component LinkText: Text {
    id: link
    signal clicked()
    color: linkMouse.containsMouse ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      anchors.margins: -Style.space(3)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }
  }

  component CheckGlyph: Text {
    property string mark: "none"
    text: mark === "all" ? "󰄲" : mark === "some" ? "󰡖" : "󰄱"
    color: mark === "none" ? root.dim : root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon
  }

  component SectionHeader: Item {
    id: sh
    property var row: ({})
    readonly property var list: row.list || []
    readonly property bool review: row.tier === "review"
    readonly property bool allOn: root.sectionAllPicked(list)
    readonly property double total: list.reduce(function(s, t) { return s + t.kb }, 0)
    implicitHeight: headerRow.implicitHeight + Style.space(review ? 16 : 4)

    RowLayout {
      id: headerRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(4)
      anchors.leftMargin: Style.space(2)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: (sh.review ? "󰀦  " : "󰗠  ") + sh.row.title.toUpperCase()
        color: sh.review ? root.urgent : root.foreground
        opacity: 0.85
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }
      Text {
        text: root.human(sh.total)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      LinkText {
        text: sh.allOn ? "none" : "all"
        onClicked: root.setTargets(sh.list, !sh.allOn)
      }
    }
  }

  component TargetRow: CursorSurface {
    id: trow
    property var row: ({})
    property int rowIndex: -1
    readonly property var t: row.target || ({})
    readonly property bool hasItems: (t.items || []).length > 0
    readonly property bool isOpen: !!root.expanded[t.id]
    readonly property string mark: root.checkState(t)
    readonly property bool review: t.tier === "review"
    readonly property bool projects: root.isProjectTarget(t)

    hasCursor: root.cursor === rowIndex
    foreground: root.foreground
    implicitHeight: trowContent.implicitHeight + Style.space(14)

    // Size bar behind the row, relative to the biggest target.
    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * Math.min(1, (trow.t.kb || 0) / root.maxKb)
      color: Util.alpha(trow.review ? root.urgent : root.accent, 0.08)
      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: !root.cleaning
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = trow.rowIndex
      // The chevron end of the row expands; anywhere else ticks.
      onClicked: function(mouse) {
        if (trow.hasItems && mouse.x > width - Style.space(40)) root.toggleExpanded(trow.t)
        else root.toggleTarget(trow.t)
      }
    }

    RowLayout {
      id: trowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      CheckGlyph { mark: trow.mark; Layout.alignment: Qt.AlignVCenter }

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(28); implicitHeight: implicitWidth
        radius: Style.cornerRadius > 0 ? Style.space(7) : 0
        color: Util.alpha(trow.review ? root.urgent : root.foreground, 0.1)
        Text {
          anchors.centerIn: parent
          text: trow.t.icon || "󰋊"
          color: trow.review ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: trow.t.label || ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: trow.t.selectable && trow.hasItems && trow.t.items.length > 1
            ? root.pickedCount(trow.t) + " of " + trow.t.items.length + " picked · " + trow.t.description
            : trow.t.description || ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: !!trow.t.note
          text: "󰀦 " + (trow.t.note || "")
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.alignment: Qt.AlignVCenter
        text: (trow.t.estimate ? "≤ " : "") + root.human(trow.mark === "none" ? trow.t.kb : root.pickedKb(trow.t))
        color: trow.mark === "none" ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: trow.mark !== "none"
      }

      Text {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(18)
        text: trow.hasItems ? (trow.isOpen ? "󰅀" : "󰅂") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  component MoreRow: Text {
    property var row: ({})
    readonly property var t: row.target || ({})
    textFormat: Text.PlainText
    leftPadding: Style.space(34)
    topPadding: Style.space(4)
    bottomPadding: Style.space(6)
    wrapMode: Text.WordWrap
    text: "Showing the largest " + (t.items || []).length + " of " + t.count + ". Clean the rest from the terminal: " + root.script + " clean " + t.id
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component ItemRow: CursorSurface {
    id: irow
    property var row: ({})
    property int rowIndex: -1
    readonly property var t: row.target || ({})
    readonly property var item: row.item || ({})
    readonly property bool picked: !!root.sel[root.itemKey(t, item)]
    readonly property bool canPick: !!t.selectable
    readonly property bool canIgnore: root.isProjectTarget(t)

    hasCursor: root.cursor === rowIndex
    foreground: root.foreground
    implicitHeight: irowContent.implicitHeight + Style.space(10)

    // Thread line tying the folder to its target.
    Rectangle {
      x: Style.space(19)
      width: Style.space(1)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      color: Util.alpha(root.foreground, 0.15)
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: !root.cleaning
      cursorShape: irow.canPick ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.cursor = irow.rowIndex
      onClicked: if (irow.canPick) root.toggleItem(irow.t, irow.item)
    }

    RowLayout {
      id: irowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(34)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      CheckGlyph {
        visible: irow.canPick
        mark: irow.picked ? "all" : "none"
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: irow.item.label || ""
          color: irow.picked || !irow.canPick ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: irow.item.meta || ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Visible on the row under the cursor (mouse or keyboard).
      PanelActionButton {
        visible: irow.hasCursor
        iconText: "󰉋"
        tooltipText: "Open folder (o)"
        size: Style.space(24)
        fontSize: Style.font.body
        foreground: root.foreground
        fontFamily: root.fontFamily
        onHovered: function(on) { if (on) root.cursor = irow.rowIndex }
        onClicked: root.openItem(irow.t, irow.item)
      }
      PanelActionButton {
        visible: irow.canIgnore && irow.hasCursor
        iconText: "󰈉"
        tooltipText: "Never suggest this project again (i)"
        size: Style.space(24)
        fontSize: Style.font.body
        foreground: root.foreground
        fontFamily: root.fontFamily
        onHovered: function(on) { if (on) root.cursor = irow.rowIndex }
        onClicked: root.ignoreItem(irow.t, irow.item)
      }

      Text {
        textFormat: Text.PlainText
        Layout.alignment: Qt.AlignVCenter
        text: root.human(irow.item.kb || 0)
        color: irow.picked ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Item { Layout.preferredWidth: Style.space(18) }
    }
  }
}
