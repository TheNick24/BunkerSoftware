# MAMDANI OS

Custom operating system / control system for a bunker network in ComputerCraft.

## Files

- `lib/bunkerlib.lua` - Shared library (network, device drivers, monitor drawing, client runtime)
- `control/startup.lua` - Control room software (monitor UI, password login, rednet)
- `client/entrance/startup.lua` - Room client (Entrance) - device control, rednet status
- `client/meroom/startup.lua` - Room client (ME-Core) - device control, rednet status
- `client/control/startup.lua` - Client for the control room computer (its own devices)
- `client/distributor1/startup.lua` - Room client (Distributor_1) - device control, rednet status
- `remote/startup.lua` - Remote CLI (e.g. pocket computer) - list/control devices from the shell

## Requirements

- Control room: computer + touchscreen monitor + wireless modem
- Room computers: computer + wireless modem + connected devices (redstone relay, redstone output, ...)
- Wireless modems on all sides within range of each other

## How it is modular

A **device** is just { `id`, `cmd`, `driver`, ... }. Two independent concepts:

- **`driver`** (client side): *HOW* the device is physically controlled.
  - `"relay"` - through a redstone relay peripheral (`relay` + `side`)
  - `"redstone"` - directly on a computer redstone output (only `side`)
  - New transports (other peripherals) are added in `bunkerlib.DRIVERS`.
- **`action` / `cmd`** : *WHAT* the device is (light, door, safety-door, ...) and
  which command toggles it. The control panel's `action` must match the client
  device's `cmd`. New behaviors are added in `bunkerlib.ACTIONS`.

Patch protocol: clients broadcast `{ id, cmd, state }` on `bunker_status`;
the control (or any remote) sends `{ room, cmd, state }` on `bunker_cmd`.

## Setup

> **Important:** `bunkerlib.lua` must be copied to **every** computer, into the
> same folder as the program. All MAMDANI programs load it via `require`.

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

Passwords are stored as a **SHA-256 hash** in `bunker.hash`.
The file is stored in the **same folder as the program** (so it stays with it
and survives copies/reboots). On the host disk it lives inside the
ComputerCraft computer directory of the world save:
`saves/<world>/computercraft/computer/<id>/bunker.hash`.

Changing the password requires the **current password**:
run `control setup` in the control room.

## Control room usage

- Monitor: tap the `[CLICK]` buttons to switch the devices
- Only monitors listed in `MONITOR_PANELS` with entries are interactive
- Terminal: `s` = status, `exit` = quit

## Remote CLI (pocket computer / any computer with a modem)

Copy `remote/startup.lua` as `remote.lua` (next to `bunkerlib.lua`); enable
the wireless modem (pocket GUI) and run:

```
remote               list all devices heard in the last 4s
remote <id> on|off   set a device explicitly
remote <id> toggle   flip a device
remote <id>          shorthand for toggle
```

Devices are discovered live from the clients' `bunker_status` broadcasts,
which also carry each device's `cmd` type (light / door / safety-door), so
the CLI shows the correct state texts (ON/OFF vs OPEN/CLOSED) and sends the
right command to the right client.

## Add a new device type

1. Control: add the device to a list (`rooms`, `aux`, `doors`, `safetyDoors`, ...)
   + one row in `MONITOR_PANELS` (or a section on an existing panel)
2. Client: add the device to `DEVICES` with a matching `cmd`
3. New transport (how it is driven): add a driver in `bunkerlib.DRIVERS`
4. New behavior (what a button does): add an action in `bunkerlib.ACTIONS`
   and adjust the panel's `action` / device's `cmd`