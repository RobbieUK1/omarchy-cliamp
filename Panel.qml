import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the cliamp terminal music player (https://cliamp.stream).
//
// The button sits on the bar permanently. Clicking it opens a dropdown that
// controls playback (prev / play-pause / next) and lets you jump
// between stations from the built-in "default" list (radio.cliamp.stream/
// streams.m3u), a live Radio Browser search, or your favourites
// (~/.config/cliamp/favorites.toml). A bookmark toggle on each row adds or
// removes that station from favourites.
//
// State comes from a small helper script so the widget never needs to parse
// cliamp's raw IPC output itself. The socket is watched with a FileView, so
// the widget wakes up the moment cliamp starts or stops; a slow poll timer
// is the fallback and drives the fast poll while cliamp is active.
Panel {
  id: root
  moduleName: "robbie.cliamp"
  ipcTarget: "robbie.cliamp"
  manageIpc: true

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/robbie.cliamp/cliamp.py"
  readonly property string socketPath: Quickshell.env("HOME") + "/.config/cliamp/cliamp.sock"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Runtime snapshot, refreshed by pollTimer / socket watcher.
  property bool running: false
  property string pState: "stopped" // "playing" | "paused" | "stopped"
  property string currentTitle: ""
  property string currentPath: ""

  // Set when a station is picked while cliamp is stopped. The URL is played
  // as soon as the player socket appears (see applyPoll / launchTimer).
  property string pendingPlayUrl: ""
  property bool launcherArmed: false

  // The station sources. `default` comes from cliamp's streams.m3u,
  // `favorites` from favorites.toml (both delivered by the helper), and
  // `search` from a live Radio Browser (radio-browser.info) query.
  property var defaultStations: []
  property var favorites: []
  property var searchResults: []
  property string stationSource: "default"
  property bool searching: false

  // Keyboard-cursor state over the active station list.
  property var stRows: []
  property int cursorIndex: 0

  // Playback state label shown in the dropdown header.
  readonly property bool playing: root.running && (root.pState === "playing" || root.pState === "paused")

  function sourceList() {
    if (root.stationSource === "search") return root.searchResults
    return root.stationSource === "favorites" ? root.favorites : root.defaultStations
  }

  function isFavorite(url) {
    for (var i = 0; i < root.favorites.length; i++)
      if (root.favorites[i].url === url) return true
    return false
  }

  function stationRows() {
    var rows = []
    var src = root.sourceList()
    for (var i = 0; i < src.length; i++) {
      var s = src[i]
      var meta = ""
      if (s.country) meta = s.country
      if (s.tags) meta = meta !== "" ? meta + " · " + s.tags : s.tags
      if (s.bitrate) meta = meta !== "" ? meta + " · " + s.bitrate + "k" : s.bitrate + "k"
      rows.push({ kind: "station", title: s.title, url: s.url, active: false, fav: root.isFavorite(s.url), meta: meta })
      if (s.url === root.currentPath) rows[rows.length - 1].active = true
    }
    return rows
  }

  function rebuildStations() {
    root.stRows = root.stationRows()
    if (root.cursorIndex >= root.stRows.length) root.cursorIndex = Math.max(0, root.stRows.length - 1)
    Qt.callLater(revealRow)
  }

  function currentRow() {
    return (root.cursorIndex >= 0 && root.cursorIndex < root.stRows.length) ? root.stRows[root.cursorIndex] : null
  }

  function moveCursor(step) {
    if (root.stRows.length === 0) return
    var n = root.stRows.length
    root.cursorIndex = (root.cursorIndex + step + n) % n
  }

  function activateRow(row) {
    if (row && row.kind === "station" && row.url) root.playStation(row.url)
  }

  // Type-to-search: any single-character key switches to the Search tab and
  // routes into the search field so it is visible/focused.
  function keyTyped(text) {
    if (!text) return
    if (root.stationSource !== "search") {
      root.stationSource = "search"
      root.rebuildStations()
    }
    searchField.insert(searchField.cursorPosition, text)
    searchField.forceActiveFocus()
  }

  function clickRow(index) {
    if (index < 0 || index >= root.stRows.length) return
    root.cursorIndex = index
    root.activateRow(root.stRows[index])
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.command = ["python3", root.scriptPath, "poll"]
    statusProc.running = false
    statusProc.running = true
  }

  function applyPoll(raw) {
    var d = {}
    try { d = JSON.parse(raw) } catch (e) { d = {} }
    root.running = !!d.running
    root.pState = String(d.state || "stopped")
    root.currentTitle = String(d.title || "")
    root.currentPath = String(d.path || "")
    if (root.running && root.pendingPlayUrl !== "") {
      var queued = root.pendingPlayUrl
      root.pendingPlayUrl = ""
      root.launcherArmed = false
      root.playStation(queued)
    }
    if (d.stations) {
      if (d.stations.default) root.defaultStations = d.stations.default
      if (d.stations.favorites) root.favorites = d.stations.favorites
    }
    root.rebuildStations()
  }

  function runSearch() {
    var q = searchField.text.trim()
    if (q === "") {
      root.searching = false
      root.searchResults = []
      if (root.stationSource === "search") root.stationSource = "default"
      root.rebuildStations()
      return
    }
    if (searchProc.running) return
    root.searching = true
    searchProc.command = ["python3", root.scriptPath, "search", q]
    searchProc.running = false
    searchProc.running = true
  }

  function applySearch(raw) {
    root.searching = false
    var d = {}
    try { d = JSON.parse(raw) } catch (e) { d = {} }
    root.searchResults = (d.results || []).map(function(s) {
      return {
        title: String(s.title || ""),
        url: String(s.url || ""),
        country: String(s.country || ""),
        tags: String(s.tags || ""),
        bitrate: Number(s.bitrate) || 0,
        votes: Number(s.votes) || 0
      }
    })
    root.stationSource = "search"
    root.cursorIndex = 0
    root.rebuildStations()
  }

  function doControl(cmd) {
    if (!root.running) return
    ctrlProc.command = ["python3", root.scriptPath, "raw", cmd]
    ctrlProc.running = false
    ctrlProc.running = true
  }

  function playStation(url) {
    if (!url) return
    if (root.running) {
      root.pendingPlayUrl = ""
      playProc.command = ["python3", root.scriptPath, "play", url]
      playProc.running = false
      playProc.running = true
      return
    }
    root.pendingPlayUrl = url
    if (root.launcherArmed) return
    root.launcherArmed = true
    launchTimer.restart()
    launchProc.command = ["omarchy-launch-or-focus-tui", "cliamp"]
    launchProc.running = false
    launchProc.running = true
  }

  function toggleFavorite(url, title) {
    if (!url || favoriteProc.running) return
    favoriteProc.command = ["python3", root.scriptPath, "favorite", url, title || ""]
    favoriteProc.running = false
    favoriteProc.running = true
  }

  function applyFavorite(raw) {
    var d = {}
    try { d = JSON.parse(raw) } catch (e) { d = {} }
    if (d.favorites) root.favorites = d.favorites
    root.rebuildStations()
  }

  function stateLabel() {
    if (root.pState === "playing") return "Playing"
    if (root.pState === "paused") return "Paused"
    return "Stopped"
  }

  function barTooltip() {
    if (root.currentTitle !== "") return "Cliamp · " + root.currentTitle
    return "Cliamp"
  }

  function revealRow() {
    if (!stRowsRepeater || !stScroll) return
    if (root.cursorIndex < 0 || root.cursorIndex >= stRowsRepeater.count) return
    var item = stRowsRepeater.itemAt(root.cursorIndex)
    if (!item) return
    var pos = item.mapToItem(stRowsColumn, 0, 0)
    var pad = Style.space(6)
    var top = stScroll.contentY
    var bottom = top + stScroll.height
    if (pos.y < top) stScroll.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + item.height > bottom)
      stScroll.contentY = pos.y + item.height - stScroll.height + pad
  }

  Process {
    id: statusProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPoll(text)
    }
    onExited: function(code, status) {
      if (code !== 0) root.applyPoll("")
    }
  }

  Process {
    id: ctrlProc
    running: false
  }

  Process {
    id: playProc
    running: false
  }

  Process {
    id: launchProc
    running: false
  }

  Timer {
    id: launchTimer
    interval: 15000
    repeat: false
    onTriggered: {
      root.launcherArmed = false
      root.pendingPlayUrl = ""
    }
  }

  Process {
    id: favoriteProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFavorite(text)
    }
  }

  Process {
    id: searchProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearch(text)
    }
    onExited: function(code, status) {
      root.searching = false
    }
  }

  // Watch cliamp's Unix socket so the widget wakes up as soon as the player
  // starts/stops instead of waiting for the slow poll.
  FileView {
    id: sockView
    path: root.socketPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
    onLoaded: root.refresh()
    onLoadFailed: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: root.running ? 2500 : 6000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: searchDebounce
    interval: 350
    repeat: false
    onTriggered: root.runSearch()
  }

  onOpenedChanged: {
    if (root.opened) {
      root.rebuildStations()
      Qt.callLater(revealRow)
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰝚"
    tooltipText: root.barTooltip()
    active: root.running && !root.opened
    activeColor: root.accent
    onPressed: function(buttonCode) {
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.cappedContentHeight(Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx); root.revealRow() }
      onActivateRequested: root.activateRow(root.currentRow())
      onDeleteRequested: root.activateRow(root.currentRow())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.keyTyped(t) }

      Column {
        id: column
        width: parent.width
        height: parent.height
        spacing: 0

        // ---- header
        Item {
          id: headerBox
          width: parent.width
          height: headerRow.implicitHeight + Style.space(8)

          Row {
            id: headerRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              id: headerIconText
              text: "󰝚"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: headerTitleText
              text: "Cliamp"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: headerStatusText
              text: root.playing ? root.stateLabel() : (root.launcherArmed ? "Starting cliamp…" : "Not playing")
              color: root.pState === "playing" ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Item {
              id: headerCtrlSpace
              height: parent.height
              width: Math.max(0, parent.width - headerIconText.implicitWidth
                - headerTitleText.implicitWidth - headerStatusText.implicitWidth
                - headerRow.spacing * 3)

              Row {
                id: headerCtrls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Button {
                  iconText: "󰒮"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX + 2
                  verticalPadding: Style.spacing.controlPaddingY
                  enabled: root.running
                  opacity: enabled ? 1.0 : 0.35
                  tooltipText: "Previous"
                  onClicked: root.doControl("prev")
                }

                Button {
                  iconText: root.pState === "playing" ? "󰏤" : "󰐊"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.panelGap
                  verticalPadding: Style.spacing.controlPaddingY
                  iconSize: Style.font.iconLarge
                  enabled: root.running
                  opacity: enabled ? 1.0 : 0.35
                  tooltipText: "Play / Pause"
                  onClicked: root.doControl("toggle")
                }

                Button {
                  iconText: "󰒭"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX + 2
                  verticalPadding: Style.spacing.controlPaddingY
                  enabled: root.running
                  opacity: enabled ? 1.0 : 0.35
                  tooltipText: "Next"
                  onClicked: root.doControl("next")
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- now playing
        Item {
          id: nowBox
          width: parent.width
          height: nowColumn.implicitHeight + Style.space(8)

          Column {
            id: nowColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(1)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.currentTitle !== "" ? root.currentTitle : "Nothing playing yet"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: root.currentTitle !== ""
              elide: Text.ElideRight
              visible: text !== ""
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.currentPath !== "" ? root.currentPath : "Pick a station below"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              visible: text !== ""
            }
          }
        }

        // ---- station source tabs
        Item {
          id: chipsBox
          width: parent.width
          height: chipsRow.implicitHeight + Style.space(8)

          Row {
            id: chipsRow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Default"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              selected: root.stationSource === "default"
              horizontalPadding: Style.spacing.controlPaddingX + 4
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.stationSource = "default"
                root.cursorIndex = 0
                root.rebuildStations()
              }
            }

            Button {
              text: root.searchResults.length > 0
                ? "Search (" + root.searchResults.length + ")"
                : "Search"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              selected: root.stationSource === "search"
              horizontalPadding: Style.spacing.controlPaddingX + 4
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.stationSource = "search"
                root.cursorIndex = 0
                root.rebuildStations()
                searchField.forceActiveFocus()
              }
            }

            Button {
              text: "Favourites (" + root.favorites.length + ")"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              selected: root.stationSource === "favorites"
              horizontalPadding: Style.spacing.controlPaddingX + 4
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.stationSource = "favorites"
                root.cursorIndex = 0
                root.rebuildStations()
              }
            }
          }
        }

        // ---- radio directory search (shown only on the Search tab)
        Item {
          id: searchBox
          visible: root.stationSource === "search"
          width: parent.width
          height: visible ? searchRow.implicitHeight + Style.space(8) : 0

          Row {
            id: searchRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              id: searchIcon
              text: "󰛉"
              color: root.searching ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            TextField {
              id: searchField
              width: parent.width - searchIcon.implicitWidth - searchRow.spacing
              height: Style.space(26)
              verticalPadding: Math.max(2, Style.spacing.inputPaddingY - 4)
              accent: root.accent
              foreground: root.foreground
              placeholderText: root.searching ? "Searching…" : "Search radio stations…"
              onTextChanged: searchDebounce.restart()
              onAccepted: {
                searchDebounce.stop()
                root.runSearch()
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- picker
        Flickable {
          id: stScroll
          width: parent.width
          height: column.height - headerBox.height - nowBox.height
            - searchBox.height - chipsBox.height - footerBox.height - Style.space(2)
          clip: true
          contentWidth: width
          contentHeight: stRowsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            width: 6
          }

          Column {
            id: stRowsColumn
            width: parent.width
            spacing: 0

            Repeater {
              id: stRowsRepeater
              model: root.stRows

              delegate: Item {
                id: stRowItem
                required property var modelData
                required property int index

                readonly property var row: modelData
                readonly property bool hasCursor: root.cursorIndex === index
                readonly property bool isActive: row ? !!row.active : false
                readonly property bool hasMeta: row ? !!row.meta : false
                readonly property bool isFav: row ? !!row.fav : false

                width: stRowsColumn.width
                height: (stRowItem.hasMeta ? Style.space(40) : Style.spacing.popupRowHeight) + Style.space(4)

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  radius: Style.cornerRadius
                  color: stRowItem.hasCursor
                    ? Style.hoverFillFor(root.foreground, root.accent)
                    : "transparent"

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: {
                      if (root.cursorIndex !== stRowItem.index) root.cursorIndex = stRowItem.index
                    }
                    onClicked: root.clickRow(stRowItem.index)
                  }
                }

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(18)
                    textFormat: Text.PlainText
                    text: stRowItem.isActive ? "󰐊" : ""
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    width: parent.width - Style.space(18) - Style.space(8)
                      - favBtn.width - Style.space(8)
                      - (stRowItem.isActive ? playingTag.width + Style.space(8) : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: stRowItem.row ? String(stRowItem.row.title || "") : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: stRowItem.isActive
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      visible: stRowItem.hasMeta
                      textFormat: Text.PlainText
                      text: stRowItem.hasMeta ? String(stRowItem.row.meta || "") : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Item {
                    id: favBtn
                    width: Style.space(20)
                    height: Style.space(20)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: stRowItem.row ? !!stRowItem.row.url : false

                    Text {
                      anchors.centerIn: parent
                      text: stRowItem.isFav ? "󰃂" : "󰃃"
                      color: stRowItem.isFav ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      hoverEnabled: true
                      onEntered: {
                        if (root.cursorIndex !== stRowItem.index) root.cursorIndex = stRowItem.index
                      }
                      onClicked: {
                        if (stRowItem.row && stRowItem.row.url)
                          root.toggleFavorite(stRowItem.row.url, stRowItem.row.title)
                      }
                      PanelToolTip {
                        visible: parent.containsMouse
                        text: stRowItem.isFav ? "Remove from favourites" : "Add to favourites"
                      }
                    }
                  }

                  Text {
                    id: playingTag
                    visible: stRowItem.isActive
                    textFormat: Text.PlainText
                    text: "playing"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }
        }

        // ---- footer
        Item {
          id: footerBox
          width: parent.width
          height: footerLabel.implicitHeight + Style.space(8)

          Text {
            id: footerLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Click a row to play · bookmark toggles favourites · Esc closes"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}