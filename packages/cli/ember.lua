#!/usr/bin/env lua
-- ember CLI

local function sh(cmd)
	local pipe = io.popen(cmd)
	if not pipe then return "" end
	local out = pipe:read("a")
	pipe:close()
	return out or ""
end

-- Lua 5.4 returns true/nil from os.execute, not an exit code.
local function ok(cmd)
	return os.execute(cmd) == true
end

local function isDir(path) return ok("test -d '" .. path .. "'") end
local function isFile(path) return ok("test -f '" .. path .. "'") end

local function home()
	return os.getenv("HOME") or error("HOME is not set")
end

local function steamRoot()
	local h = home()
	for _, candidate in ipairs({ h .. "/.steam/steam", h .. "/.local/share/Steam" }) do
		if isDir(candidate .. "/config") then return candidate end
	end
	return h .. "/.local/share/Steam"
end

local function configDir()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	return (xdg and xdg ~= "" and xdg or (home() .. "/.config")) .. "/ember"
end

local function stplugDir() return steamRoot() .. "/config/stplug-in" end
local function storeDir() return configDir() .. "/manifests" end
local function depotCacheDir() return steamRoot() .. "/depotcache" end

local function mkdirp(path) ok("mkdir -p '" .. path .. "'") end

local function listFiles(dir, suffix)
	local out = {}
	if not isDir(dir) then return out end
	for name in sh("ls -1 '" .. dir .. "' 2>/dev/null"):gmatch("[^\n]+") do
		if not suffix or name:sub(-#suffix) == suffix then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function readFile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local content = f:read("a")
	f:close()
	return content
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Collects the directives a stplug-in script contributes, keyed by app/depot
-- so duplicates across files collapse the same way the core's maps do.
local function scanScript(path)
	local out = { apps = {}, keys = {}, pins = {} }
	local content = readFile(path)
	if not content then return out end

	-- The script is named after the app it unlocks; some generators only put the
	-- app id inside a depot-key line, so the filename is authoritative.
	local stem = path:match("([^/]+)%.lua$")
	if stem and stem:match("^%d+$") then
		out.apps[stem] = true
	end

	for line in content:gmatch("[^\n]+") do
		line = trim(line:gsub("%-%-.*$", ""))
		local name, args = line:match("^(%w+)%s*%((.*)%)$")
		if name then
			name = name:lower()
			local parts = {}
			for part in (args .. ","):gmatch("([^,]*),") do
				table.insert(parts, (trim(part):gsub('"', "")))
			end
			if name == "addappid" then
				if #parts == 1 then
					out.apps[parts[1]] = true
				elseif #parts == 3 then
					out.keys[parts[1]] = true
				end
			elseif name == "setmanifestid" and (#parts == 2 or #parts == 3) then
				out.pins[parts[1]] = true
			end
		end
	end
	return out
end

local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function isManifestName(name)
	local depot, gid = name:match("^(%d+)_(%d+)%.manifest$")
	return depot ~= nil and gid ~= nil
end

local function cmdImport(path)
	if not path or not isFile(path) then
		io.stderr:write("ember: no such file: " .. tostring(path) .. "\n")
		return 1
	end

	local lower = path:lower()
	local base = path:match("([^/]+)$")

	if lower:sub(-4) == ".lua" then
		mkdirp(stplugDir())
		local counts = scanScript(path)
		ok("cp -f '" .. path .. "' '" .. stplugDir() .. "/" .. base .. "'")
		print(string.format("imported %s: %d app id(s), %d depot key(s), %d manifest pin(s)",
			base, count(counts.apps), count(counts.keys), count(counts.pins)))
		print("Steam picks it up on the next config reload; no restart needed.")
		return 0
	end

	if lower:sub(-4) == ".zip" then
		-- Reject archives that would write outside the extraction directory
		-- before unzip gets a chance to do it.
		for entry in sh("unzip -Z1 '" .. path .. "' 2>/dev/null"):gmatch("[^\n]+") do
			if entry:match("^/") or entry:match("^%.%.") or entry:match("/%.%./") or entry:match("^%a:") then
				io.stderr:write("ember: refusing " .. path .. ": unsafe entry '" .. entry .. "'\n")
				return 1
			end
		end

		local tmp = trim(sh("mktemp -d"))
		if not ok("unzip -o -q '" .. path .. "' -d '" .. tmp .. "'") then
			ok("rm -rf '" .. tmp .. "'")
			io.stderr:write("ember: cannot extract " .. path .. "\n")
			return 1
		end

		mkdirp(storeDir())
		mkdirp(stplugDir())

		-- Two passes: manifests first, scripts last. The stplug-in directory is
		-- watched, so copying a script triggers a reload — the store has to be
		-- complete by then or the reload publishes nothing.
		local sources = {}
		for source in sh("find '" .. tmp .. "' -type f"):gmatch("[^\n]+") do
			table.insert(sources, source)
		end

		local manifests, scripts = 0, 0
		for _, source in ipairs(sources) do
			local name = source:match("([^/]+)$")
			if isManifestName(name) then
				ok("cp -f '" .. source .. "' '" .. storeDir() .. "/" .. name .. "'")
				manifests = manifests + 1
			end
		end
		for _, source in ipairs(sources) do
			local name = source:match("([^/]+)$")
			if name:sub(-4) == ".lua" and not isManifestName(name) then
				ok("cp -f '" .. source .. "' '" .. stplugDir() .. "/" .. name .. "'")
				scripts = scripts + 1
			end
		end

		ok("rm -rf '" .. tmp .. "'")

		-- A manifest-only archive touches nothing the watcher watches, so force
		-- the reload explicitly.
		if manifests > 0 then
			ok("touch '" .. configDir() .. "/config.yaml'")
		end
		print(string.format("imported %s: %d manifest(s), %d script(s)", base, manifests, scripts))
		if manifests > 0 then
			print("Manifests are published to depotcache on the next config reload.")
		end
		return 0
	end

	io.stderr:write("ember: unsupported file type: " .. path .. " (expected .lua or .zip)\n")
	return 1
end

local function cmdList()
	local scripts = listFiles(stplugDir(), ".lua")
	local apps, keys, pins = {}, {}, {}
	for _, name in ipairs(scripts) do
		local counts = scanScript(stplugDir() .. "/" .. name)
		for id in pairs(counts.apps) do apps[id] = true end
		for id in pairs(counts.keys) do keys[id] = true end
		for id in pairs(counts.pins) do pins[id] = true end
	end

	print(string.format("stplug-in: %d script(s), %d app id(s), %d depot key(s), %d manifest pin(s)",
		#scripts, count(apps), count(keys), count(pins)))
	for _, name in ipairs(scripts) do
		print("  " .. name)
	end

	print(string.format("manifest store: %d file(s)", #listFiles(storeDir(), ".manifest")))
	return 0
end

local function cmdStatus()
	print("steam root:     " .. steamRoot())

	local pids = {}
	for pid in sh("pgrep -f 'steamrt64/stea[m]' 2>/dev/null"):gmatch("%d+") do
		table.insert(pids, pid)
	end

	if #pids == 0 then
		print("client:         not running")
		print("core loaded:    no")
	else
		local loaded = false
		for _, pid in ipairs(pids) do
			if trim(sh("grep -c ember-core /proc/" .. pid .. "/maps 2>/dev/null")) ~= "0" then
				loaded = true
				break
			end
		end
		print(string.format("client:         running (%d process(es))", #pids))
		print("core loaded:    " .. (loaded and "yes" or "no"))
	end

	print(string.format("stplug-in:      %d script(s)", #listFiles(stplugDir(), ".lua")))
	print(string.format("manifest store: %d file(s)", #listFiles(storeDir(), ".manifest")))
	print(string.format("depotcache:     %d manifest(s)", #listFiles(depotCacheDir(), ".manifest")))
	return 0
end

local function cmdDoctor()
	local fails, warns = 0, 0
	local function line(label, value, state)
		local tag = ""
		if state == "ok" then tag = "ok"
		elseif state == "warn" then tag = "WARN"; warns = warns + 1
		elseif state == "fail" then tag = "FAIL"; fails = fails + 1
		elseif state == "info" then tag = "" end
		print(string.format("  %-17s %-46s %s", label, value, tag))
	end

	print("ember doctor\n")

	local root = steamRoot()
	if isDir(root .. "/config") then
		line("steam root", root, "ok")
	else
		line("steam root", "not found", "fail")
	end

	local pids = {}
	for pid in sh("pgrep -f 'steamrt64/stea[m]' 2>/dev/null"):gmatch("%d+") do
		table.insert(pids, pid)
	end

	local corePath = ""
	if #pids == 0 then
		line("client", "not running", "fail")
		line("core", "-", "fail")
	else
		line("client", string.format("running (%d process(es))", #pids), "ok")
		for _, pid in ipairs(pids) do
			local hit = sh("grep -o '/nix/store/[a-z0-9]*-ember-core[^ ]*' /proc/" .. pid .. "/maps 2>/dev/null | head -1")
			hit = trim(hit)
			if hit ~= "" then
				corePath = hit
				break
			end
		end
		if corePath ~= "" then
			line("core", corePath:match("([^/]+/[^/]+/[^/]+)$") or corePath, "ok")
		else
			line("core", "not mapped into the client", "fail")
		end
	end

	if isFile(configDir() .. "/.boot-in-progress") then
		line("boot marker", "present - last start died, next start runs vanilla", "warn")
	else
		line("boot marker", "absent", "ok")
	end

	local config = readFile(configDir() .. "/config.yaml")
	if config then
		local lang = config:match("\nDepotLanguages:%s*\"?([^\"\n]*)")
		if lang == nil or trim(lang) == "" then
			line("config", "ok, depot language follows the client", "ok")
		else
			line("config", "ok, depot languages [" .. trim(lang) .. "]", "ok")
		end
	else
		line("config", configDir() .. "/config.yaml missing", "warn")
	end

	local scripts = listFiles(stplugDir(), ".lua")
	local apps, keys, pins = {}, {}, {}
	for _, name in ipairs(scripts) do
		local sc = scanScript(stplugDir() .. "/" .. name)
		for id in pairs(sc.apps) do apps[id] = true end
		for id in pairs(sc.keys) do keys[id] = true end
		for id in pairs(sc.pins) do pins[id] = true end
	end
	line("stplug-in", string.format("%d script(s), %d app(s), %d key(s), %d pin(s)",
		#scripts, count(apps), count(keys), count(pins)), #scripts > 0 and "ok" or "info")

	-- depotcache is a staging area: Steam consumes an entry when it mounts the
	-- depot, so "not in depotcache" is expected and is not a health signal. The
	-- store is the durable copy.
	local stored = listFiles(storeDir(), ".manifest")
	local cached = listFiles(depotCacheDir(), ".manifest")
	line("manifest store", string.format("%d file(s)", #stored), #stored > 0 and "ok" or "info")
	line("depotcache", string.format("%d manifest(s), staged on demand", #cached), "info")

	local log = sh("tr -d '\\0' < " .. home() .. "/.ember.log 2>/dev/null")
	if log == "" then
		line("log", "empty or unreadable", "info")
	else
		if log:find("Failed to find all patterns", 1, true) then
			local names = {}
			for name in log:gmatch("Pattern not found: ([^\n]+)") do
				table.insert(names, name)
			end
			line("patterns", "FAILED: " .. (#names > 0 and table.concat(names, ", ") or "see log"), "fail")
		else
			line("patterns", "resolved", "ok")
		end

		if log:find("did not finish; running vanilla", 1, true) then
			line("last start", "boot guard tripped - ran vanilla", "warn")
		end
		if log:find("Captured SteamID", 1, true) then
			line("ownership", "SteamID captured", "ok")
		else
			line("ownership", "no SteamID captured yet (not logged in?)", "warn")
		end
	end

	print("")
	if fails > 0 then
		print(string.format("%d failure(s), %d warning(s)", fails, warns))
		return 1
	end
	if warns > 0 then
		print(string.format("%d warning(s)", warns))
		return 0
	end
	print("all checks passed")
	return 0
end

local function usage()
	print([[
ember — Steam library tooling

  ember import <file.lua|file.zip>   import a script or a manifest archive
  ember list                         show imported scripts and stored manifests
  ember status                       show client, store and depotcache state
  ember doctor                       check the whole stack and say what is wrong
]])
end

local command = arg[1]
if command == "import" then
	os.exit(cmdImport(arg[2]))
elseif command == "list" then
	os.exit(cmdList())
elseif command == "status" then
	os.exit(cmdStatus())
elseif command == "doctor" then
	os.exit(cmdDoctor())
else
	usage()
	os.exit(command == nil and 0 or 1)
end
