# MAMDANI OS

Custom operating system / control system for a bunker network in ComputerCraft.

## Files

- `control/startup.lua` - Control room software (monitor UI, password login, rednet)
- `client/entrance/startup.lua` - Room client (Entrance) - relay control, rednet status
- `client/meroom/startup.lua` - Room client (ME-Core) - relay control, rednet status

## Requirements

- Control room: computer + touchscreen monitor + wireless modem
- Room computers: computer + wireless modem + redstone relay
- Wireless modems on all sides within range of each other

## Setup

### Control room

1. Copy `control/startup.lua` as `startup.lua` to the control room computer
2. Adjust the `rooms` table in the config (room IDs + names)
3. Set `CONTROL_MONITOR` (name of the monitor that shows the light controls)
4. For special lights (e.g. corridor lamps): set `AUX_MONITOR` (a separate
   monitor) and fill the `aux` table - these are NOT part of a room/group
4. Run: `control setup`
5. Enter a password (min. 6 characters)
6. From now on it autostarts on boot

### Room clients

1. Copy the matching `client/<room>/startup.lua` as `startup.lua` to the room computer
2. Adjust the config at the top:
   - `ROOM_ID` - must match the ID in the control room
   - `ROOM_NAME` - display name
   - `RELAY` - name of the redstone relay
   - `RELAY_SIDE` - output side of the relay
   - `MODEM_SIDE` - side of the computer the wireless modem is on
     (e.g. `"left"`); `nil` = auto-detect all sides
   - Optional extra lights on this computer: the `AUX_GROUPS` list, e.g.
     ```
     local AUX_GROUPS = {
         { id = "flur1", relay = "redstone_relay_X", side = "right" },
         { id = "flur2", relay = "redstone_relay_Y", side = "top"    },
     }
     ```
     Each `id` must match an entry in the control room's `aux` table.
     These groups are shown on the AUX monitor - not part of a room.
     Leave the list empty if not used.
3. Run: `startup.lua` (also autostarts)

## Security

Passwords are stored as a **SHA-256 hash** in `bunker.hash`.
The file is stored in the **same folder as the program** (so it stays with it
and survives copies/reboots). On the host disk it lives inside the
ComputerCraft computer directory of the world save:
`saves/<world>/computercraft/computer/<id>/bunker.hash`.

Changing the password requires the **current password**:
run `control setup` in the control room.

## Control room usage

- Monitor: tap the `[ TOGGLE ]` buttons to switch the lights
- Only the monitor set in `CONTROL_MONITOR` is interactive
- Terminal: `s` = status, `exit` = quit