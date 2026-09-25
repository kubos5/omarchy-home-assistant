// Pure helpers for the Home Assistant plugin: what a domain looks like, what
// it can do, and how to say it. Everything here is a function of an entity
// snapshot, so the panel stays a renderer and the service stays a transport.

// ------------------------------------------------------------------ glyphs
//
// Material Design Icons only — the same set Home Assistant draws from, so a
// light here looks like a light there. Each one was resolved by MDI name out
// of the `post` table in JetBrainsMono Nerd Font (the family Omarchy resolves
// `monospace` to) rather than typed from a codepoint chart, because adjacent
// codepoints in that block are unrelated icons: U+F00AC is `blinds` and
// U+F00AD is `block_helper`, a circle with a line through it.
var GLYPH = {
  // device domains
  homeAssistant: "󰟐", home: "󰋜", light: "󰌵",
  lightOn: "󰛨", ledStrip: "󱁑", ceilingLight: "󰝩",
  switchIcon: "󰨚", plug: "󰚥", fan: "󰈐",
  airConditioner: "󰀛", thermostat: "󰎓", thermometer: "󰔏",
  humidity: "󰖎", airPurifier: "󰵄", waterBoiler: "󰾒",
  lock: "󰌾", lockOpen: "󰿆", door: "󰠛",
  doorOpen: "󰠜", window: "󱇛", windowOpen: "󱇜",
  blinds: "󰂬", shutter: "󱄜", garage: "󰛙",
  garageOpen: "󰛚", curtains: "󱡆", camera: "󰄀",
  cctv: "󰞮", media: "󰝚", speaker: "󰓃",
  television: "󰔂", vacuum: "󰜍", scene: "󰏘",
  script: "󰯂", automation: "󰚩", button: "󱊨",
  number: "󰎠", select: "󰉹", motion: "󰶑",
  person: "󰀄", mapMarker: "󰍎", weather: "󰖕",
  alarm: "󰚊", siren: "󰞏", sensor: "󰊚",
  gauge: "󰊚", battery: "󰁹", energy: "󰉁",
  update: "󰏕", valve: "󱡍", fire: "󰈸",
  smoke: "󰎒", snowflake: "󰜗", water: "󰖌",
  counter: "󰆙", washer: "󰜪",
  // panel chrome
  star: "󰓎", starOutline: "󰓒", search: "󰍉",
  cog: "󰒓", refresh: "󰑐", spinner: "󰦖",
  openIn: "󰏌", check: "󰄬", close: "󰅖",
  back: "󰅁", forward: "󰅂", plus: "󰐕",
  minus: "󰍴", play: "󰐊", pause: "󰏤",
  stop: "󰓛", next: "󰒭", previous: "󰒮",
  volume: "󰕾", volumeOff: "󰖁", alert: "󰀨",
  list: "󰉹", key: "󰌋", link: "󰌹",
  arrowUp: "󰁝", arrowDown: "󰁅", info: "󰋽",
  web: "󰖟", tune: "󰘮", dots: "󰇘"
}

// ------------------------------------------------------- feature bitmasks
//
// Home Assistant publishes each platform's capabilities as a bitmask in
// `supported_features`. Reading it is what keeps the detail view honest: a
// cover that cannot report position gets buttons, not a dead slider.
var FEATURE = {
  cover: { open: 1, close: 2, setPosition: 4, stop: 8, setTilt: 128 },
  media: { pause: 1, volumeSet: 4, volumeMute: 8, previous: 16, next: 32,
           turnOn: 128, turnOff: 256, volumeStep: 1024, selectSource: 2048,
           stop: 4096, play: 16384 },
  fan: { setSpeed: 1, oscillate: 2, direction: 4, presetMode: 8 },
  climate: { targetTemperature: 1, targetTemperatureRange: 2,
             targetHumidity: 4, fanMode: 8, presetMode: 16, swingMode: 32,
             turnOff: 128, turnOn: 256 },
  lock: { open: 1 },
  vacuum: { pause: 4, stop: 8, returnHome: 16, fanSpeed: 32, locate: 512,
            start: 8192 },
  humidifier: { modes: 1 },
  waterHeater: { targetTemperature: 1, operationMode: 2, awayMode: 4 }
}

function attrs(entity) {
  return (entity && entity.attrs) ? entity.attrs : {}
}

function supports(entity, bit) {
  var value = Number(attrs(entity).supported_features || 0)
  if (!isFinite(value)) return false
  return (value & bit) === bit
}

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

// --------------------------------------------------------------- identity

var CONTROLLABLE = {
  light: true, switch: true, input_boolean: true, fan: true, climate: true,
  lock: true, cover: true, media_player: true, scene: true, script: true,
  automation: true, button: true, input_button: true, number: true,
  input_number: true, select: true, input_select: true, humidifier: true,
  siren: true, vacuum: true, water_heater: true, valve: true
}

// Domains whose "on" is a real, reversible on/off the bar can count and a
// row can carry as a switch. Everything else gets a button or a read-out.
var TOGGLEABLE = {
  light: true, switch: true, input_boolean: true, fan: true, humidifier: true,
  siren: true, automation: true, media_player: true, climate: true,
  lock: true, cover: true, valve: true
}

function isControllable(entity) {
  return entity ? CONTROLLABLE[entity.domain] === true : false
}

function isToggleable(entity) {
  if (!entity || !TOGGLEABLE[entity.domain]) return false
  if (isUnavailable(entity)) return false
  if (entity.domain === "media_player")
    return supports(entity, FEATURE.media.turnOn) || supports(entity, FEATURE.media.turnOff)
  if (entity.domain === "cover")
    return supports(entity, FEATURE.cover.open) || supports(entity, FEATURE.cover.close)
  return true
}

function isUnavailable(entity) {
  if (!entity) return true
  var state = String(entity.state || "")
  return state === "unavailable" || state === "unknown" || state === ""
}

// "On" for counting and for the switch knob. Each domain says it its own way.
function isOn(entity) {
  if (!entity || isUnavailable(entity)) return false
  var state = String(entity.state)
  switch (entity.domain) {
    case "lock": return state === "unlocked" || state === "open"
    case "cover":
    case "valve": return state === "open" || state === "opening"
    case "climate": return state !== "off"
    case "media_player": return state === "playing" || state === "on" || state === "paused"
    case "vacuum": return state === "cleaning" || state === "returning"
    case "alarm_control_panel": return state !== "disarmed"
    default: return state === "on" || state === "home" || state === "playing"
  }
}

// The service call a row's switch fires. Lock is deliberately asymmetric:
// "on" means unlocked, so flipping the switch on unlocks.
function toggleCall(entity) {
  if (!entity) return null
  var on = isOn(entity)
  switch (entity.domain) {
    case "lock":
      return { domain: "lock", service: on ? "lock" : "unlock" }
    case "cover":
      return { domain: "cover", service: on ? "close_cover" : "open_cover" }
    case "valve":
      return { domain: "valve", service: on ? "close_valve" : "open_valve" }
    case "climate":
      return on
        ? { domain: "climate", service: "set_hvac_mode", payload: { hvac_mode: "off" } }
        : { domain: "climate", service: "turn_on" }
    case "media_player":
      return { domain: "media_player", service: on ? "turn_off" : "turn_on" }
    case "automation":
      return { domain: "automation", service: on ? "turn_off" : "turn_on" }
    default:
      return { domain: entity.domain, service: "toggle" }
  }
}

// What the state looks like locally after a toggle, so the switch throws on
// click instead of waiting a poll cycle for Home Assistant to agree.
function optimisticState(entity) {
  if (!entity) return ""
  var on = isOn(entity)
  switch (entity.domain) {
    case "lock": return on ? "locking" : "unlocking"
    case "cover":
    case "valve": return on ? "closing" : "opening"
    case "climate": return on ? "off" : "heat_cool"
    default: return on ? "off" : "on"
  }
}

// What the control at the end of a list row should be. Rows never guess: a
// switch only appears where flipping it is meaningful, one-shot domains get a
// press button, and everything else offers the jump into Home Assistant —
// which is also the honest answer for a camera or an alarm keypad.
function rowAction(entity) {
  if (!entity) return { kind: "open" }
  if (isToggleable(entity)) return { kind: "toggle" }
  switch (entity.domain) {
    case "scene":
      return { kind: "press", glyph: GLYPH.play, tooltip: "Activate scene",
               call: { domain: "scene", service: "turn_on" } }
    case "script":
      return { kind: "press", glyph: GLYPH.play, tooltip: "Run script",
               call: { domain: "script", service: "turn_on" } }
    case "button":
    case "input_button":
      return { kind: "press", glyph: GLYPH.button, tooltip: "Press",
               call: { domain: entity.domain, service: "press" } }
    case "vacuum":
      return { kind: "press", glyph: GLYPH.play, tooltip: "Start cleaning",
               call: { domain: "vacuum", service: "start" } }
    case "media_player":
      // Not toggleable (no turn_on/turn_off), but play/pause still works.
      if (supports(entity, FEATURE.media.play) || supports(entity, FEATURE.media.pause)) {
        var playing = String(entity.state) === "playing"
        return { kind: "press", glyph: playing ? GLYPH.pause : GLYPH.play,
                 tooltip: playing ? "Pause" : "Play",
                 call: { domain: "media_player", service: "media_play_pause" } }
      }
      return { kind: "open" }
    default:
      return { kind: "open" }
  }
}

// ------------------------------------------------------------------ icons

function glyphFor(entity) {
  if (!entity) return GLYPH.sensor
  var a = attrs(entity)
  var deviceClass = String(a.device_class || "")
  var on = isOn(entity)
  switch (entity.domain) {
    case "light": return on ? GLYPH.lightOn : GLYPH.light
    case "switch": return deviceClass === "outlet" ? GLYPH.plug : GLYPH.switchIcon
    case "input_boolean": return GLYPH.switchIcon
    case "fan": return GLYPH.fan
    case "climate": return GLYPH.airConditioner
    case "water_heater": return GLYPH.waterBoiler
    case "humidifier": return GLYPH.airPurifier
    case "lock": return on ? GLYPH.lockOpen : GLYPH.lock
    case "cover":
      if (deviceClass === "garage") return on ? GLYPH.garageOpen : GLYPH.garage
      if (deviceClass === "door") return on ? GLYPH.doorOpen : GLYPH.door
      if (deviceClass === "window") return on ? GLYPH.windowOpen : GLYPH.window
      if (deviceClass === "curtain") return GLYPH.curtains
      if (deviceClass === "shutter") return GLYPH.shutter
      return GLYPH.blinds
    case "valve": return GLYPH.valve
    case "camera": return GLYPH.camera
    case "media_player":
      if (deviceClass === "tv") return GLYPH.television
      if (deviceClass === "speaker") return GLYPH.speaker
      return GLYPH.media
    case "vacuum": return GLYPH.vacuum
    case "scene": return GLYPH.scene
    case "script": return GLYPH.script
    case "automation": return GLYPH.automation
    case "button":
    case "input_button": return GLYPH.button
    case "number":
    case "input_number":
    case "counter": return GLYPH.number
    case "select":
    case "input_select": return GLYPH.select
    case "person": return GLYPH.person
    case "device_tracker": return GLYPH.mapMarker
    case "weather": return GLYPH.weather
    case "alarm_control_panel": return GLYPH.alarm
    case "siren": return GLYPH.siren
    case "update": return GLYPH.update
    case "binary_sensor":
      if (deviceClass === "motion" || deviceClass === "occupancy") return GLYPH.motion
      if (deviceClass === "door") return on ? GLYPH.doorOpen : GLYPH.door
      if (deviceClass === "window" || deviceClass === "opening")
        return on ? GLYPH.windowOpen : GLYPH.window
      if (deviceClass === "moisture") return GLYPH.water
      if (deviceClass === "smoke") return GLYPH.smoke
      if (deviceClass === "gas" || deviceClass === "heat") return GLYPH.fire
      if (deviceClass === "battery") return GLYPH.battery
      return GLYPH.sensor
    case "sensor":
      if (deviceClass === "temperature") return GLYPH.thermometer
      if (deviceClass === "humidity") return GLYPH.humidity
      if (deviceClass === "battery") return GLYPH.battery
      if (deviceClass === "power" || deviceClass === "energy") return GLYPH.energy
      if (deviceClass === "moisture" || deviceClass === "water") return GLYPH.water
      return GLYPH.gauge
    default: return GLYPH.sensor
  }
}

// ------------------------------------------------------------------- text

var STATELESS = { scene: true, button: true, input_button: true, script: true }

// Home Assistant reports weather as one squashed lowercase word.
var WEATHER_STATES = {
  "clear-night": "Clear night", "cloudy": "Cloudy", "exceptional": "Exceptional",
  "fog": "Fog", "hail": "Hail", "lightning": "Lightning",
  "lightning-rainy": "Thunderstorms", "partlycloudy": "Partly cloudy",
  "pouring": "Pouring", "rainy": "Rainy", "snowy": "Snowy",
  "snowy-rainy": "Sleet", "sunny": "Sunny", "windy": "Windy",
  "windy-variant": "Windy"
}

function titleCase(value) {
  var s = String(value || "").replace(/_/g, " ")
  return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.slice(1)
}

function formatNumber(value, digits) {
  var n = Number(value)
  if (!isFinite(n)) return String(value)
  var rounded = digits === undefined ? Math.round(n * 10) / 10 : Number(n.toFixed(digits))
  return String(rounded)
}

function brightnessPercent(entity) {
  var raw = attrs(entity).brightness
  if (raw === undefined || raw === null) return -1
  return Math.max(1, Math.min(100, Math.round(Number(raw) / 2.55)))
}

// The right-hand read-out on a row: the one number or word that answers
// "what is it doing right now".
function stateText(entity) {
  if (!entity) return ""
  var a = attrs(entity)
  var state = String(entity.state || "")
  if (state === "unavailable") return "Unavailable"
  // Scenes and buttons have no meaningful state of their own — Home Assistant
  // reports `unknown` until they are first used. Showing that as a fault is
  // wrong, so let them fall through to their own labels below.
  if (state === "unknown" && !STATELESS[entity.domain]) return "Unknown"

  switch (entity.domain) {
    case "light": {
      if (state !== "on") return "Off"
      var pct = brightnessPercent(entity)
      return pct > 0 ? pct + "%" : "On"
    }
    case "climate": {
      var target = a.temperature
      var label = titleCase(a.hvac_action || state)
      if (target !== undefined && target !== null)
        return label + " · " + formatNumber(target) + "°"
      return label
    }
    case "water_heater":
      return a.temperature !== undefined
        ? titleCase(state) + " · " + formatNumber(a.temperature) + "°"
        : titleCase(state)
    case "fan": {
      if (state !== "on") return "Off"
      var pctFan = a.percentage
      return (pctFan !== undefined && pctFan !== null) ? Math.round(pctFan) + "%" : "On"
    }
    case "humidifier":
      return state === "on" && a.humidity !== undefined
        ? Math.round(a.humidity) + "%"
        : titleCase(state)
    case "cover":
    case "valve": {
      var pos = a.current_position
      if (state === "open" && pos !== undefined && pos !== null && pos < 100)
        return Math.round(pos) + "%"
      return titleCase(state)
    }
    case "media_player": {
      if (state === "off" || state === "standby" || state === "idle") return titleCase(state)
      return a.media_title ? String(a.media_title) : titleCase(state)
    }
    case "sensor": {
      var unit = a.unit_of_measurement
      return unit ? formatNumber(state) + " " + unit : String(state)
    }
    case "binary_sensor": {
      var dc = String(a.device_class || "")
      if (dc === "motion" || dc === "occupancy") return state === "on" ? "Detected" : "Clear"
      if (dc === "door" || dc === "window" || dc === "opening")
        return state === "on" ? "Open" : "Closed"
      if (dc === "moisture") return state === "on" ? "Wet" : "Dry"
      return state === "on" ? "On" : "Off"
    }
    case "person":
    case "device_tracker":
      return titleCase(state)
    case "weather": {
      var sky = WEATHER_STATES[state] || titleCase(state)
      return a.temperature !== undefined
        ? sky + " · " + formatNumber(a.temperature) + "°"
        : sky
    }
    case "scene": return "Activate"
    case "script": return state === "on" ? "Running" : "Run"
    case "button":
    case "input_button": return "Press"
    case "number":
    case "input_number": {
      var unitNum = a.unit_of_measurement
      return unitNum ? formatNumber(state) + " " + unitNum : formatNumber(state)
    }
    default:
      return titleCase(state)
  }
}

// The dim line under the name: where it is, and anything the read-out on the
// right had no room for.
function secondaryText(entity, areaName) {
  if (!entity) return ""
  var a = attrs(entity)
  var parts = []
  if (areaName) parts.push(areaName)
  if (entity.domain === "media_player" && a.media_artist) parts.push(String(a.media_artist))
  else if (entity.domain === "climate" && a.current_temperature !== undefined)
    parts.push("Now " + formatNumber(a.current_temperature) + "°")
  else if (entity.domain === "vacuum" && a.battery_level !== undefined)
    parts.push("Battery " + Math.round(a.battery_level) + "%")
  else parts.push(titleCase(entity.domain.replace(/_/g, " ")))
  return parts.join(" · ")
}

// ---------------------------------------------------------- detail controls
//
// Each entry is a spec the panel renders with one of a handful of generic
// control components. `call.field` names the service field the control's
// value goes into; `call.factor` scales the displayed value on the way out
// (volume is 0–1 in the API but 0–100 on screen).

function controlsFor(entity) {
  if (!entity) return []
  var a = attrs(entity)
  var on = isOn(entity)
  var out = []

  switch (entity.domain) {
    case "light":
      if (on) {
        var pct = brightnessPercent(entity)
        out.push({
          type: "slider", label: "Brightness", unit: "%",
          value: pct > 0 ? pct : 100, min: 1, max: 100, step: 1,
          call: { domain: "light", service: "turn_on", field: "brightness_pct",
                  optimistic: { attr: "brightness", factor: 2.55 } }
        })
        var modes = a.supported_color_modes || []
        var hasTemp = a.min_color_temp_kelvin !== undefined
          && (modes.indexOf("color_temp") !== -1 || a.color_temp_kelvin !== undefined)
        if (hasTemp) {
          out.push({
            type: "slider", label: "Colour temperature", unit: "K",
            value: num(a.color_temp_kelvin, num(a.min_color_temp_kelvin, 2700)),
            min: num(a.min_color_temp_kelvin, 2000),
            max: num(a.max_color_temp_kelvin, 6500),
            step: 50,
            call: { domain: "light", service: "turn_on", field: "color_temp_kelvin",
                    optimistic: { attr: "color_temp_kelvin" } }
          })
        }
        if (Array.isArray(a.effect_list) && a.effect_list.length > 0) {
          out.push({
            type: "choice", label: "Effect", value: String(a.effect || ""),
            options: choiceList(a.effect_list),
            call: { domain: "light", service: "turn_on", field: "effect",
                    optimistic: { attr: "effect" } }
          })
        }
      }
      break

    case "fan":
      if (on && supports(entity, FEATURE.fan.setSpeed)) {
        out.push({
          type: "slider", label: "Speed", unit: "%",
          value: num(a.percentage, 100), min: 0, max: 100,
          step: Math.max(1, Math.round(num(a.percentage_step, 1))),
          call: { domain: "fan", service: "set_percentage", field: "percentage",
                  optimistic: { attr: "percentage" } }
        })
      }
      if (Array.isArray(a.preset_modes) && a.preset_modes.length > 0) {
        out.push({
          type: "choice", label: "Preset", value: String(a.preset_mode || ""),
          options: choiceList(a.preset_modes),
          call: { domain: "fan", service: "set_preset_mode", field: "preset_mode",
                  optimistic: { attr: "preset_mode" } }
        })
      }
      if (supports(entity, FEATURE.fan.oscillate)) {
        out.push({
          type: "actions", label: "Oscillation", buttons: [
            { label: "On", call: { domain: "fan", service: "oscillate", payload: { oscillating: true } } },
            { label: "Off", call: { domain: "fan", service: "oscillate", payload: { oscillating: false } } }
          ]
        })
      }
      break

    case "climate":
      if (supports(entity, FEATURE.climate.targetTemperature)) {
        out.push({
          type: "stepper", label: "Target temperature", unit: "°",
          value: num(a.temperature, num(a.current_temperature, 20)),
          min: num(a.min_temp, 7), max: num(a.max_temp, 35),
          step: num(a.target_temp_step, 0.5),
          call: { domain: "climate", service: "set_temperature", field: "temperature",
                  optimistic: { attr: "temperature" } }
        })
      }
      if (Array.isArray(a.hvac_modes) && a.hvac_modes.length > 0) {
        out.push({
          type: "choice", label: "Mode", value: String(entity.state),
          options: choiceList(a.hvac_modes),
          call: { domain: "climate", service: "set_hvac_mode", field: "hvac_mode",
                  optimistic: { state: true } }
        })
      }
      if (Array.isArray(a.fan_modes) && a.fan_modes.length > 0) {
        out.push({
          type: "choice", label: "Fan", value: String(a.fan_mode || ""),
          options: choiceList(a.fan_modes),
          call: { domain: "climate", service: "set_fan_mode", field: "fan_mode",
                  optimistic: { attr: "fan_mode" } }
        })
      }
      if (Array.isArray(a.preset_modes) && a.preset_modes.length > 0) {
        out.push({
          type: "choice", label: "Preset", value: String(a.preset_mode || ""),
          options: choiceList(a.preset_modes),
          call: { domain: "climate", service: "set_preset_mode", field: "preset_mode",
                  optimistic: { attr: "preset_mode" } }
        })
      }
      if (Array.isArray(a.swing_modes) && a.swing_modes.length > 0) {
        out.push({
          type: "choice", label: "Swing", value: String(a.swing_mode || ""),
          options: choiceList(a.swing_modes),
          call: { domain: "climate", service: "set_swing_mode", field: "swing_mode",
                  optimistic: { attr: "swing_mode" } }
        })
      }
      if (a.current_temperature !== undefined)
        out.push({ type: "info", label: "Current", value: formatNumber(a.current_temperature) + "°" })
      if (a.current_humidity !== undefined)
        out.push({ type: "info", label: "Humidity", value: Math.round(a.current_humidity) + "%" })
      break

    case "water_heater":
      if (supports(entity, FEATURE.waterHeater.targetTemperature)) {
        out.push({
          type: "stepper", label: "Target temperature", unit: "°",
          value: num(a.temperature, 50), min: num(a.min_temp, 30),
          max: num(a.max_temp, 80), step: 1,
          call: { domain: "water_heater", service: "set_temperature", field: "temperature",
                  optimistic: { attr: "temperature" } }
        })
      }
      if (Array.isArray(a.operation_list) && a.operation_list.length > 0) {
        out.push({
          type: "choice", label: "Mode", value: String(entity.state),
          options: choiceList(a.operation_list),
          call: { domain: "water_heater", service: "set_operation_mode", field: "operation_mode",
                  optimistic: { state: true } }
        })
      }
      break

    case "humidifier":
      out.push({
        type: "slider", label: "Target humidity", unit: "%",
        value: num(a.humidity, 50), min: num(a.min_humidity, 0),
        max: num(a.max_humidity, 100), step: 1,
        call: { domain: "humidifier", service: "set_humidity", field: "humidity",
                optimistic: { attr: "humidity" } }
      })
      if (Array.isArray(a.available_modes) && a.available_modes.length > 0) {
        out.push({
          type: "choice", label: "Mode", value: String(a.mode || ""),
          options: choiceList(a.available_modes),
          call: { domain: "humidifier", service: "set_mode", field: "mode",
                  optimistic: { attr: "mode" } }
        })
      }
      break

    case "cover":
    case "valve": {
      var d = entity.domain
      var suffix = d === "cover" ? "_cover" : "_valve"
      out.push({
        type: "actions", label: "Position", buttons: [
          { label: "Open", glyph: GLYPH.arrowUp, call: { domain: d, service: "open" + suffix } },
          { label: "Stop", glyph: GLYPH.stop, call: { domain: d, service: "stop" + suffix } },
          { label: "Close", glyph: GLYPH.arrowDown, call: { domain: d, service: "close" + suffix } }
        ]
      })
      if (supports(entity, FEATURE.cover.setPosition)) {
        out.push({
          type: "slider", label: "Open to", unit: "%",
          value: num(a.current_position, 0), min: 0, max: 100, step: 1,
          call: { domain: d, service: "set_" + d + "_position", field: "position",
                  optimistic: { attr: "current_position" } }
        })
      }
      if (d === "cover" && supports(entity, FEATURE.cover.setTilt)) {
        out.push({
          type: "slider", label: "Tilt", unit: "%",
          value: num(a.current_tilt_position, 0), min: 0, max: 100, step: 1,
          call: { domain: "cover", service: "set_cover_tilt_position", field: "tilt_position",
                  optimistic: { attr: "current_tilt_position" } }
        })
      }
      break
    }

    case "lock":
      out.push({
        type: "actions", label: "Lock", buttons: [
          { label: "Lock", glyph: GLYPH.lock, call: { domain: "lock", service: "lock" } },
          { label: "Unlock", glyph: GLYPH.lockOpen, call: { domain: "lock", service: "unlock" } }
        ].concat(supports(entity, FEATURE.lock.open)
          ? [{ label: "Open", glyph: GLYPH.doorOpen, call: { domain: "lock", service: "open" } }]
          : [])
      })
      if (a.changed_by) out.push({ type: "info", label: "Changed by", value: String(a.changed_by) })
      break

    case "media_player": {
      var transport = []
      if (supports(entity, FEATURE.media.previous))
        transport.push({ label: "Previous", glyph: GLYPH.previous, call: { domain: "media_player", service: "media_previous_track" } })
      if (supports(entity, FEATURE.media.play) || supports(entity, FEATURE.media.pause))
        transport.push({ label: entity.state === "playing" ? "Pause" : "Play",
                         glyph: entity.state === "playing" ? GLYPH.pause : GLYPH.play,
                         call: { domain: "media_player", service: "media_play_pause" } })
      if (supports(entity, FEATURE.media.stop))
        transport.push({ label: "Stop", glyph: GLYPH.stop, call: { domain: "media_player", service: "media_stop" } })
      if (supports(entity, FEATURE.media.next))
        transport.push({ label: "Next", glyph: GLYPH.next, call: { domain: "media_player", service: "media_next_track" } })
      if (transport.length > 0) out.push({ type: "actions", label: "Playback", buttons: transport })

      if (supports(entity, FEATURE.media.volumeSet)) {
        out.push({
          type: "slider", label: "Volume", unit: "%",
          value: Math.round(num(a.volume_level, 0) * 100), min: 0, max: 100, step: 1,
          call: { domain: "media_player", service: "volume_set", field: "volume_level",
                  factor: 0.01, optimistic: { attr: "volume_level", factor: 0.01 } }
        })
      }
      if (supports(entity, FEATURE.media.volumeMute)) {
        out.push({
          type: "actions", label: "Mute", buttons: [
            { label: a.is_volume_muted ? "Unmute" : "Mute",
              glyph: a.is_volume_muted ? GLYPH.volume : GLYPH.volumeOff,
              call: { domain: "media_player", service: "volume_mute",
                      payload: { is_volume_muted: !a.is_volume_muted } } }
          ]
        })
      }
      if (supports(entity, FEATURE.media.selectSource)
          && Array.isArray(a.source_list) && a.source_list.length > 0) {
        out.push({
          type: "choice", label: "Source", value: String(a.source || ""),
          options: choiceList(a.source_list),
          call: { domain: "media_player", service: "select_source", field: "source",
                  optimistic: { attr: "source" } }
        })
      }
      if (a.media_title) out.push({ type: "info", label: "Playing", value: String(a.media_title) })
      if (a.media_artist) out.push({ type: "info", label: "Artist", value: String(a.media_artist) })
      break
    }

    case "vacuum": {
      var vacuumButtons = []
      if (supports(entity, FEATURE.vacuum.start))
        vacuumButtons.push({ label: "Start", glyph: GLYPH.play, call: { domain: "vacuum", service: "start" } })
      if (supports(entity, FEATURE.vacuum.pause))
        vacuumButtons.push({ label: "Pause", glyph: GLYPH.pause, call: { domain: "vacuum", service: "pause" } })
      if (supports(entity, FEATURE.vacuum.stop))
        vacuumButtons.push({ label: "Stop", glyph: GLYPH.stop, call: { domain: "vacuum", service: "stop" } })
      if (supports(entity, FEATURE.vacuum.returnHome))
        vacuumButtons.push({ label: "Dock", glyph: GLYPH.home, call: { domain: "vacuum", service: "return_to_base" } })
      if (supports(entity, FEATURE.vacuum.locate))
        vacuumButtons.push({ label: "Locate", glyph: GLYPH.mapMarker, call: { domain: "vacuum", service: "locate" } })
      if (vacuumButtons.length > 0) out.push({ type: "actions", label: "Vacuum", buttons: vacuumButtons })
      if (Array.isArray(a.fan_speed_list) && a.fan_speed_list.length > 0) {
        out.push({
          type: "choice", label: "Suction", value: String(a.fan_speed || ""),
          options: choiceList(a.fan_speed_list),
          call: { domain: "vacuum", service: "set_fan_speed", field: "fan_speed",
                  optimistic: { attr: "fan_speed" } }
        })
      }
      if (a.battery_level !== undefined)
        out.push({ type: "info", label: "Battery", value: Math.round(a.battery_level) + "%" })
      break
    }

    case "select":
    case "input_select":
      out.push({
        type: "choice", label: "Option", value: String(entity.state),
        options: choiceList(a.options || []),
        call: { domain: entity.domain, service: "select_option", field: "option",
                optimistic: { state: true } }
      })
      break

    case "number":
    case "input_number":
      out.push({
        type: "slider", label: "Value", unit: String(a.unit_of_measurement || ""),
        value: num(entity.state, 0), min: num(a.min, 0), max: num(a.max, 100),
        step: num(a.step, 1),
        call: { domain: entity.domain, service: "set_value", field: "value",
                optimistic: { state: true } }
      })
      break

    case "scene":
      out.push({
        type: "actions", label: "Scene", buttons: [
          { label: "Activate", glyph: GLYPH.scene, call: { domain: "scene", service: "turn_on" } }
        ]
      })
      break

    case "script":
      out.push({
        type: "actions", label: "Script", buttons: [
          { label: "Run", glyph: GLYPH.play, call: { domain: "script", service: "turn_on" } },
          { label: "Stop", glyph: GLYPH.stop, call: { domain: "script", service: "turn_off" } }
        ]
      })
      break

    case "automation":
      out.push({
        type: "actions", label: "Automation", buttons: [
          { label: "Run now", glyph: GLYPH.play, call: { domain: "automation", service: "trigger" } },
          { label: "Enable", glyph: GLYPH.check, call: { domain: "automation", service: "turn_on" } },
          { label: "Disable", glyph: GLYPH.close, call: { domain: "automation", service: "turn_off" } }
        ]
      })
      break

    case "button":
    case "input_button":
      out.push({
        type: "actions", label: "Button", buttons: [
          { label: "Press", glyph: GLYPH.button, call: { domain: entity.domain, service: "press" } }
        ]
      })
      break

    case "siren":
      out.push({
        type: "actions", label: "Siren", buttons: [
          { label: "Sound", glyph: GLYPH.siren, call: { domain: "siren", service: "turn_on" } },
          { label: "Silence", glyph: GLYPH.close, call: { domain: "siren", service: "turn_off" } }
        ]
      })
      break

    case "camera":
      // Rendered by the panel as a live snapshot via /api/camera_proxy. The
      // stream itself needs a video pipeline the shell has no business
      // hosting, so the detail view offers the still plus a jump to HA.
      out.push({ type: "camera" })
      break

    case "alarm_control_panel":
      // Arming and disarming almost always require a user code, and prompting
      // for one in a bar popup is the wrong place to type a house PIN.
      out.push({
        type: "note",
        text: "Arming and disarming need your alarm code. Open this entity in Home Assistant to use the keypad."
      })
      break

    case "update":
      out.push({
        type: "actions", label: "Update", buttons: [
          { label: "Install", glyph: GLYPH.update, call: { domain: "update", service: "install" } },
          { label: "Skip", glyph: GLYPH.close, call: { domain: "update", service: "skip" } }
        ]
      })
      break
  }

  // Read-only domains and anything with no controls above still deserve their
  // numbers spelled out rather than an empty pane.
  if (a.device_class) out.push({ type: "info", label: "Type", value: titleCase(a.device_class) })
  out.push({ type: "info", label: "State", value: stateText(entity) })
  out.push({ type: "info", label: "Entity", value: entity.id })
  return out
}

function choiceList(values) {
  var list = []
  if (!Array.isArray(values)) return list
  for (var i = 0; i < values.length; i++) {
    var value = String(values[i])
    list.push({ value: value, label: titleCase(value) })
  }
  return list
}

// -------------------------------------------------------------- filtering

function matches(entity, query, areaName) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return true
  var haystack = (entity.name + " " + entity.id + " " + entity.domain + " "
    + (areaName || "")).toLowerCase()
  var terms = q.split(/\s+/)
  for (var i = 0; i < terms.length; i++)
    if (haystack.indexOf(terms[i]) === -1) return false
  return true
}

// Favourites first, then the domains a person actually reaches for, then
// everything else — inside each bucket, alphabetically.
var DOMAIN_RANK = {
  light: 0, switch: 1, climate: 2, fan: 3, cover: 4, lock: 5, media_player: 6,
  vacuum: 7, scene: 8, script: 9, automation: 10, camera: 11, humidifier: 12,
  water_heater: 13, valve: 14, siren: 15, alarm_control_panel: 16,
  input_boolean: 17, number: 18, input_number: 19, select: 20,
  input_select: 21, button: 22, input_button: 23, person: 24,
  device_tracker: 25, binary_sensor: 26, sensor: 27
}

function domainRank(domain) {
  var rank = DOMAIN_RANK[domain]
  return rank === undefined ? 90 : rank
}

function sortEntities(list) {
  var copy = (list || []).slice()
  copy.sort(function (a, b) {
    var ra = domainRank(a.domain), rb = domainRank(b.domain)
    if (ra !== rb) return ra - rb
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
  })
  return copy
}

// ------------------------------------------------------------------- urls

function normalizeUrl(raw) {
  var url = String(raw || "").trim().replace(/\/+$/, "")
  if (url === "") return ""
  if (url.indexOf("://") === -1) url = "http://" + url
  return url
}

// Home Assistant releases are `YEAR.MONTH.PATCH`. Returns a comparable number
// (2025.6 -> 202506) or 0 when the version is unknown.
function versionOrdinal(version) {
  var parts = String(version || "").split(".")
  var year = parseInt(parts[0], 10)
  var month = parseInt(parts[1], 10)
  if (!isFinite(year) || !isFinite(month)) return 0
  return year * 100 + month
}

// `more-info-entity-id` opens an entity's more-info dialog. It arrived in
// 2025.6 handled by the dashboard root, and 2026.8 moved the handling up to
// the app root so it works on any path — including `/`, which is why the link
// below targets the instance root rather than guessing a dashboard path. That
// matters: `/lovelace/0` only exists on instances that still carry the legacy
// overview dashboard, and newer installs default to a different panel
// entirely.
var MORE_INFO_PARAM_VERSION = 202506

function supportsMoreInfoUrl(version) {
  var ordinal = versionOrdinal(version)
  // Unknown version: assume it works. The worst case is that Home Assistant
  // simply opens without the dialog, where the alternative — the My Home
  // Assistant redirect this replaced — showed an error page instead.
  return ordinal === 0 || ordinal >= MORE_INFO_PARAM_VERSION
}

function moreInfoUrl(baseUrl, entityId, version) {
  var base = normalizeUrl(baseUrl)
  if (base === "") return ""
  if (!entityId) return base
  if (!supportsMoreInfoUrl(version)) return historyUrl(base, entityId)
  return base + "/?more-info-entity-id=" + encodeURIComponent(entityId)
}

// Pre-2025.6 fallback. The history panel has taken `entity_id` in its query
// for years and always exists, so an old instance still lands on the entity
// rather than on an error.
function historyUrl(baseUrl, entityId) {
  var base = normalizeUrl(baseUrl)
  if (base === "") return ""
  return base + "/history?entity_id=" + encodeURIComponent(entityId)
}
