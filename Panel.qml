import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Home Assistant in the Omarchy bar: a favourites dashboard behind the icon,
// the full device list a keypress away, and per-device controls for every
// domain the REST API can drive.
//
// Four views share one popup. `view` is the whole navigation model — there is
// no stack, because every route out of a device is back to the list it came
// from. Keyboard and mouse drive the same cursor state (focusSection plus an
// index), which is what keeps a single highlight on screen no matter which
// one the user last touched.
Panel {
  id: root
  moduleName: "romeo.home-assistant"
  ipcTarget: "romeo.home-assistant"
  manageIpc: false

  // favorites | devices | detail | settings
  property string view: "favorites"
  property string detailId: ""
  property string query: ""
  property bool searching: false

  property int listIndex: 0
  property int detailIndex: -1
  // Which button inside a focused `actions` control the keyboard sits on.
  property int detailButtonIndex: 0
  property bool cursorActive: false
  readonly property bool listVisible: view === "favorites" || view === "devices"

  // Rows carry a switch on some devices and a button on others. Reserving one
  // width for either keeps the state column's right edge straight instead of
  // letting it wander by the difference between the two controls.
  readonly property real rowControlWidth:
    Math.max(Math.round(Style.space(18) * 1.9), Style.space(22))

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ view model

  readonly property var detailEntity: detailId === "" ? null : hass.byId[detailId]
  readonly property var detailControls: detailEntity ? Model.controlsFor(detailEntity) : []

  // The devices view lists everything; favourites lists the chosen few. Both
  // run through the same search and the same optional area grouping, so the
  // two views differ only in what they start from.
  readonly property var sourceEntities: {
    if (view === "favorites") return hass.favoriteEntities
    return Model.sortEntities(hass.entities)
  }

  readonly property var filteredEntities: {
    var source = sourceEntities
    var out = []
    for (var i = 0; i < source.length; i++) {
      var entity = source[i]
      if (hass.hideUnavailable && Model.isUnavailable(entity) && view !== "favorites") continue
      if (!Model.matches(entity, root.query, hass.areaFor(entity.id))) continue
      out.push(entity)
    }
    return out
  }

  // One flat array of rows so the keyboard cursor is a single integer even
  // when area headers are interleaved. Headers carry no entity and the
  // cursor steps over them.
  readonly property var listRows: {
    var entities = filteredEntities
    var rows = []
    // Grouping a hand-picked favourites list would scatter it; the manual
    // order is the point of that view.
    var grouped = hass.groupByArea && (view === "devices" || hass.favoritesSource === "label")
    if (!grouped) {
      for (var i = 0; i < entities.length; i++) rows.push({ entity: entities[i] })
      return rows
    }
    var groups = hass.groupByAreas(entities)
    for (var g = 0; g < groups.length; g++) {
      rows.push({ header: groups[g].area })
      for (var e = 0; e < groups[g].entities.length; e++)
        rows.push({ entity: groups[g].entities[e] })
    }
    return rows
  }

  readonly property int rowCount: listRows.length
  readonly property var selectedEntity: {
    var row = listRows[listIndex]
    return (row && row.entity) ? row.entity : null
  }

  // Only the specs that need a keyboard stop; `info` and `note` are read-only.
  readonly property var focusableControls: {
    var out = []
    for (var i = 0; i < detailControls.length; i++) {
      var type = detailControls[i].type
      if (type === "info" || type === "note" || type === "camera") continue
      out.push(i)
    }
    return out
  }

  readonly property string deviceCount: {
    if (!hass.configured) return hass.baseUrl === "" ? "Not configured" : "No access token"
    if (!hass.everLoaded) return hass.lastError !== "" ? "Disconnected" : "Connecting…"
    if (view === "devices") return hass.entities.length + " devices"
    var favorites = hass.favoriteEntities.length
    if (favorites === 0) return "No favourites yet"
    return hass.onCount + " of " + favorites + " on"
  }

  // The hero subtitle. Errors stay out of it on purpose: they belong on the
  // red line below, which wraps and can hold a full sentence, and letting one
  // in here would swap a one-line subtitle for a two-line one and move the
  // whole panel — the very thing the detail pill used to do.
  readonly property string heroMeta: deviceCount

  // What a tooltip or an IPC `status` call should say: the same summary, but
  // carrying the failure reason when there is one, since that is the whole
  // reason someone asks.
  readonly property string statusLine: {
    if (hass.configured && hass.lastError !== "") return hass.lastError
    return deviceCount
  }

  // ------------------------------------------------------------- navigation

  function firstFocusableRow(from, direction) {
    var step = direction < 0 ? -1 : 1
    for (var i = from; i >= 0 && i < rowCount; i += step)
      if (listRows[i].entity) return i
    // Nothing that way — walk back so a trailing header never traps the cursor.
    for (var j = from; j >= 0 && j < rowCount; j -= step)
      if (listRows[j].entity) return j
    return -1
  }

  function ensureCursor() {
    if (view === "detail") {
      // -1 is a real position — the device's own switch — so only an index
      // that fell off the end of a changed control list needs correcting.
      if (detailIndex >= 0 && focusableControls.indexOf(detailIndex) === -1)
        detailIndex = focusableControls.length > 0 ? focusableControls[0] : -1
      return
    }
    if (rowCount === 0) { listIndex = 0; return }
    if (listIndex < 0) listIndex = 0
    if (listIndex >= rowCount) listIndex = rowCount - 1
    if (!listRows[listIndex].entity) {
      var next = firstFocusableRow(listIndex, 1)
      if (next >= 0) listIndex = next
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (view === "settings") return
    if (view === "detail") {
      if (dy !== 0) {
        if (focusableControls.length === 0) return
        var at = focusableControls.indexOf(detailIndex)
        // Arriving from the device's own switch, `dy > 0` lands on the first
        // control rather than skipping one.
        if (at === -1) at = dy > 0 ? 0 : focusableControls.length - 1
        else {
          var next = at + dy
          // Stepping up off the first control returns to the entity switch.
          if (next < 0) { detailIndex = -1; return }
          at = Math.min(focusableControls.length - 1, next)
        }
        detailIndex = focusableControls[at]
        detailButtonIndex = 0
        return
      }
      // Left with nothing focused is "back"; with a control focused it is
      // that control's own decrement, which is what makes a slider reachable
      // without the mouse.
      if (detailIndex < 0) { if (dx < 0) closeDetail(); return }
      adjustDetail(dx)
      return
    }
    if (dx > 0) { openDetail(selectedEntity); return }
    if (dy === 0 || rowCount === 0) return
    ensureCursor()
    var target = listIndex + dy
    while (target >= 0 && target < rowCount && !listRows[target].entity) target += dy
    if (target < 0 || target >= rowCount) return
    listIndex = target
    scrollCursorIntoView()
  }

  // The focused control's spec, or null while the cursor sits on the device's
  // own switch.
  function detailSpec() {
    if (detailIndex < 0 || detailIndex >= detailControls.length) return null
    return detailControls[detailIndex]
  }

  function adjustDetail(direction) {
    var spec = detailSpec()
    var entity = detailEntity
    if (!spec || !entity || direction === 0) return
    if (spec.type === "slider" || spec.type === "stepper") {
      var step = Number(spec.step) || 1
      var next = Number(spec.value) + step * direction
      next = Math.max(Number(spec.min), Math.min(Number(spec.max), next))
      hass.callService(entity, spec.call, next)
    } else if (spec.type === "choice") {
      var options = spec.options || []
      if (options.length === 0) return
      var at = 0
      for (var i = 0; i < options.length; i++)
        if (String(options[i].value) === String(spec.value)) at = i
      var target = (at + direction + options.length) % options.length
      hass.callService(entity, spec.call, String(options[target].value))
    } else if (spec.type === "actions") {
      var buttons = spec.buttons || []
      if (buttons.length === 0) return
      detailButtonIndex = (detailButtonIndex + direction + buttons.length) % buttons.length
    }
  }

  function activateDetail() {
    var spec = detailSpec()
    var entity = detailEntity
    if (!entity) return
    if (!spec) {
      if (Model.isToggleable(entity)) hass.toggleEntity(entity)
      return
    }
    if (spec.type === "actions") {
      var buttons = spec.buttons || []
      var index = Math.max(0, Math.min(detailButtonIndex, buttons.length - 1))
      if (buttons[index]) hass.callService(entity, buttons[index].call, undefined)
    }
  }

  function activateCursor() {
    if (view === "detail") { activateDetail(); return }
    var entity = selectedEntity
    if (!entity) return
    var action = Model.rowAction(entity)
    if (action.kind === "toggle") hass.toggleEntity(entity)
    else if (action.kind === "press") hass.callService(entity, action.call, undefined)
    else openDetail(entity)
  }

  function setListCursor(index) {
    cursorActive = true
    listIndex = index
  }

  function scrollCursorIntoView() {
    if (listView) listView.positionViewAtIndex(listIndex, ListView.Contain)
  }

  function openDetail(entity) {
    if (!entity) return
    detailId = entity.id
    detailIndex = -1
    detailButtonIndex = 0
    view = "detail"
    cursorActive = true
    if (entity.domain === "camera") hass.fetchSnapshot(entity.id)
  }

  function closeDetail() {
    if (view !== "detail") return
    detailId = ""
    view = previousListView
    cursorActive = true
    Qt.callLater(scrollCursorIntoView)
  }

  // Which list the detail view returns to. Set on the way in so the trip back
  // never dumps a device from the full list into the favourites view.
  property string previousListView: "favorites"

  function showView(next) {
    if (next === "favorites" || next === "devices") previousListView = next
    if (next !== view) {
      view = next
      listIndex = 0
      cursorActive = false
      if (listView) listView.positionViewAtBeginning()
    }
  }

  function toggleSearch() {
    if (view === "settings" || view === "detail") showView(previousListView)
    searching = !searching
    if (searching) Qt.callLater(function () { if (searchField) searchField.forceActiveFocus() })
    else { query = ""; Qt.callLater(function () { keyCatcher.forceActiveFocus() }) }
  }

  function favoriteCurrent() {
    var entity = view === "detail" ? detailEntity : selectedEntity
    if (!entity) return
    if (!hass.favoritesEditable) {
      hass.noteStatus("Favourites come from the \"" + hass.favoritesLabel + "\" label in Home Assistant")
      return
    }
    hass.toggleFavorite(entity.id)
  }

  function openCurrentInHome() {
    var entity = view === "detail" ? detailEntity : selectedEntity
    if (entity) hass.openEntity(entity.id)
    else hass.openHome()
  }

  // ------------------------------------------------------------- lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) { searching = false; query = ""; return }
    cursorActive = false
    listIndex = 0
    view = previousListView
    if (hass.configured) { hass.refresh(); hass.refreshMeta() }
    else hass.checkToken()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  onViewChanged: ensureCursor()
  onListRowsChanged: ensureCursor()

  Service {
    id: hass
    settings: root.settings
    bar: root.bar
    moduleName: root.moduleName
    active: root.opened
  }

  // Bind the panel's own settings to whatever `omarchy bar set` last wrote,
  // and let anything the panel saves flow straight back in.
  Connections {
    target: hass
    function onConfiguredChanged() { if (hass.configured && root.opened) hass.refresh() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { hass.refresh(); return "ok" }
    function status(): string { return root.statusLine }
    // Bindable from Hyprland: `omarchy-shell romeo.home-assistant call light.desk toggle`
    function call(entityId: string, service: string): string {
      var entity = hass.byId[String(entityId)]
      if (!entity) return "unknown entity"
      if (String(service) === "toggle") { hass.toggleEntity(entity); return "ok" }
      hass.callService(entity, { domain: entity.domain, service: String(service) }, undefined)
      return "ok"
    }
    function openHome(): string { hass.openHome(); return "ok" }
  }

  // ------------------------------------------------------------ bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.GLYPH.homeAssistant
    tooltipText: hass.configured
      ? (hass.connected ? "Home Assistant — " + root.statusLine : "Home Assistant — offline")
      : "Home Assistant — click to set up"
    foreground: {
      if (!hass.configured || !hass.connected) return Qt.darker(root.barForeground, 1.55)
      return hass.onCount > 0 ? root.barForeground : Qt.darker(root.barForeground, 1.35)
    }
    active: hass.configured && hass.lastError !== ""
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) hass.refresh()
      else if (buttonCode === Qt.MiddleButton) hass.openHome()
      else root.toggle()
    }
  }

  // A small count of what is on, for people who want the number without
  // opening anything. Off by default so the bar stays quiet.
  Text {
    visible: hass.setting("showCount", false) === true && hass.connected && hass.onCount > 0
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: -Style.space(1)
    anchors.topMargin: Style.space(1)
    text: String(hass.onCount)
    color: root.barForeground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  // ----------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(root.desiredHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Text inputs own their keys outright; without this, typing "j" in the
      // URL field would walk the device list instead.
      blocked: searchField.activeFocus || urlField.activeFocus || tokenField.activeFocus

      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive && dy !== 0) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.searching) root.toggleSearch()
        else if (root.view === "detail") root.closeDetail()
        else if (root.view === "settings") root.showView(root.previousListView)
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        switch (text) {
          case "/": root.toggleSearch(); break
          case "f": case "F": root.favoriteCurrent(); break
          case "o": case "O": root.openCurrentInHome(); break
          case "g": case "G": hass.openHome(); break
          case "r": case "R": hass.refresh(); hass.refreshMeta(); break
          case "a": case "A": root.showView("devices"); break
          case "d": case "D": root.showView("favorites"); break
          case "s": case "S": root.showView(root.view === "settings" ? root.previousListView : "settings"); break
          case "?": hass.openUrl("https://www.home-assistant.io/docs/"); break
        }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // ------------------------------------------------------------ hero

        Item {
          id: heroHolder
          Layout.fillWidth: true
          implicitHeight: hero.implicitHeight

          PanelHero {
            id: hero
            width: parent.width
            title: hass.locationName !== "" ? hass.locationName : "Home Assistant"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: hass.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: Model.GLYPH.homeAssistant
                color: hass.connected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }
        }

        // --------------------------------------------------------- toolbar

        RowLayout {
          id: toolbarRow
          Layout.fillWidth: true
          spacing: Style.space(6)

          ButtonGroup {
            id: viewSwitch
            visible: !root.searching
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            value: root.listVisible ? root.view : root.previousListView
            options: [
              { value: "favorites", label: "Favourites" },
              { value: "devices", label: "Devices" }
            ]
            onChanged: function (value) { root.showView(value) }
          }

          TextField {
            id: searchField
            visible: root.searching
            Layout.fillWidth: true
            foreground: root.foreground
            verticalPadding: Style.space(4)
            placeholderText: "Search devices, rooms, domains…"
            text: root.query
            onTextChanged: {
              root.query = text
              root.listIndex = 0
              if (listView) listView.positionViewAtBeginning()
            }
            Keys.onEscapePressed: root.toggleSearch()
            Keys.onDownPressed: {
              root.cursorActive = true
              keyCatcher.forceActiveFocus()
            }
          }

          Item { Layout.fillWidth: !root.searching; implicitHeight: 1 }

          PanelActionButton {
            iconText: Model.GLYPH.search
            tooltipText: root.searching ? "Close search  ·  /" : "Search  ·  /"
            foreground: root.searching ? Color.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.toggleSearch()
          }

          PanelActionButton {
            iconText: hass.refreshing ? Model.GLYPH.spinner : Model.GLYPH.refresh
            tooltipText: "Refresh  ·  r"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: hass.configured
            onClicked: { hass.refresh(); hass.refreshMeta() }
          }

          PanelActionButton {
            iconText: Model.GLYPH.cog
            tooltipText: "Settings  ·  s"
            foreground: root.view === "settings" ? Color.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showView(root.view === "settings" ? root.previousListView : "settings")
          }

          PanelActionButton {
            iconText: Model.GLYPH.openIn
            tooltipText: hass.openMode === "webapp"
              ? "Open Home Assistant as a web app  ·  g"
              : "Open Home Assistant in your browser  ·  g"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: hass.baseUrl !== ""
            onClicked: hass.openHome()
          }
        }

        // ------------------------------------------------------- status bar

        Text {
          Layout.fillWidth: true
          visible: hass.actionStatus !== "" || (hass.lastError !== "" && root.view !== "settings")
          text: hass.actionStatus !== "" ? hass.actionStatus : hass.lastError
          color: hass.actionStatus !== "" ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---------------------------------------------------------- content

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // ---- device list -------------------------------------------------

          ListView {
            id: listView
            anchors.fill: parent
            visible: root.view === "favorites" || root.view === "devices"
            model: root.listRows
            clip: true
            spacing: Style.space(3)
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.listIndex
            highlightMoveDuration: 0
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Item {
              id: rowHolder
              required property var modelData
              required property int index
              readonly property bool isHeader: modelData && modelData.header !== undefined
              width: listView.width
              implicitHeight: isHeader ? headerPart.implicitHeight : entityPart.implicitHeight
              height: implicitHeight

              PanelSectionHeader {
                id: headerPart
                visible: rowHolder.isHeader
                width: parent.width
                topPadding: rowHolder.index === 0 ? Style.space(2) : Style.space(10)
                bottomPadding: Style.space(2)
                text: rowHolder.isHeader ? String(rowHolder.modelData.header).toUpperCase() : ""
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              EntityRow {
                id: entityPart
                visible: !rowHolder.isHeader
                width: parent.width
                entity: rowHolder.isHeader ? null : rowHolder.modelData.entity
                rowIndex: rowHolder.index
              }
            }
          }

          // ---- empty states ------------------------------------------------

          ColumnLayout {
            anchors.centerIn: parent
            width: parent.width - Style.space(40)
            spacing: Style.space(10)
            visible: (root.view === "favorites" || root.view === "devices") && root.rowCount === 0

            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              text: {
                if (!hass.configured) return Model.GLYPH.key
                if (root.query !== "") return Model.GLYPH.search
                return Model.GLYPH.star
              }
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: {
                if (!hass.configured) return "Connect this plugin to Home Assistant to get started."
                if (root.query !== "") return "Nothing matches “" + root.query + "”."
                if (root.view === "devices") return hass.everLoaded
                  ? "Home Assistant reported no devices."
                  : "Loading devices…"
                if (hass.favoritesSource === "label")
                  return "No entities carry the “" + hass.favoritesLabel + "” label in Home Assistant yet."
                return "Pick favourites from the Devices tab — the star on each row puts it here."
              }
            }

            Button {
              Layout.alignment: Qt.AlignHCenter
              visible: !hass.configured
              text: "Open settings"
              iconText: Model.GLYPH.cog
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showView("settings")
            }

            Button {
              Layout.alignment: Qt.AlignHCenter
              visible: hass.configured && root.query === "" && root.view === "favorites"
                && hass.favoritesSource !== "label"
              text: "Browse devices"
              iconText: Model.GLYPH.list
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showView("devices")
            }
          }

          // ---- detail ------------------------------------------------------

          Flickable {
            id: detailFlick
            anchors.fill: parent
            visible: root.view === "detail"
            contentWidth: width
            contentHeight: detailColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            ColumnLayout {
              id: detailColumn
              width: detailFlick.width
              spacing: Style.space(12)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                PanelActionButton {
                  iconText: Model.GLYPH.back
                  tooltipText: "Back  ·  esc"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.closeDetail()
                }

                DeviceGlyph {
                  glyph: root.detailEntity ? Model.glyphFor(root.detailEntity) : ""
                  color: root.detailEntity && Model.isOn(root.detailEntity) ? Color.accent : root.foreground
                  size: Style.font.iconLarge
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  Text {
                    Layout.fillWidth: true
                    text: root.detailEntity ? root.detailEntity.name : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    text: root.detailEntity
                      ? Model.secondaryText(root.detailEntity, hass.areaFor(root.detailEntity.id))
                      : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  iconText: root.detailEntity && hass.isFavorite(root.detailEntity.id)
                    ? Model.GLYPH.star : Model.GLYPH.starOutline
                  tooltipText: hass.favoritesEditable
                    ? "Toggle favourite  ·  f"
                    : "Favourites come from the “" + hass.favoritesLabel + "” label"
                  foreground: root.detailEntity && hass.isFavorite(root.detailEntity.id)
                    ? Color.accent : root.foreground
                  fontFamily: root.fontFamily
                  enabled: hass.favoritesEditable
                  onClicked: root.favoriteCurrent()
                }

                PanelActionButton {
                  iconText: Model.GLYPH.openIn
                  tooltipText: "Open in Home Assistant  ·  o"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.detailEntity) hass.openEntity(root.detailEntity.id)
                }
              }

              ToggleRow {
                Layout.fillWidth: true
                visible: root.detailEntity !== null && Model.isToggleable(root.detailEntity)
                entity: root.detailEntity
              }

              Repeater {
                model: root.detailControls
                ControlRow {
                  required property var modelData
                  required property int index
                  Layout.fillWidth: true
                  spec: modelData
                  specIndex: index
                  entity: root.detailEntity
                }
              }
            }
          }

          // ---- settings ----------------------------------------------------

          Flickable {
            id: settingsFlick
            anchors.fill: parent
            visible: root.view === "settings"
            contentWidth: width
            contentHeight: settingsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            ColumnLayout {
              id: settingsColumn
              width: settingsFlick.width
              spacing: Style.space(10)

              // --- connection -----------------------------------------------

              PanelSectionHeader {
                text: "CONNECTION"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              FieldLabel { text: "Home Assistant URL" }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                TextField {
                  id: urlField
                  Layout.fillWidth: true
                  foreground: root.foreground
                  verticalPadding: Style.space(5)
                  placeholderText: "homeassistant.local:8123"
                  text: hass.url
                  onEditingFinished: {
                    var next = String(text).trim()
                    if (next !== "" && next !== hass.url) hass.persist("url", next)
                  }
                  Keys.onEscapePressed: { text = hass.url; keyCatcher.forceActiveFocus() }
                }

                Button {
                  text: "Test"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    var next = String(urlField.text).trim()
                    if (next !== "" && next !== hass.url) hass.persist("url", next)
                    Qt.callLater(hass.testConnection)
                  }
                }
              }

              FieldHint {
                text: "Host and port, or a full https:// address. Self-signed certificates are accepted."
              }

              FieldLabel { text: hass.hasToken ? "Access token — saved" : "Long-lived access token" }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                TextField {
                  id: tokenField
                  Layout.fillWidth: true
                  enabled: !hass.hasToken
                  password: true
                  foreground: root.foreground
                  verticalPadding: Style.space(5)
                  placeholderText: hass.hasToken ? "••••••••••••••••••••" : "Paste your token here"
                  onAccepted: { hass.saveToken(text); text = "" }
                  Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
                }

                Button {
                  text: hass.hasToken ? "Forget" : "Save"
                  bordered: true
                  foreground: hass.hasToken ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (hass.hasToken) hass.clearToken()
                    else { hass.saveToken(tokenField.text); tokenField.text = "" }
                  }
                }
              }

              FieldHint {
                text: hass.hasToken
                  ? "Stored in ~/.config/omarchy/home-assistant/token, readable only by you."
                  : "Home Assistant → your profile → Security → Long-lived access tokens → Create token."
              }

              Text {
                Layout.fillWidth: true
                visible: hass.lastError !== ""
                text: hass.lastError
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

              // --- favourites -----------------------------------------------

              PanelSectionHeader {
                text: "FAVOURITES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              ButtonGroup {
                focusable: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                value: hass.favoritesSource
                options: [
                  { value: "manual", label: "Chosen here" },
                  { value: "label", label: "Home Assistant label" }
                ]
                onChanged: function (value) { hass.persist("favoritesSource", value) }
              }

              FieldHint {
                text: hass.favoritesSource === "label"
                  ? "Home Assistant has no favourites of its own, so the plugin reads a label instead: tag entities with it in Home Assistant and they appear here."
                  : "Star devices in the Devices tab to add them. The order you add them is the order they appear."
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                visible: hass.favoritesSource === "label"

                FieldLabel { text: "Label" }

                Flow {
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  visible: hass.labels.length > 0

                  Repeater {
                    model: hass.labels
                    Button {
                      required property var modelData
                      // A Repeater hands each row over as a QVariantMap, so the
                      // nested entity list arrives array-like rather than as a
                      // real Array — normalise before counting it.
                      text: String(modelData.name || modelData.id)
                        + "  " + hass.arrayFrom(modelData.entities).length
                      bordered: true
                      fontSize: Style.font.caption
                      selected: String(modelData.name || "").toLowerCase() === hass.favoritesLabel.toLowerCase()
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: hass.persist("favoritesLabel", String(modelData.name || modelData.id))
                    }
                  }
                }

                FieldHint {
                  visible: hass.labels.length === 0
                  text: hass.labelsSupported
                    ? "No labels defined yet. Create one in Home Assistant under Settings → Areas, labels & zones."
                    : (hass.everLoaded
                      ? "This Home Assistant version does not expose labels (they need 2024.4 or newer). Use “Chosen here” instead."
                      : "Connect first to read the labels from Home Assistant.")
                }
              }

              PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

              // --- behaviour ------------------------------------------------

              PanelSectionHeader {
                text: "BEHAVIOUR"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              FieldLabel { text: "Open Home Assistant links" }

              ButtonGroup {
                focusable: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                value: hass.openMode
                options: [
                  { value: "browser", label: "In the browser" },
                  { value: "webapp", label: "As a web app" }
                ]
                onChanged: function (value) { hass.persist("openMode", value) }
              }

              FieldHint {
                text: hass.openMode === "webapp"
                  ? "Launches through omarchy-launch-webapp, in its own chromeless window."
                  : "Opens in your default browser via omarchy-launch-browser."
              }

              Toggle {
                Layout.fillWidth: true
                label: "Group devices by area"
                description: "Uses the areas defined in Home Assistant."
                checked: hass.groupByArea
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: hass.persist("groupByArea", !hass.groupByArea)
              }

              Toggle {
                Layout.fillWidth: true
                label: "Hide unavailable devices"
                description: "Keeps offline entities out of the Devices list."
                checked: hass.hideUnavailable
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: hass.persist("hideUnavailable", !hass.hideUnavailable)
              }

              Toggle {
                Layout.fillWidth: true
                label: "Show the count in the bar"
                description: "A small number beside the icon for how many favourites are on."
                checked: hass.setting("showCount", false) === true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: hass.persist("showCount", hass.setting("showCount", false) !== true)
              }

              FieldLabel { text: "Refresh every " + hass.refreshIntervalSec + " seconds" }

              PanelSlider {
                Layout.fillWidth: true
                bar: root.bar
                integer: true
                minimum: 3
                maximum: 120
                step: 1
                value: hass.refreshIntervalSec
                onReleased: function (value) { hass.persist("refreshIntervalSec", Math.round(value)) }
              }

              FieldHint {
                text: "While the panel is open it polls every " + Math.min(hass.refreshIntervalSec, 5)
                  + " seconds regardless, so changes made elsewhere show up quickly."
              }

              PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Button {
                  text: "Open Home Assistant"
                  iconText: Model.GLYPH.openIn
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: hass.baseUrl !== ""
                  onClicked: hass.openHome()
                }

                Item { Layout.fillWidth: true; implicitHeight: 1 }

                Text {
                  visible: hass.version !== ""
                  text: "Core " + hass.version
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // --------------------------------------------------------- key hints

        Text {
          id: keyHints
          Layout.fillWidth: true
          visible: root.view !== "settings"
          text: root.view === "detail"
            ? "j/k control · h/l adjust · enter run · esc back · f favourite · o open"
            : "j/k move · enter toggle · → details · f favourite · o open · / search · s settings"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // ------------------------------------------------------------ dimensions

  // The popup sizes itself to the view it is showing: forms and device
  // details are as tall as their content, a list gets room for a useful
  // number of rows. Every term here depends only on widths and content, so
  // there is no height feedback loop back into the panel.
  readonly property real chromeHeight:
    heroHolder.implicitHeight
    + toolbarRow.implicitHeight
    + keyHints.implicitHeight
    + Style.space(9)
    + Style.space(10) * 4

  readonly property real desiredHeight: {
    if (view === "detail") return chromeHeight + detailColumn.implicitHeight
    if (view === "settings") return chromeHeight + settingsColumn.implicitHeight
    var listHeight = Math.max(Style.space(120),
                              Math.min(Style.space(430), rowCount * Style.space(45)))
    return chromeHeight + listHeight
  }

  // ------------------------------------------------------------ components

  // A device icon in a box of fixed width.
  //
  // Qt sizes a Text by the ink it paints, not by the font's advance, and these
  // MDI glyphs vary by most of an em: measured at a 14px icon size their ink
  // runs from 5px to 14px, because a lit bulb carries rays a dark one does not
  // and an open lock has a shackle off to one side. Left-aligned in a row that
  // means the label lands at a different x for every icon, and toggling a
  // light visibly nudges its own name sideways.
  //
  // Pinning the box and optically centring the glyph in it keeps one column
  // edge down the whole list, and keeps the icon itself still when its shape
  // changes. `OpticalGlyph` centres painted bounds rather than the advance
  // box, which is what the bar's own icons use.
  component DeviceGlyph: Item {
    id: deviceGlyph

    property string glyph: ""
    property color color: root.foreground
    property real size: Style.font.icon

    // The widest glyph in the set measures a full 1.0x the font size; the
    // remainder is clearance so ink never crowds the label.
    implicitWidth: Math.round(size * 1.2)
    implicitHeight: Math.round(size * 1.2)

    OpticalGlyph {
      anchors.fill: parent
      text: deviceGlyph.glyph
      fontFamily: root.fontFamily
      fontSize: deviceGlyph.size
      color: deviceGlyph.color
    }
  }

  component FieldLabel: Text {
    Layout.fillWidth: true
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
    elide: Text.ElideRight
  }

  component FieldHint: Text {
    Layout.fillWidth: true
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // One device in a list. The switch is the toggle target; the row body opens
  // the detail view. Hover never paints directly — it moves the panel cursor,
  // which is what paints, so mouse and keyboard can never both highlight.
  component EntityRow: CursorSurface {
    id: row

    property var entity: null
    property int rowIndex: 0

    readonly property var action: entity ? Model.rowAction(entity) : ({ kind: "open" })
    readonly property bool isOn: entity ? Model.isOn(entity) : false
    readonly property bool unavailable: entity ? Model.isUnavailable(entity) : false
    readonly property bool favorite: entity ? hass.isFavorite(entity.id) : false

    hasCursor: root.cursorActive && root.listVisible && root.listIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: root.setListCursor(row.rowIndex)
      onClicked: function (mouse) {
        if (mouse.button === Qt.RightButton) {
          if (row.entity) hass.openEntity(row.entity.id)
        } else root.openDetail(row.entity)
      }
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(9)

      DeviceGlyph {
        glyph: row.entity ? Model.glyphFor(row.entity) : ""
        color: row.unavailable ? root.faint : (row.isOn ? Color.accent : root.foreground)
        opacity: row.unavailable ? 0.6 : 1.0
        size: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: row.entity ? row.entity.name : ""
          color: row.unavailable ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: row.entity ? Model.secondaryText(row.entity, hass.areaFor(row.entity.id)) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        Layout.maximumWidth: Style.space(110)
        Layout.alignment: Qt.AlignVCenter
        text: row.entity ? Model.stateText(row.entity) : ""
        color: row.unavailable ? root.faint : (row.isOn ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
      }

      // Toggle, one-shot press, or the jump into Home Assistant — whichever
      // the domain can actually honour.
      // One slot, holding whichever control the domain earns. Only one is ever
      // visible; the slot keeps its width either way.
      Item {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: root.rowControlWidth
        implicitHeight: Math.max(rowSwitch.implicitHeight, pressButton.implicitHeight,
                                 openButton.implicitHeight)

        ToggleSwitch {
          id: rowSwitch
          anchors.centerIn: parent
          visible: row.action.kind === "toggle"
          checked: row.isOn
          enabled: !row.unavailable
          hasCursor: row.hasCursor
          cursorRing: false
          foreground: root.foreground
          trackHeight: Style.space(18)
          onHovered: function (on) { if (on) root.setListCursor(row.rowIndex) }
          onToggled: hass.toggleEntity(row.entity)
        }

        PanelActionButton {
          id: pressButton
          anchors.centerIn: parent
          visible: row.action.kind === "press"
          iconText: row.action.glyph || Model.GLYPH.play
          tooltipText: row.action.tooltip || "Run"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !row.unavailable
          onHovered: function (on) { if (on) root.setListCursor(row.rowIndex) }
          onClicked: hass.callService(row.entity, row.action.call, undefined)
        }

        PanelActionButton {
          id: openButton
          anchors.centerIn: parent
          visible: row.action.kind === "open"
          iconText: Model.GLYPH.openIn
          tooltipText: "Open in Home Assistant"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onHovered: function (on) { if (on) root.setListCursor(row.rowIndex) }
          onClicked: if (row.entity) hass.openEntity(row.entity.id)
        }
      }

      PanelActionButton {
        visible: hass.favoritesEditable
        Layout.alignment: Qt.AlignVCenter
        iconText: row.favorite ? Model.GLYPH.star : Model.GLYPH.starOutline
        tooltipText: row.favorite ? "Remove from favourites" : "Add to favourites"
        foreground: row.favorite ? Color.accent : root.foreground
        fontFamily: root.fontFamily
        onHovered: function (on) { if (on) root.setListCursor(row.rowIndex) }
        onClicked: if (row.entity) hass.toggleFavorite(row.entity.id)
      }
    }
  }

  // The primary on/off at the top of a device's detail view.
  component ToggleRow: CursorSurface {
    id: toggleRow
    property var entity: null

    readonly property bool isOn: entity ? Model.isOn(entity) : false
    hasCursor: false
    foreground: root.foreground
    implicitHeight: toggleContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: hass.toggleEntity(toggleRow.entity)
    }

    RowLayout {
      id: toggleContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: toggleRow.entity ? Model.stateText(toggleRow.entity) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight
      }

      ToggleSwitch {
        checked: toggleRow.isOn
        interactive: false
        foreground: root.foreground
        enabled: toggleRow.entity ? !Model.isUnavailable(toggleRow.entity) : false
      }
    }
  }

  // Renders one entry from Model.controlsFor. The spec decides which branch
  // shows; the rest cost nothing because they never get a size.
  component ControlRow: CursorSurface {
    id: control

    property var spec: null
    property int specIndex: -1
    property var entity: null

    readonly property string kind: spec ? String(spec.type) : ""
    readonly property bool focused: root.cursorActive && root.view === "detail"
      && root.detailIndex === specIndex
    readonly property real liveValue: spec ? Number(spec.value) : 0

    // Read-only entries are not cursor stops, so they never paint.
    hasCursor: focused
    foreground: root.foreground
    implicitHeight: controlBody.implicitHeight + Style.space(8)

    function send(value) {
      if (!spec || !entity) return
      hass.callService(entity, spec.call, value)
    }

    ColumnLayout {
      id: controlBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(7)
      anchors.rightMargin: Style.space(7)
      spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      visible: control.kind !== "note" && control.kind !== "camera"
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: control.spec ? String(control.spec.label || "") : ""
        color: control.kind === "info" ? root.dim : root.foreground
        opacity: control.kind === "info" ? 1.0 : 0.85
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: control.kind !== "info"
        elide: Text.ElideRight
      }

      Text {
        text: {
          if (!control.spec) return ""
          if (control.kind === "info") return String(control.spec.value || "")
          if (control.kind === "slider" || control.kind === "stepper")
            return Model.formatNumber(slider.liveValue) + String(control.spec.unit || "")
          return ""
        }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        Layout.maximumWidth: control.width * 0.55
      }
    }

    PanelSlider {
      id: slider
      Layout.fillWidth: true
      visible: control.kind === "slider"
      bar: root.bar
      integer: control.spec ? Number(control.spec.step) >= 1 : true
      minimum: control.spec ? Number(control.spec.min) : 0
      maximum: control.spec ? Number(control.spec.max) : 100
      step: control.spec ? Number(control.spec.step) : 1
      value: control.liveValue
      // Send on release only. Streaming every drag frame would put a hundred
      // service calls on the wire for one sweep of a brightness slider.
      onReleased: function (value) { control.send(value) }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: control.kind === "stepper"
      spacing: Style.space(8)

      PanelActionButton {
        iconText: Model.GLYPH.minus
        tooltipText: "Down"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: {
          if (!control.spec) return
          var next = Math.max(Number(control.spec.min),
                              control.liveValue - Number(control.spec.step))
          control.send(next)
        }
      }

      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: control.spec
          ? Model.formatNumber(control.liveValue) + String(control.spec.unit || "")
          : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      PanelActionButton {
        iconText: Model.GLYPH.plus
        tooltipText: "Up"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: {
          if (!control.spec) return
          var next = Math.min(Number(control.spec.max),
                              control.liveValue + Number(control.spec.step))
          control.send(next)
        }
      }
    }

    Flow {
      Layout.fillWidth: true
      visible: control.kind === "choice"
      spacing: Style.space(5)

      Repeater {
        model: control.kind === "choice" && control.spec ? control.spec.options : []
        Button {
          required property var modelData
          text: String(modelData.label)
          bordered: true
          fontSize: Style.font.caption
          selected: control.spec && String(modelData.value) === String(control.spec.value)
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: control.send(String(modelData.value))
        }
      }
    }

    Flow {
      Layout.fillWidth: true
      visible: control.kind === "actions"
      spacing: Style.space(5)

      Repeater {
        model: control.kind === "actions" && control.spec ? control.spec.buttons : []
        Button {
          required property var modelData
          required property int index
          text: String(modelData.label)
          iconText: String(modelData.glyph || "")
          bordered: true
          fontSize: Style.font.caption
          hasCursor: control.focused && root.detailButtonIndex === index
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: {
            root.detailButtonIndex = index
            hass.callService(control.entity, modelData.call, undefined)
          }
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: control.kind === "note"
      text: control.spec ? String(control.spec.text || "") : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    // Cameras: a still from /api/camera_proxy, refreshed on demand. Playing
    // the live stream would mean hosting a video pipeline inside the bar
    // process, so the button below hands the feed to Home Assistant instead.
    ColumnLayout {
      Layout.fillWidth: true
      visible: control.kind === "camera"
      spacing: Style.space(6)

      BorderSurface {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(width * 9 / 16)
        color: Style.normalFillFor(root.foreground, Color.accent)
        radius: Style.cornerRadius
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        Image {
          id: cameraImage
          anchors.fill: parent
          anchors.margins: Style.space(1)
          fillMode: Image.PreserveAspectFit
          cache: false
          asynchronous: true
          visible: status === Image.Ready

          function reload() {
            source = ""
            if (hass.snapshotPath !== "" && control.entity
                && hass.snapshotEntity === control.entity.id)
              source = "file://" + hass.snapshotPath
          }

          Connections {
            target: hass
            function onSnapshotSerialChanged() { cameraImage.reload() }
          }

          Component.onCompleted: reload()
        }

        Text {
          anchors.centerIn: parent
          visible: cameraImage.status !== Image.Ready
          text: hass.snapshotError !== "" ? hass.snapshotError : "Loading snapshot…"
          color: hass.snapshotError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: parent.width - Style.space(24)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(5)

        Button {
          text: "New snapshot"
          iconText: Model.GLYPH.refresh
          bordered: true
          fontSize: Style.font.caption
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (control.entity) hass.fetchSnapshot(control.entity.id)
        }

        Button {
          text: "Live view"
          iconText: Model.GLYPH.openIn
          bordered: true
          fontSize: Style.font.caption
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (control.entity) hass.openEntity(control.entity.id)
        }
      }
    }
    }
  }
}
