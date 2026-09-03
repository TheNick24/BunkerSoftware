local config = {}

config.password = "bunker123"

config.rooms = {
    {
        id = "atrium",
        name = "Atrium",
        door_side = "front",
        light_side = "right",
    },
    {
        id = "eingang",
        name = "Eingang",
        door_side = "front",
        light_side = "left",
    },
}

config.update_interval = 2

return config
