# Bunker Control - ComputerCraft

Steuerung des Bunker-Lichts (Atrium) von einem einzelnen Computer mit Monitor und Touchscreen.

## Dateien

- `startup.lua` : Das komplette Programm (Server-only, steuert das Relay direkt)

## Voraussetzungen

- 1x Computer (Control-Raum)
- 1x Touchscreen-Monitor (am Computer)
- Redstone-Relay für das Licht (als Peripheral per Kabel erreichbar)
- Passwort: `bunker123`

## Konfiguration (in `startup.lua`)

| Variable | Bedeutung |
|----------|-----------|
| `PASSWORD` | Zugangs-Passwort |
| `RELAY` | Name des Redstone-Relays (z.B. `redstone_relay_4`) |
| `RELAY_SIDE` | Ausgangsseite des Relays (z.B. `right`) |

## Starten

```
startup.lua
```

Nach Passwort-Eingabe erscheint auf dem Monitor:

- Status (LICHT AN / LICHT AUS)
- `[ LICHT ]` Knopf

## Bedienung

- Tipp auf `[ LICHT ]` auf dem Monitor → Licht umschalten
- Oder Tastatur: `L` / Leertaste = Licht umschalten, `S` = Status anzeigen

## Automatischer Start

Site ist aktiv, sobald `startup.lua` im Computer-Root liegt (CC führt es automatisch beim Boot aus).
