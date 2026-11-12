-- ember plugin backend.
--
-- The whole feature lives in the browser script; the backend only registers it.
-- Paths are relative to the plugin root, which is how Millennium resolves them.

local millennium = require("millennium")

millennium.add_browser_js("public/protondb.js")

millennium.ready()
