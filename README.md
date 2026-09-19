# MAMDANI OS

Custom operating system / control system for a bunker network in ComputerCraft.

## Files

- `lib/bunkerlib.lua` - Shared library loader (keeps the `require("bunkerlib")` API)
- `lib/network.lua` - Modems (`findModem`) + `printOnce`
- `lib/crypto.lua` - SHA-256 + PBKDF2 password hashing (`hashPassword`/`verifyPassword`)
- `lib/status.lua` - Device status cache (`setStatus`, `cleanStatuses`)
- `lib/drivers.lua` - Base transports (`relay`, `redstone`) + protected relay access
- `lib/doors.lua` - Door controllers (own driver + action per type: `door`, `safety-door`)
- `lib/actions.lua` - Generic panel actions (`light`)
- `lib/monitor.lua` - Monitor rendering (headers, toggle tables, panels, footer)
- `lib/client.lua` - Room client runtime (`runClient`)
- `control/startup.lua` - ControlRoom software (control room computer with the monitor panels)
- `client/entrance/startup.lua` - Room client (Entrance) - device control, rednet status
- `client/meroom/startup.lua` - Room client (ME-Core) - device control, rednet status
- `client/control/startup.lua` - Door keypad + client on the separate **Control** computer (door devices + keypad/inside monitors)
- `client/distributor1/startup.lua` - Room client (Distributor_1) - device control, rednet status
- `remote/startup.lua` - Remote CLI (e.g. pocket computer) - list/control devices from the shell
- `deploy/startup.lua` - Deploy tool (push files to every computer over rednet)
- `deploy/receiver.lua` - One-time listener that receives and saves the pushed files
- `tools/install.lua` - HTTP installer (`wget run`) for the repo / the receiver

## Requirements

- Control room: computer + touchscreen monitor + wireless modem
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
the control (or any remote) sends `{ room, cmd, state }` on `bunker_cmd`.

## Setup

> **Important:** The whole `lib/` bundle must be copied to **every** computer,
> flat into the same folder as the program (`bunkerlib.lua`, `network.lua`,
> `crypto.lua`, `status.lua`, `drivers.lua`, `actions.lua`, `doors.lua`,
> `monitor.lua`, `client.lua`). `bunkerlib.lua` is a loader that binds them
> together; all MAMDANI programs load it via `require`.

### Control room

1. Copy `control/startup.lua` as `startup.lua` to the control room computer
2. Copy `lib/bunkerlib.lua` as `bunkerlib.lua` into the same folder
3. Adjust the config:
   - `rooms` table (room device IDs + names)
   - `aux` table for special devices (e.g. corridor lamps) - NOT part of a room
- `MONITOR_PANELS` assigns each monitor a device group - one entry per
     device list (`rooms`, `aux`, `doors`, `safetyDoors`, ...). A single
     monitor can show several groups via `sections`:
     ```
     local MONITOR_PANELS = {
         ["monitor_4"] = { title = "ROOM LIGHTS",     action = "light", header = "LIGHT", entries = rooms },
         ["monitor_7"] = { title = "CORRIDOR LIGHTS", action = "light", header = "LIGHT", entries = aux   },
         ["monitor_3"] = { title = "DOORS", sections = {
             { title = "DOOR",         action = "door",        onText = "OPEN", offText = "CLOSED", entries = doors },
             { title = "SAFETY DOORS", action = "safety-door", onText = "OPEN", offText = "CLOSED", entries = safetyDoors },
         } },
     }
     ```
     `action` must match the client `cmd`. `header` is the state column
     title. Monitors not listed show an info placeholder. New devices only
     need an entry in a list + one row here.
4. Run: `control setup`
5. Enter a password (min. 6 characters)
6. From now on it autostarts on boot

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
still verify, but re-running `control setup` / `startup setup` rewrites the
hash in the new format. The salt makes identical secrets produce different
stored values and defeats rainbow tables; the iteration count slows brute
force down.

The file is stored in the **same folder as the program** (so it stays with it
and survives copies/reboots). On the host disk it lives inside the
ComputerCraft computer directory of the world save:
`saves/<world>/computercraft/computer/<id>/bunker.hash`.

Changing the password requires the **current password**:
run `control setup` in the control room.

## Control room usage

- Monitor: tap the `[CLICK]` buttons to switch the devices
- Only monitors listed in `MONITOR_PANELS` with entries are interactive
- Terminal console (type commands directly and press Enter):
  - `<id> on|off|toggle` - set/flick a device (e.g. `me-safety-1 on`)
  - `alarm` / `alarm on` - EMERGENCY: closes every safety door at once
  - `alarm off` - reopens all safety doors (ends the emergency)
  - `list` - show all known device states
  - `help`, `exit`
  While an alarm is active every monitor shows a red `!! ALARM !!` banner.
  The dedicated `monitor_13` shows a big tappable `ALARM` button instead;
  tap it to start/stop the emergency without the terminal.
  The control room learns each device's `cmd` type from the status broadcasts,
  so the console works for lights, doors and safety doors alike.

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

## Automatic deployment (rednet)

Instead of visiting every computer, you can push the current files to all of
them from a single computer over rednet:

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
deploy            deploy to all targets
deploy <role>     deploy only to the targets of a role (controlroom, control, entrance, ...)
deploy update     refresh the admin's local repo mirror from GitHub over HTTP
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

The first command puts the full repo layout (`lib/`, `control/`, `client/`,
`deploy/`, `remote/`) on the admin computer, ready for `deploy`. The second
puts `receiver.lua` on a target so it can be deployed to. Requires the `http`
API to be enabled in the CC config.

### Other ways (if you prefer not to use rednet)

- **Floppy disk**: put all files on a floppy, insert it into each computer
  and copy from `/disk/` - still per-computer, but no typing.
- **Pastebin**: `pastebin get <code> <file>` for single files per computer.

## Add a new device type

1. Control: add the device to a list (`rooms`, `aux`, `doors`, `safetyDoors`, ...)
   + one row in `MONITOR_PANELS` (or a section on an existing panel)
2. Client: add the device to `DEVICES` with a matching `cmd`
3. New transport (how it is driven): add a driver in `bunkerlib.DRIVERS`
4. New behavior (what a button does): add an action in `bunkerlib.ACTIONS`
   and adjust the panel's `action` / device's `cmd`