# Bunker Netzwerk - ComputerCraft

Monitoring-System für ein Bunker-Netzwerk (Türen + Lampen) mit Control-Raum.

## Architektur

- **server.lua** : Control-Raum Computer - zeigt Status auf Monitoren, Passwort-Login, Fernsteuerung
- **client.lua** : Ein Computer pro Raum - liest/schreibt Redstone, sendet Status
- **config.lua**: Zentrale Konfiguration (Passwort, Räume, Redstone-Sides)

## Voraussetzungen (pro Computer)

- 1x Advanced/Normal Computer
- 1x Wired Modem **auf der "back"-Seite**
- Netzwerk-Kabel zwischen allen Computern
- Control-Raum: beliebig viele Monitore (an beliebiger Seite)

## Installation

Die Computer-IDs werden automatisch vergeben, sobald du Computer im Spiel platzierst.
Sie erscheinen als Ordner `computer/<ID>/` hier im Dateisystem.

### Methode A: Direkt über die ID-Ordner (empfohlen)

1. Computer im Spiel platzieren (Control-Raum + je 1 pro Raum)
2. ID-Nummern ablesen: Im Spiel `/` auf den Computer, obere Zeile zeigt die ID.
   Oder im Dateisystem: nach dem Platzieren erscheinen Ordner `computer/1/`, `computer/2/`, ...
3. Dateien in den passenden ID-Ordner kopieren:
   - **Control-Raum** (die Dateien in `bunker/`):
     ```
     config.lua
     server.lua
     ```
     Plus eine `startup.lua` (bei Bedarf) mit: `shell.run("bunker/server")`
   - **Jeder Raum-Client** (die Dateien in `bunker/`):
     ```
     config.lua
     client.lua
     ```
     Plus eine `startup.lua`: `shell.run("bunker/client <raum_id>")`
4. `config.lua` pro Computer anpassen (s. unten)

### Methode B: Diskette

Kopiere den Inhalt von `./bunker` auf eine Diskette. Steck die Diskette in einen
frischen Computer - die `startup`-Datei führt `install` aus, das die Dateien
einrichtet und Autostart setzt.

## config.lua anpassen (wichtig!)

```lua
config.password = "dein_passwort"   -- Passwort für Control-Raum

config.rooms = {
    {
        id = "atrium",          -- eindeutige Raum-ID (auch für client start)
        name = "Atrium",        -- Anzeige-Name auf dem Monitor
        door_side = "front",    -- RS-Seite der Tür (Redstone ein/aus)
        light_side = "right",   -- RS-Seite der Lampe
    },
    {
        id = "eingang",
        name = "Eingang",
        door_side = "front",
        light_side = "left",
    },
    -- Weitere Räume hier ergänzen...
}
```

Redstone-Seiten: `top`, `bottom`, `left`, `right`, `front`, `back`
(bezogen auf die Blickrichtung des Computers)

## Starten

**Control-Raum:**
```
bunker/server
```
Nach Passwort-Eingabe erscheint das Monitor-Layout und eine Befehlseingabe.

**Raum-Client (z.B. Atrium):**
```
bunker/client atrium
```

## Bedienung (Control-Raum)

| Befehl | Wirkung |
|--------|---------|
| `atrium toggle` | Tür + Licht umschalten |
| `atrium tuer an` / `atrium tuer aus` | Tür öffnen / schließen |
| `atrium licht an` / `atrium licht aus` | Lampe an / aus |
| `clear` | Status zurücksetzen |
| `exit` | Server beenden |

Raum-IDs: `atrium`, `eingang` (bzw. was in config.lua steht).

## Automatischer Start bei Reboot

Lege im jeweiligen `computer/<ID>/`-Ordner eine `startup.lua` an:
- Server: `shell.run("bunker/server")`
- Client: `shell.run("bunker/client <raum_id>")`

Die Computer führen diese beim Boot automatisch aus.
