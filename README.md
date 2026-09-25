# MAMDANI OS

Custom operating system / control system for a bunker network in ComputerCraft.

## Files

- `lib/bunkerlib.lua` - Shared library loader (keeps the `require("bunkerlib")` API)
- `lib/network.lua` - Modems (`findModem`) + `printOnce`
- `lib/crypto.lua` - SHA-256 + PBKDF2 password hashing (`hashPassword`/`verifyPassword`)
- `lib/status.lua` - Device status cache (`setStatus`, `cleanStatuses`)
- `lib/drivers.lua` - Base transports (`relay`, `redstone`) + protected relay access + input reads (`relayGetInput`)
- `lib/doors.lua` - Door controllers (own driver + action per type: `door`, `safety-door`)
- `lib/actions.lua` - Generic panel actions (`light`)
- `lib/monitor.lua` - Monitor rendering (headers, toggle tables, panels, footer)
- `lib/client.lua` - Room client runtime (`runClient`)
- `lib/alarmin.lua` - Redstone alarm-input polling (`bunkerlib.alarmin.create`) for wired panic/trigger inputs
- `lib/alarmconfig.lua` - Shared static device lists (`rooms`, `aux`, `doors`, `alarmSirens`, `safetyDoors`, `lockableDoors`) used by control server + screen servers
- `controlserver/startup.lua` - Control Server software (console + alarm + status cache, NO monitors) - multi-instance capable (backup consoles stay in sync)
- `screenserver/startup.lua` - Screen Server software (monitor panels + touch + alarm banner) - multi-instance capable, per-instance panel selection via `/screenserver_panels.lua`
- `client/entrance/startup.lua` - Room client (Entrance) - device control, rednet status
- `client/meroom/startup.lua` - Room client (ME-Core) - device control, rednet status
- `client/control/startup.lua` - Door keypad + client on the separate **Control** computer (door devices + keypad/inside monitors + Mekanism alarm siren on `redstone_relay_9`/back)
- `client/distributor1/startup.lua` - Room client (Distributor_1) - device control, rednet status
- `remote/startup.lua` - Remote CLI (e.g. pocket computer) - list/control devices from the shell
- `deploy/startup.lua` - Deploy tool (push files to every computer over rednet)
- `deploy/receiver.lua` - One-time listener that receives and saves the pushed files
- `tools/install.lua` - HTTP installer (`wget run`) for the repo / the receiver

## Requirements

- Control server: computer + wireless modem (console/alarm; no monitors)
- Screen server: computer + touchscreen monitors + wireless modem
  (any number of screen servers, each with its own monitor set)
- Room computers: computer + wireless modem + connected devices (redstone relay, redstone output, ...)
- Wireless modems on all sides within range of each other

## How it is modular

A **device** is just { `id`, `cmd`, `driver`, ... }. Two independent concepts:

- **`driver`** (client side): *HOW* the device is physically controlled.
  - `"relay"` - through a redstone relay peripheral (`relay` + `side`)
  - `"redstone"` - directly on a computer redstone output (only `side`)
  - New transports (other peripherals) are added in `bunkerlib.DRIVERS`
    (base transports live in `lib/drivers.lua`).
- **`action` / `cmd`** : *WHAT* the device is (light, door, safety-door, ...) and
  which command toggles it. The control panel's `action` must match the client
  device's `cmd`. New behaviors are added in `bunkerlib.ACTIONS`.
- **Door controllers** (`lib/doors.lua`): each door type is one unit that owns
  its driver *and* its action:
  - `door` - the **control-room door**: always CLOSED, opens only via the
    keypad PIN (`restClosed = true`, handled by `client/control/startup.lua`).
  - `safety-door` - an **alarm/safety door**: normally OPEN, closes only in an
    emergency (`alarm = true`). Close all of them at once with the control
    room's `alarm` command (`bunkerlib.emergencyDoors(statuses, close)`).
  Add a new door type here, nothing else changes.

Patch protocol: clients broadcast `{ id, cmd, state }` on `bunker_status`;
any server (control or screen) sends `{ room, cmd, state }` on `bunker_cmd`.
Servers sync among themselves on `bunker_alarm` (`{ on, source }`).

## Alarm (Mekanism Industrial Alarm / sirens)

The alarm is started from the UI (big ALARM button, ALARM row on the DOORS
monitor) or the console (`alarm on`). `setAlarm(true)` then:

1. closes safety doors and locks lockable doors (red `!! ALARM !!` banner)
2. powers every entry in the **`alarmSirens` group** so external alarm
   blocks (e.g. Mekanism **Industrial Alarm**) make sound

There is **no** redstone alarm *input* — redstone is only the *output* to
the sirens.

### Wiring one Mekanism alarm

1. Place the Industrial Alarm next to a redstone relay (or run redstone to it)
2. Control client (`client/control/startup.lua`) — one device row:

```lua
{ id = "alarm-siren", cmd = "alarm", driver = "relay",
  relay = "redstone_relay_9", side = "back" },
```

3. Shared list (`lib/alarmconfig.lua`) — same id in the group:

```lua
bunkerlib.alarmSirens = {
    { id = "alarm-siren", name = "Mekanism Alarm" },
}
```

When the alarm goes ON, the client gets `{ room = id, cmd = "alarm",
state = true }` and switches the relay. Alarm OFF cuts power again.

The alarm state itself syncs across ALL server instances: whoever triggers
it (a screen server's touch button or a control server's `alarm on`)
broadcasts `bunker_alarm { on, source }`; every other instance applies the
same doors/sirens locally without re-broadcasting (no loops). Multiple
screen servers and multiple control servers therefore always agree.

### Adding another alarm block later

1. New relay/side (or another computer + its own device row)
2. New unique `id` in **both** lists (`DEVICES` + `alarmSirens` in
   `lib/alarmconfig.lua`)
3. Deploy — all sirens in the group fire together with the alarm

The group is shown as the `ALARM` section on `monitor_3` (same toggle as
the big button).

## Setup

> **Important:** The whole `lib/` bundle must be copied to **every** computer,
> flat into the same folder as the program (`bunkerlib.lua`, `network.lua`,
> `crypto.lua`, `status.lua`, `drivers.lua`, `actions.lua`, `doors.lua`,
> `monitor.lua`, `client.lua`). `bunkerlib.lua` is a loader that binds them
> together; all MAMDANI programs load it via `require`.

### Control server + screen server

The old all-in-one control room program is split into two roles (both may
run multiple instances in parallel - they sync via `bunker_status` for
device states and `bunker_alarm` for the alarm on/off state):

1. **Control server** (`controlserver/startup.lua`): terminal console,
   password, alarm logic, status cache. NO monitors.
2. **Screen server** (`screenserver/startup.lua`): discovers the monitors
   attached to ITS computer, draws the panels, forwards touch presses,
   shows the `!! ALARM !!` banner. No console.

Shared static device lists live in `lib/alarmconfig.lua` (`rooms`, `aux`,
`doors`, `alarmSirens`, `safetyDoors`, `lockableDoors`) so every server
instance works from the same source.

#### Screen server setup

1. Copy `screenserver/startup.lua` as `startup.lua` to the screen server
   computer (with the monitor peripherals attached)
2. Copy the whole `lib/` bundle next to it (flat)
3. Optional per-instance panels: create `/screenserver_panels.lua` at the
   computer root (survives deploys):

   ```lua
   -- show only a subset of the default panels:
   return { only = { "monitor_4", "monitor_14" } }

   -- or replace the panels entirely:
   return {
     panels = {
       ["monitor_4"] = { title = "ROOM LIGHTS", action = "light",
                         header = "LIGHT", entries = {
           { id = "entrance", name = "Entrance" },
       } },
     },
     alarmButton = "monitor_14",   -- or false to disable
     energyMonitor = "monitor_18", -- or false to disable
   }
   ```

   Without an override file the defaults are used (identical to the old
   all-in-one `MONITOR_PANELS`). Monitors not present on this computer are
   skipped automatically - a second control room with a different monitor
   set just works.
4. Start the program (autostarts on deployed systems).

#### Control server setup

1. Copy `controlserver/startup.lua` as `startup.lua` to the control server
   computer
2. Copy the whole `lib/` bundle next to it (flat)
3. Start the program. On the first start (no password yet) it prompts
   **directly inside the running system** for a new password (min. 6
   characters) - after that the console boots locked. To change the
   password later, run `main setup`.

### Room clients

1. Copy the matching `client/<room>/startup.lua` as `startup.lua` to the room computer
2. Copy `lib/bunkerlib.lua` as `bunkerlib.lua` into the same folder
3. Adjust the config:
   - `NAME` - display name in the header
   - `MODEM_SIDE` - side of the computer the wireless modem is on
     (e.g. `"left"`); `nil` = auto-detect all sides
   - `DEVICES` - every device this computer controls, e.g.
     ```
     local DEVICES = {
         -- light through a relay
         { id = "me",      cmd = "light", driver = "relay",    relay = "redstone_relay_7", side = "top"   },
         -- corridor lamps through a relay
         { id = "corr-1",  cmd = "light", driver = "relay",    relay = "redstone_relay_7", side = "right" },
         -- safety door through a door contact/link bridge (signal ON = closed,
         -- so "door" inverts the state; sync the `id` with `safetyDoors`)
         { id = "me-safety-1", cmd = "safety-door", driver = "door", peripheral = "redstone_relay_11", side = "left" },
     }
     ```
     `id` must match a control panel entry, `cmd` the panel's `action`.
4. Run: `startup.lua` (also autostarts)

## Security

Passwords / PINs are stored as a **salted, stretched PBKDF2-HMAC-SHA256**
hash (random 16-byte salt, 1000 iterations) with the format
`pbkdf2$<salt>$<iterations>$<key>` - stored in `bunker.hash` (control room)
or `door.hash` (door keypad). Old installations with a plain SHA-256 hash
still verify, but re-running the password setup (`main setup` on deployed
control server clients) rewrites the hash in the new format. The salt makes
identical secrets produce different
stored values and defeats rainbow tables; the iteration count slows brute
force down.

The file is stored in the **same folder as the program** (so it stays with it
and survives copies/reboots). On the host disk it lives inside the
ComputerCraft computer directory of the world save:
`saves/<world>/computercraft/computer/<id>/bunker.hash`.

Changing the password requires the **current password**:
run `main setup` on the control server.

## Control room usage

**Screen server (monitors):**

- Tap the `[CLICK]` buttons to switch the devices
- Only monitors listed in the panels (default `MONITOR_PANELS` or the
  `/screenserver_panels.lua` override) with entries are interactive
- While an alarm is active every monitor shows a red `!! ALARM !!` banner.
  The dedicated `monitor_14` shows a big tappable `ALARM` button instead;
  tap it to start/stop the emergency.
- The sirens themselves are driven by a room client (device `alarm-siren` on
  `redstone_relay_9` / `back`, see **Alarm** above) - both server roles only
  switch the shared alarm state.

**Control server (terminal console):**

- Type commands directly and press Enter:
  - `<id> on|off|toggle` - set/flick a device (e.g. `me-safety-1 on`)
  - `alarm` / `alarm on` - EMERGENCY: closes every safety door at once
  - `alarm off` - reopens all safety doors (ends the emergency)
  - `list` - show all known device states
  - `help`, `exit`
- The console learns each device's `cmd` type from the status broadcasts,
  so the console works for lights, doors and safety doors alike.
- Alarm started on ANY server instance (console or touch) syncs to every
  other control/screen server instance via `bunker_alarm`.

### Door semantics

The two door drivers are deliberately different controllers:

| Type          | Rest state  | How it opens/closes                    |
|---------------|-------------|----------------------------------------|
| `door`        | CLOSED      | Keypad code in the control room        |
| `safety-door` | OPEN        | `alarm` closes all of them (emergency) |

Both sit on the same physical wiring (signal ON = CLOSED, state is inverted),
but they behave differently: the control-room door rests closed and must be
code-opened, while the safety doors rest open and may only be closed during
an alarm. Manual `on`/`off`/click works for testing/override either way.

## Remote CLI (pocket computer / any computer with a modem)

Copy `remote/startup.lua` as `remote.lua` (next to `bunkerlib.lua`); enable
the wireless modem (pocket GUI) and run:

```
remote               list all devices heard in the last seconds
remote <id> on|off   set a device explicitly
remote <id> toggle   flip a device
remote <id>          shorthand for toggle
remote watch         live view of every incoming rednet message (diagnostics)
remote shell         interactive console - keep typing commands
remote help
```

Devices are discovered live from the clients' `bunker_status` broadcasts,
which also carry each device's `cmd` type (light / door / safety-door), so
the CLI shows the correct state texts (ON/OFF vs OPEN/CLOSED) and sends the
right command to the right client. Known devices are cached in `remote.cache`,
so commands still work briefly when out of range.

If `remote` finds nothing, run `remote watch` first: it prints every message
that arrives at the pocket computer, so you can tell whether the problem is
wireless range/modem (no output) or something else.

## Deploying updates

There are two ways to get new files onto the target computers.

### A. Self-updating clients (recommended)

Every target pulls its own files over HTTP directly from GitHub - rednet is
only used to *trigger* the refresh, the data never travels over wireless.

1. **Bootstrap once per computer** with the room role:
   `wget run <BASE_URL>/tools/install.lua client entrance`
   (roles: `controlserver`, `screenserver`, `control`, `entrance`, `meroom`,
   `distributor`, `maschineroom`). It installs the flat library bundle, the
   room's `main.lua`, a `receiver.lua`, a generated `startup.lua` launcher and
   an `update.lua`.
2. Reboot the computer.
3. The launcher now pulls the newest files over HTTP on **every boot** and then
   starts `main.lua` (a failed pull never blocks the room, old files stay).
   When GitHub is unreachable nothing breaks.
4. Manual refresh from the admin computer, without touching the target:
   `deploy refresh` (or `deploy refresh <role>`). It sends a tiny rednet
   `update` trigger; the target's receiver runs `update.lua`, which pulls the
   newest files over HTTP and reboots. You can also just type `update` in the
   target's shell.

A one-time ID->role setup is still needed for `deploy refresh` (the `TARGETS`
table in `deploy/startup.lua`).

### B. Classic rednet push (fallback / LAN)

If HTTP is not available, the original push still works:

1. **Admin computer** (any computer with a modem, e.g. the control room):
   copy the whole repo next to `deploy/startup.lua` - either by file access,
   or over HTTP with the installer (see below).
2. **One-time bootstrap**: get `deploy/receiver.lua` onto every target
   computer and run `receiver` on it. It prints its computer ID. Over HTTP:
   `wget run <BASE_URL>/tools/install.lua receiver` then `receiver`.
3. Fill in the computer IDs in the `TARGETS` table at the top of
   `deploy/startup.lua` (id -> role, see the `ROLES` table).
4. Run `deploy` on the admin computer. It sends `bunkerlib.lua`, the role's
   program and a generated `startup.lua` launcher to every target and
   reboots them.

After the first deploy every target boots into a launcher that runs the
receiver AND the main program together (`parallel.waitForAll`), so future
updates are fully automatic: edit files on the admin computer, run `deploy`,
done. When the repo changed on GitHub, refresh the admins's local mirror
first with `deploy update` (does the old `wget run .../tools/install.lua`
remotely) - you don't have to type the wget URL anymore.

```
deploy            deploy to all targets over rednet (push, fallback)
deploy <role>     deploy only to the targets of a role (push)
deploy update     refresh the admin's local repo mirror from GitHub over HTTP
deploy refresh    tell all targets to self-update over HTTP (rednet is only the
                  trigger - the data comes from GitHub directly)
deploy targets    show the configured targets
```

Notes:
- Files are streamed in 16 KB chunks; every file must be acknowledged by
  the target. A missing or dropped chunk just means the whole file is re-sent
  (up to 4 attempts), so nothing is written until it arrived completely.
- `REBOOT_AFTER = true` restarts every target right after the transfer. Set
  it to `false` if a target is in the middle of something.
- Pocket computers are not auto-deployed (they have no launcher); copy
  `remote.lua` + `bunkerlib.lua` to the pocket once and update manually.

### HTTP installer (`tools/install.lua`)

Host the repo somewhere reachable (GitHub raw, your own web server, ...) and
set `BASE_URL` at the top of `tools/install.lua` to the repository root, e.g.
`https://raw.githubusercontent.com/<user>/BunkerSoftware/main`.

```
wget run <BASE_URL>/tools/install.lua            # admin computer: whole repo
wget run <BASE_URL>/tools/install.lua receiver   # target bootstrap: receiver only
```

The first command puts the full repo layout (`lib/`, `controlserver/`, `client/`,
`deploy/`, `remote/`) on the admin computer, ready for `deploy`. The second
puts `receiver.lua` on a target so it can be deployed to. Requires the `http`
API to be enabled in the CC config.

### Other ways (if you prefer not to use rednet)

- **Floppy disk**: put all files on a floppy, insert it into each computer
  and copy from `/disk/` - still per-computer, but no typing.
- **Pastebin**: `pastebin get <code> <file>` for single files per computer.

## Add a new device type

1. Shared lists: add the device to a list in `lib/alarmconfig.lua`
   (`rooms`, `aux`, `doors`, `safetyDoors`, ...)
2. Screen server: one row in the panels (default `MONITOR_PANELS` in
   `screenserver/startup.lua`, or the instance's `/screenserver_panels.lua`)
3. Client: add the device to `DEVICES` with a matching `cmd`
4. New transport (how it is driven): add a driver in `bunkerlib.DRIVERS`
5. New behavior (what a button does): add an action in `bunkerlib.ACTIONS`
   and adjust the panel's `action` / device's `cmd`

## Controlplane (operator API + web UI + agents)

`controlplane/` runs *next to* the CC network, outside ComputerCraft (Node.js).
Every CC computer runs a small agent (`controlplane/agent/agentd.lua`) that
bootstraps from `GET /agentd.lua`, registers and then long-polls
`POST /agent/poll`. All agent traffic is signed (HMAC over
`METHOD\nPATH\nSEQ\nBODY`, strictly-increasing sequence, replay-safe).

- `.env` - operator token, HMAC secret, `COMMAND_ALLOWLIST`, bind host/port
  (read at startup; a change requires a restart)
- `node server/index.js` - HTTP server: device ingress + release files on
  (`127.0.0.1:<PORT>`) signed with HMAC when a tunnel maps them into the CC
  network; operator API + web UI protected by `x-operator-token`
- `node mcp/index.js` - MCP server over stdio (`npm run mcp`); exposes the
  operator API as MCP tools
- `tools/build-releases.js` (`npm run build`) - builds the `subsystem` bundles
  from `tools/roles.json`; a deploy publishes `releases/<id>/` + `manifest.json`
- `tools/install.lua` + `deploy/` - legacy MAMDANI bootstrap/deploy for the
  CC network (roles: `controlserver`, `screenserver`, `control`, `entrance`,
  `meroom`, `distributor`, `maschineroom`)
- `public/` - the operator web UI (device list, commands, release deploy)

Commands (all require `agent.update` to be running the matching `agentd.lua`):

```
inspect             device info + latest client status
peripherals         every attached peripheral with type + methods
                    (monitors: size + text scale) - button in the web UI
monitor.capture     list monitors / capture a monitor's text
config.read/write   read/write the agent settings
log.read            agent log
reboot              restart the computer (agent plus room program)
agent.update        pull the newest agentd.lua + reboot
release.deploy      build + install a release for a role/installation
release.rollback    switch back to the previous release
eval_lua            run an arbitrary snippet on the target
```

To keep the fleet reachable through the operator, run a tunnel into the
controlplane port (e.g. the local line in `.env` points
`AGENT_BASE_URL`/`releases` at the public HTTPS URL that maps back to
`127.0.0.1:<PORT>`), then pair a CC computer with
`wget run <AGENT_BASE_URL>/agentd.lua <deviceId> <pairingToken>`.