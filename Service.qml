import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Transport and state for the Home Assistant plugin. Nothing here draws: it
// owns the poll loop, the service-call queue, and the single source of truth
// for what the house is doing. The panel binds to these properties.
//
// All HTTP goes through hass.py, which keeps the access token in a 0600 file
// and out of argv. This object never sees the token except when saving it,
// and it hands it over on stdin for the same reason.
Item {
  id: root

  property var settings: ({})
  property var bar: null
  property string moduleName: "romeo.home-assistant"

  // True while the panel is open. Polling tightens so a light someone flips
  // at the wall shows up while you are looking at the list, and relaxes back
  // to the configured interval when the panel closes.
  property bool active: false

  // ------------------------------------------------------------- settings

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Settings cross from C++ as QVariantList, which reaches QML's JS engine as
  // an array-like that `Array.isArray` rejects — the same trap `Ui/MultiSelect`
  // documents. Anything that came out of `settings` has to be normalised here
  // before it is treated as an array, or a saved favourites list silently
  // reads as empty.
  function arrayFrom(value) {
    if (!value || typeof value === "string" || typeof value.length !== "number") return []
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  readonly property string url: String(setting("url", "homeassistant.local:8123"))
  readonly property string baseUrl: Model.normalizeUrl(url)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 3, 3600)
  readonly property string favoritesSource: String(setting("favoritesSource", "manual"))
  readonly property string favoritesLabel: String(setting("favoritesLabel", "favorite"))
  readonly property bool groupByArea: setting("groupByArea", true) === true
  readonly property bool hideUnavailable: setting("hideUnavailable", false) === true
  readonly property string openMode: String(setting("openMode", "browser"))

  readonly property var manualFavorites: arrayFrom(setting("favorites", []))

  // --------------------------------------------------------------- state

  property bool hasToken: false
  property bool connected: false
  property bool refreshing: false
  property bool everLoaded: false
  property string lastError: ""
  property string actionStatus: ""
  property string locationName: ""
  property string version: ""

  property var entities: []
  property var byId: ({})
  property var areaByEntity: ({})
  property var labels: []
  property bool labelsSupported: false
  property string labelsError: ""

  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    return dir.replace(/\/+$/, "")
  }
  readonly property string helper: pluginDir + "/hass.py"
  readonly property string snapshotDir: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (!runtime) runtime = "/tmp"
    return runtime + "/omarchy-home-assistant"
  }

  readonly property bool configured: baseUrl !== "" && hasToken
  readonly property int onCount: {
    var favorites = favoriteEntities
    var count = 0
    for (var i = 0; i < favorites.length; i++)
      if (Model.isOn(favorites[i])) count++
    return count
  }

  // ----------------------------------------------------------- favourites

  // Home Assistant has no "favourites" of its own. Labels are the closest
  // native equivalent — an arbitrary tag a user puts on entities from the
  // HA UI — and they are reachable over the template API, so this plugin
  // offers them as one of the two sources. The other is a list kept here.
  readonly property var labelFavorites: {
    var wanted = String(favoritesLabel || "").toLowerCase()
    for (var i = 0; i < labels.length; i++) {
      var label = labels[i]
      if (!label) continue
      if (String(label.name || "").toLowerCase() === wanted
          || String(label.id || "").toLowerCase() === wanted)
        return arrayFrom(label.entities)
    }
    return []
  }

  readonly property var favoriteIds: favoritesSource === "label" ? labelFavorites : manualFavorites

  readonly property var favoriteEntities: {
    var ids = favoriteIds
    var out = []
    for (var i = 0; i < ids.length; i++) {
      var entity = byId[String(ids[i])]
      if (entity) out.push(entity)
    }
    // A label is a set, not an order, so sort it into something predictable.
    // A manual list is the order the user built, so leave it alone.
    return favoritesSource === "label" ? Model.sortEntities(out) : out
  }

  function isFavorite(entityId) {
    var ids = favoriteIds
    for (var i = 0; i < ids.length; i++)
      if (String(ids[i]) === String(entityId)) return true
    return false
  }

  readonly property bool favoritesEditable: favoritesSource !== "label"

  function setFavorite(entityId, wanted) {
    if (!favoritesEditable) return
    var id = String(entityId)
    var next = []
    var found = false
    for (var i = 0; i < manualFavorites.length; i++) {
      var existing = String(manualFavorites[i])
      if (existing === id) { found = true; if (wanted) next.push(existing) }
      else next.push(existing)
    }
    if (wanted && !found) next.push(id)
    persist("favorites", next)
  }

  function toggleFavorite(entityId) {
    setFavorite(entityId, !isFavorite(entityId))
  }

  // Write one setting back into this widget's inline shell.json entry. The
  // shell owns the file; we hand it the whole entry and it persists it.
  function persist(key, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      lastError = "Cannot save settings — the shell did not expose its config"
      return
    }
    var entry = { id: moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    entry[key] = value
    bar.shell.updateEntryInline(moduleName, entry)
  }

  // ---------------------------------------------------------------- areas

  function areaFor(entityId) {
    var name = areaByEntity[String(entityId)]
    return name === undefined ? "" : String(name)
  }

  // Entities bucketed by area for the grouped list, with everything
  // unassigned collected at the end rather than dropped.
  function groupByAreas(list) {
    var buckets = {}
    var order = []
    for (var i = 0; i < list.length; i++) {
      var entity = list[i]
      var area = areaFor(entity.id) || "No area"
      if (!buckets[area]) { buckets[area] = []; order.push(area) }
      buckets[area].push(entity)
    }
    order.sort(function (a, b) {
      if (a === "No area") return 1
      if (b === "No area") return -1
      return a.toLowerCase() < b.toLowerCase() ? -1 : 1
    })
    var out = []
    for (var j = 0; j < order.length; j++)
      out.push({ area: order[j], entities: buckets[order[j]] })
    return out
  }

  // -------------------------------------------------------------- opening

  // Every "open" in the plugin funnels through here so the browser-versus-
  // web-app choice is made in exactly one place.
  function openUrl(target) {
    var link = String(target || "")
    if (link === "") return
    if (openMode === "webapp") Quickshell.execDetached(["omarchy-launch-webapp", link])
    else Quickshell.execDetached(["omarchy-launch-browser", link])
  }

  function openHome() { openUrl(baseUrl) }
  function openEntity(entityId) { openUrl(Model.moreInfoUrl(baseUrl, entityId, version)) }

  // --------------------------------------------------------------- errors

  function elide(text, limit) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    var cap = limit || 160
    return value.length > cap ? value.substring(0, cap - 1) + "…" : value
  }

  function parseResult(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      return (parsed && typeof parsed === "object") ? parsed : null
    } catch (error) {
      return null
    }
  }

  function noteStatus(message) {
    actionStatus = elide(message, 90)
    statusTimer.restart()
  }

  // ------------------------------------------------------------ polling

  function refresh() {
    if (statesProcess.running) return
    if (baseUrl === "") { lastError = "Set your Home Assistant URL in settings"; return }
    refreshing = true
    statesProcess.command = ["python3", helper, "states", baseUrl]
    statesProcess.running = true
  }

  function applyStates(raw) {
    var parsed = parseResult(raw)
    if (!parsed) { lastError = "Could not read the response from Home Assistant"; connected = false; return }
    if (parsed.ok !== true) {
      lastError = elide(parsed.error || "Home Assistant request failed")
      if (parsed.needsToken === true) hasToken = false
      connected = false
      return
    }
    var list = arrayFrom(parsed.entities)
    var map = {}
    for (var i = 0; i < list.length; i++) map[list[i].id] = list[i]
    entities = list
    byId = map
    connected = true
    everLoaded = true
    lastError = ""
  }

  function refreshMeta() {
    if (metaProcess.running || baseUrl === "" || !hasToken) return
    metaProcess.command = ["python3", helper, "meta", baseUrl]
    metaProcess.running = true
  }

  function applyMeta(raw) {
    var parsed = parseResult(raw)
    if (!parsed || parsed.ok !== true) return
    var map = {}
    var areas = arrayFrom(parsed.areas)
    for (var i = 0; i < areas.length; i++) {
      var area = areas[i]
      var ids = arrayFrom(area.entities)
      for (var j = 0; j < ids.length; j++) map[String(ids[j])] = String(area.name || "")
    }
    areaByEntity = map
    labels = arrayFrom(parsed.labels)
    labelsSupported = parsed.labelsSupported === true
    labelsError = elide(parsed.labelsError || "")
    if (parsed.version) version = String(parsed.version)
    if (parsed.location) locationName = String(parsed.location)
  }

  function checkToken() {
    if (tokenProcess.running) return
    tokenProcess.command = ["python3", helper, "status"]
    tokenProcess.running = true
  }

  // ------------------------------------------------------- service calls
  //
  // Calls are queued behind one Process. Clicking three lights off in quick
  // succession must send three requests, not race one Process object into
  // dropping two of them.

  property var callQueue: []

  function enqueue(job) {
    var queue = callQueue.slice()
    queue.push(job)
    callQueue = queue
    pumpQueue()
  }

  function pumpQueue() {
    if (callProcess.running || callQueue.length === 0) return
    var queue = callQueue.slice()
    var job = queue.shift()
    callQueue = queue
    callProcess.command = ["python3", helper, "call", baseUrl,
                           job.domain, job.service, JSON.stringify(job.payload)]
    callProcess.running = true
  }

  // Fire one service call for an entity. `call` is a spec from Model:
  // {domain, service, field?, factor?, payload?}. `value` fills `field`.
  function callService(entity, call, value) {
    if (!entity || !call) return
    if (!configured) { lastError = "Connect to Home Assistant first"; return }
    var payload = {}
    if (call.payload) for (var key in call.payload) payload[key] = call.payload[key]
    if (call.field !== undefined && value !== undefined && value !== null) {
      var factor = call.factor === undefined ? 1 : Number(call.factor)
      payload[call.field] = typeof value === "number" ? value * factor : value
    }
    // Services live on the entity's own domain except where a spec says
    // otherwise (a scene is turned on through `scene.turn_on`, not `turn_on`).
    payload.entity_id = entity.id

    // Paint the new value straight away. Beyond feeling immediate, this is
    // what lets a held key ramp: the next press reads the value this one set
    // rather than recomputing from the last poll.
    if (call.optimistic && value !== undefined && value !== null) {
      var patch = {}
      if (call.optimistic.state === true) {
        patch.state = String(value)
      } else if (call.optimistic.attr) {
        var scale = call.optimistic.factor === undefined ? 1 : Number(call.optimistic.factor)
        patch.attrs = {}
        patch.attrs[call.optimistic.attr] = typeof value === "number" ? value * scale : value
      }
      patchLocal(entity.id, patch)
    }

    enqueue({ domain: call.domain || entity.domain, service: call.service, payload: payload })
    settle()
  }

  function toggleEntity(entity) {
    if (!entity) return
    var call = Model.toggleCall(entity)
    if (!call) return
    patchLocal(entity.id, { state: Model.optimisticState(entity) })
    callService(entity, call, undefined)
  }

  // Paint the change immediately so a switch throws under the finger. The
  // next poll replaces it with whatever Home Assistant actually did, so a
  // failed call corrects itself within a cycle rather than lying forever.
  function patchLocal(entityId, changes) {
    var list = entities.slice()
    var map = {}
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === entityId) {
        var copy = JSON.parse(JSON.stringify(list[i]))
        for (var key in changes) {
          if (key === "attrs") {
            for (var attr in changes.attrs) copy.attrs[attr] = changes.attrs[attr]
          } else copy[key] = changes[key]
        }
        list[i] = copy
      }
      map[list[i].id] = list[i]
    }
    entities = list
    byId = map
  }

  function settle() {
    settleTimer.ticks = 0
    settleTimer.restart()
  }

  // ---------------------------------------------------------------- token

  function saveToken(token) {
    if (tokenWriter.running) return
    tokenWriter.secret = String(token || "")
    if (tokenWriter.secret === "") { lastError = "Paste a long-lived access token first"; return }
    tokenWriter.command = ["python3", helper, "save-token"]
    tokenWriter.running = true
  }

  function clearToken() {
    if (tokenProcess.running) return
    connected = false
    entities = []
    byId = ({})
    tokenProcess.command = ["python3", helper, "clear-token"]
    tokenProcess.running = true
  }

  function testConnection() {
    if (pingProcess.running) return
    if (baseUrl === "") { lastError = "Set your Home Assistant URL first"; return }
    noteStatus("Connecting…")
    pingProcess.command = ["python3", helper, "ping", baseUrl]
    pingProcess.running = true
  }

  // ------------------------------------------------------------ snapshots

  property string snapshotEntity: ""
  property string snapshotPath: ""
  property int snapshotSerial: 0
  property string snapshotError: ""

  function fetchSnapshot(entityId) {
    if (snapshotProcess.running || !configured) return
    var safe = String(entityId).replace(/[^a-zA-Z0-9_.-]/g, "_")
    snapshotEntity = String(entityId)
    snapshotError = ""
    var target = snapshotDir + "/" + safe + ".jpg"
    snapshotProcess.pendingPath = target
    snapshotProcess.command = ["python3", helper, "snapshot", baseUrl, String(entityId), target]
    snapshotProcess.running = true
  }

  // ------------------------------------------------------------ processes

  Process {
    id: statesProcess
    running: false
    stdout: StdioCollector { id: statesOut; waitForEnd: true }
    onExited: {
      root.refreshing = false
      root.applyStates(statesOut.text)
    }
  }

  Process {
    id: metaProcess
    running: false
    stdout: StdioCollector { id: metaOut; waitForEnd: true }
    onExited: root.applyMeta(metaOut.text)
  }

  Process {
    id: tokenProcess
    running: false
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    onExited: {
      var parsed = root.parseResult(tokenOut.text)
      root.hasToken = !!(parsed && (parsed.hasToken === true || parsed.saved === true))
      if (root.hasToken) { root.refresh(); root.refreshMeta() }
    }
  }

  Process {
    id: tokenWriter
    property string secret: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: tokenWriterOut; waitForEnd: true }
    onStarted: {
      // Straight down the pipe — the token must never reach argv, where any
      // process on the machine could read it out of /proc.
      write(secret)
      secret = ""
      stdinEnabled = false
    }
    onExited: {
      var parsed = root.parseResult(tokenWriterOut.text)
      if (parsed && parsed.ok === true) {
        root.hasToken = true
        root.noteStatus("Token saved")
        root.testConnection()
      } else {
        root.lastError = root.elide(parsed ? parsed.error : "Could not save the token")
      }
    }
  }

  Process {
    id: callProcess
    running: false
    stdout: StdioCollector { id: callOut; waitForEnd: true }
    onExited: {
      var parsed = root.parseResult(callOut.text)
      if (parsed && parsed.ok !== true)
        root.lastError = root.elide(parsed.error || "Home Assistant rejected the command")
      else root.lastError = ""
      root.pumpQueue()
    }
  }

  Process {
    id: pingProcess
    running: false
    stdout: StdioCollector { id: pingOut; waitForEnd: true }
    onExited: {
      var parsed = root.parseResult(pingOut.text)
      if (parsed && parsed.ok === true) {
        root.connected = true
        root.lastError = ""
        root.locationName = String(parsed.location || "")
        root.version = String(parsed.version || "")
        root.noteStatus("Connected to " + (root.locationName || "Home Assistant"))
        root.refresh()
        root.refreshMeta()
      } else {
        root.connected = false
        root.lastError = root.elide(parsed ? parsed.error : "Could not reach Home Assistant")
        root.actionStatus = ""
      }
    }
  }

  Process {
    id: snapshotProcess
    property string pendingPath: ""
    running: false
    stdout: StdioCollector { id: snapshotOut; waitForEnd: true }
    onExited: {
      var parsed = root.parseResult(snapshotOut.text)
      if (parsed && parsed.ok === true) {
        root.snapshotPath = snapshotProcess.pendingPath
        root.snapshotSerial++
        root.snapshotError = ""
      } else {
        root.snapshotPath = ""
        root.snapshotError = root.elide(parsed ? parsed.error : "Could not fetch a snapshot", 90)
      }
    }
  }

  // -------------------------------------------------------------- timers

  Timer {
    id: refreshTimer
    // Tighten the loop while the panel is on screen so someone else's wall
    // switch shows up in the list, then fall back to the configured rate.
    interval: (root.active ? Math.min(root.refreshIntervalSec, 5) : root.refreshIntervalSec) * 1000
    repeat: true
    running: root.configured
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: metaTimer
    // Areas and labels change when someone edits their Home Assistant setup,
    // which is rare — an hourly refresh keeps it current without cost.
    interval: 3600000
    repeat: true
    running: root.configured
    onTriggered: root.refreshMeta()
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 700
    repeat: true
    running: false
    onTriggered: {
      ticks++
      root.refresh()
      // Two follow-ups: one for devices that answer instantly, one for the
      // covers and locks that take a few seconds to finish moving.
      if (ticks >= 2) { settleTimer.running = false; settleTimer.interval = 700 }
      else settleTimer.interval = 2400
    }
  }

  Timer {
    id: statusTimer
    interval: 2600
    onTriggered: root.actionStatus = ""
  }

  Component.onCompleted: checkToken()
}
