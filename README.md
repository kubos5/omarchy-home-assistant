# Home Assistant for Omarchy

Control your Home Assistant devices from the Omarchy bar. Click the icon for a
dashboard of your favourite devices, or open the full device list and drive
anything the REST API can reach.

` 󰟐 ` → favourites dashboard → full device list → per-device controls

## Installation

```bash
omarchy plugin add https://github.com/kubos5/omarchy-home-assistant --enable
```

## Setup

1. In Home Assistant, open your profile → **Security** → **Long-lived access
   tokens** → **Create token**. Copy it.
2. Click the Home Assistant icon in the bar, then **Open settings** (or press
   `s` with the panel open).
3. Enter your URL — `homeassistant.local:8123` by default — paste the token,
   and press **Test**.

The token is written to `~/.config/omarchy/home-assistant/token` with mode
`0600` and is never passed on a command line, so it does not show up in `ps`
for other processes on the machine. Everything else lives in the widget's
entry in `~/.config/omarchy/shell.json`.

## Favourites

Home Assistant has no built-in notion of "favourites", so the plugin offers
two sources and you pick one in settings:

- **Chosen here** (default) — star devices in the **Devices** tab. The list is
  kept in `shell.json` and shown in the order you added them.
- **Home Assistant label** — tag entities with a label in Home Assistant
  (Settings → Areas, labels & zones) and the plugin reads that label as the
  favourites list, so the same set follows you to every client. The label is
  picked from the ones your instance reports; the default name is `favorite`.
  Labels need Home Assistant 2024.4 or newer — on anything older the plugin
  says so and you use "Chosen here" instead.

Areas come from Home Assistant too, and group the device list when
**Group devices by area** is on.

## What each device can do

Every row carries the control its domain actually supports, and every device
has an **Open in Home Assistant** button for whatever the panel cannot do.

| Domain | In the panel |
|---|---|
| `light` | on/off, brightness, colour temperature, effects |
| `switch`, `input_boolean` | on/off |
| `fan` | on/off, speed, preset, oscillation |
| `climate` | on/off, target temperature, HVAC mode, fan / preset / swing mode |
| `water_heater` | target temperature, operation mode |
| `humidifier` | on/off, target humidity, mode |
| `lock` | lock, unlock, open |
| `cover`, `valve` | open / stop / close, position, tilt |
| `media_player` | play/pause, previous, next, stop, volume, mute, source |
| `vacuum` | start, pause, stop, dock, locate, suction |
| `scene`, `script`, `button`, `input_button` | run in one click |
| `automation` | enable, disable, trigger now |
| `number`, `input_number` | value slider |
| `select`, `input_select` | option picker |
| `siren` | sound, silence |
| `camera` | still snapshot, refresh, live view in Home Assistant |
| `alarm_control_panel` | opens in Home Assistant — arming needs your code |
| sensors, `person`, `weather`, `update` | current readings, update install |

Cameras show a still from `/api/camera_proxy` rather than the live stream:
playing video would mean hosting a decode pipeline inside the bar process, so
**Live view** hands the feed to Home Assistant instead. Alarm panels are the
other deliberate hand-off — a bar popup is the wrong place to type a house PIN.

### How "open in Home Assistant" links work

The buttons link to `<your-url>/?more-info-entity-id=<entity_id>`, which opens
that entity's more-info dialog. Home Assistant added the query parameter in
**2025.6** (handled by the dashboard root) and moved the handling up to the app
root in **2026.8**, which is why the link targets the instance root rather than
a dashboard path — `/lovelace/0` only exists on instances that still carry the
legacy overview dashboard, and newer installs default to a different panel.

On instances older than 2025.6 the buttons fall back to
`<your-url>/history?entity_id=<entity_id>`, which has accepted that parameter
for years. The plugin reads your version from `/api/config` to choose, so this
happens automatically.

This is *not* the My Home Assistant redirect service (`/_my_redirect/...`).
There is no `more_info` redirect in that scheme, and asking for one produces
"This redirect is not supported by your Home Assistant instance."

## Keyboard

With the panel open:

| Key | Action |
|---|---|
| `j` / `k` or `↑` / `↓` | move the cursor |
| `enter` / `space` | toggle the device (or run a scene/script) |
| `→` | open the device's details |
| `←` / `esc` | back, then close |
| `j` / `k` in details | move between controls |
| `h` / `l` in details | adjust the focused slider, stepper, or option |
| `f` | favourite / unfavourite |
| `o` | open the selected device in Home Assistant |
| `g` | open Home Assistant itself |
| `/` | search by name, room, or domain |
| `a` / `d` | Devices / Favourites |
| `s` | settings |
| `r` | refresh |
| `tab` | move to the next bar panel |

Mouse: click a row for details, the switch to toggle, the star to favourite,
and right-click a row to open it in Home Assistant. On the bar icon itself,
right-click refreshes and middle-click opens Home Assistant.

## Opening links

**Open Home Assistant links** in settings chooses between your default browser
(`omarchy-launch-browser`) and a standalone web-app window
(`omarchy-launch-webapp`). Every link in the plugin follows that choice.

## Settings

Settings are editable in the panel, and from the command line:

```bash
omarchy bar set romeo.home-assistant url 192.168.1.20:8123
omarchy bar set romeo.home-assistant openMode webapp
omarchy bar set romeo.home-assistant refreshIntervalSec 30
omarchy bar set romeo.home-assistant favoritesSource label
omarchy bar set romeo.home-assistant favoritesLabel favorite
omarchy bar set romeo.home-assistant groupByArea false
omarchy bar set romeo.home-assistant hideUnavailable true
omarchy bar set romeo.home-assistant showCount true
```

`showCount` draws the number of favourites that are on next to the bar icon.
While the panel is closed the plugin polls every `refreshIntervalSec` seconds;
while it is open it polls at most every 5 seconds so changes made elsewhere in
the house show up as you watch.

## Scripting

The plugin registers an IPC target, so devices can be bound to keys in
`~/.config/hypr/bindings.lua`:

```bash
omarchy-shell romeo.home-assistant toggle                      # show/hide the panel
omarchy-shell romeo.home-assistant call light.desk toggle      # toggle one entity
omarchy-shell romeo.home-assistant call scene.movie_night turn_on
omarchy-shell romeo.home-assistant refresh
omarchy-shell romeo.home-assistant openHome
omarchy-shell romeo.home-assistant status                      # "4 of 9 on"
```

Note that after `omarchy-shell shell rescanPlugins` hot-reloads plugin code,
the IPC target can still be held by the previous instance until the shell is
restarted (`omarchy restart shell`). The bar widget itself reloads correctly
either way; this only affects IPC calls.

## Layout

```
manifest.json   plugin metadata and the settings schema
Panel.qml       bar icon plus the popup: favourites, devices, details, settings
Service.qml     poll loop, service-call queue, favourites, settings persistence
Model.js        domain knowledge — icons, capabilities, wording, controls
hass.py         the only thing that speaks HTTP; owns the token
```

`hass.py` can be run by hand for troubleshooting:

```bash
cd ~/.config/omarchy/plugins/romeo.home-assistant
./hass.py ping homeassistant.local:8123
./hass.py states homeassistant.local:8123 | head -c 400
./hass.py meta homeassistant.local:8123        # areas and labels
./hass.py status                               # is a token saved?
```

## Requirements

- Home Assistant reachable over HTTP(S), with a long-lived access token
- `python3` (standard library only)
- Home Assistant 2024.4+ for label-based favourites; everything else works on
  older versions

Self-signed certificates are accepted, which is the usual case for a local
instance on `https`.
