# MAMDANI OS

Custom operating system / control system for a bunker network in ComputerCraft.

## Files

- `lib/bunkerlib.lua` - Shared library (network, device drivers, monitor drawing, client runtime)
- `control/startup.lua` - Control room software (monitor UI, password login, rednet)
- `client/entrance/startup.lua` - Room client (Entrance) - device control, rednet status
- `client/meroom/startup.lua` - Room client (ME-Core) - device control, rednet status
- `client/control/startup.lua` - Client for the control room computer (its own devices)

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
- **`action` / `cmd`** : *WHAT* the device is (light, door, ...) and which
  command toggles it. The control panel's `action` must match the client
  device's `cmd`. New behaviors are added in `bunkerlib.ACTIONS`.

Patch protocol: clients broadcast `{ id, state }` on `bunker_status`;
the control sends `{ room, cmd, state }` on `bunker_cmd`.

## Setup

> **Important:** `bunkerlib.lua` must be copied to **every** computer, into the
> same folder as the program. All MAMDANI programs load it via `require`.

### Control room

1. Copy `control/startup.lua` as `startup.lua` to the control room computer
2. Copy `lib/bunkerlib.lua` as `bunkerlib.lua` into the same folder
3. Adjust the config:
   - `rooms` table (room device IDs + names)
   - `aux` table for special devices (e.g. corridor lamps) - NOT part of a room
   - `MONITOR_PANELS` assigns each monitor a device group:
     ```
     local MONITOR_PANELS = {
         ["monitor_4"] = { title = "ROOM LIGHTS",     action = "light", header = "LIGHT", entries = rooms },
         ["monitor_7"] = { title = "CORRIDOR LIGHTS", action = "light", header = "LIGHT", entries = aux   },
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
         -- a door directly on a redstone output (no relay)
         { id = "door1",   cmd = "light", driver = "redstone", side = "front" },
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

## Add a new device type

1. Control: add the device to a list + one row in `MONITOR_PANELS`
2. Client: add the device to `DEVICES` with a matching `cmd`
3. New transport (how it is driven): add a driver in `bunkerlib.DRIVERS`
4. New behavior (what a button does): add an action in `bunkerlib.ACTIONS`
   and adjust the panel's `action` / device's `cmd`