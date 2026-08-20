unused_args = false
std = "luajit"
self = false

globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "_ENV",
}

files["spec/*"].std = "+busted"

ignore = {
    "211/__*",
    "231/__",
    "631",
    "dummy",
}
