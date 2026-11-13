-- Fixture tests for the CLI's UI parsers. Runs on the host, no Steam needed:
--
--   EMBER_CLI_LIBRARY_ONLY=1 lua tools/test_ui.lua
--
-- The CLI returns its parsers instead of running a command when that variable is
-- set, so this loads the real file rather than a copy of the logic.

local cli = arg[1] or "packages/cli/ember.lua"
local chunk = assert(loadfile(cli))
local lib = chunk()
assert(type(lib) == "table", "EMBER_CLI_LIBRARY_ONLY must be set for the CLI to expose its parsers")

local failures = 0
local function check(name, got, want)
	if got ~= want then
		failures = failures + 1
		io.stderr:write(("FAIL %s\n  got:  %s\n  want: %s\n"):format(name, tostring(got), tostring(want)))
	else
		print(("ok   %s"):format(name))
	end
end

-- parse_debug_port: both flag spellings, and the shapes that must not resolve.
check("port = form", lib.parse_debug_port("./steamwebhelper --remote-debugging-port=9222 --x"), 9222)
check("port space form", lib.parse_debug_port("./steamwebhelper --remote-debugging-port 9333"), 9333)
check("port absent", lib.parse_debug_port("./steamwebhelper -lang=en_US"), nil)
check("port out of range", lib.parse_debug_port("--remote-debugging-port=80"), nil)
check("port not a number", lib.parse_debug_port("--remote-debugging-port=abc"), nil)
check("port nil input", lib.parse_debug_port(nil), nil)

-- parse_targets: a real /json/list shape, plus noise that must be ignored.
local body = [==[ {
   "description": "",
   "devtoolsFrontendUrl": "/devtools/inspector.html?ws=127.0.0.1:8080/devtools/page/1",
   "id": "1",
   "title": "SharedJSContext",
   "type": "page",
   "url": "https://steamloopback.host/index.html",
   "webSocketDebuggerUrl": "ws://127.0.0.1:8080/devtools/page/1"
}, {
   "id": "2",
   "title": "Steam Store",
   "type": "page",
   "url": "https://store.steampowered.com/app/1091500/",
   "webSocketDebuggerUrl": "ws://127.0.0.1:8080/devtools/page/2"
} ]
]==]

local targets = lib.parse_targets(body)
check("target count", #targets, 2)
check("target 1 title", targets[1].title, "SharedJSContext")
check("target 1 kind", targets[1].kind, "page")
check("target 1 ws", targets[1].ws, "ws://127.0.0.1:8080/devtools/page/1")
check("target 2 url", targets[2].url, "https://store.steampowered.com/app/1091500/")

check("empty body", #lib.parse_targets(""), 0)
check("error body", #lib.parse_targets('{"error":"not found"}'), 0)
check("nil body", #lib.parse_targets(nil), 0)

if failures > 0 then
	io.stderr:write(("%d test(s) failed\n"):format(failures))
	os.exit(1)
end
print("all ui parser tests passed")
