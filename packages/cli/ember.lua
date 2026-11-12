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

-- Counts the directives a stplug-in script contributes.
local function scanScript(path)
	local counts = { apps = 0, keys = 0, pins = 0 }
	local content = readFile(path)
	if not content then return counts end

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
					counts.apps = counts.apps + 1
				elseif #parts == 3 then
					counts.keys = counts.keys + 1
				end
			elseif name == "setmanifestid" and #parts == 2 then
				counts.pins = counts.pins + 1
			end
		end
	end
	return counts
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
			base, counts.apps, counts.keys, counts.pins))
		print("Steam picks it up on the next config reload; no restart needed.")
		return 0
	end

	if lower:sub(-4) == ".zip" then
		local tmp = trim(sh("mktemp -d"))
		if not ok("unzip -o -q '" .. path .. "' -d '" .. tmp .. "'") then
			ok("rm -rf '" .. tmp .. "'")
			io.stderr:write("ember: cannot extract " .. path .. "\n")
			return 1
		end

		mkdirp(storeDir())
		mkdirp(stplugDir())

		local manifests, scripts = 0, 0
		for source in sh("find '" .. tmp .. "' -type f"):gmatch("[^\n]+") do
			local name = source:match("([^/]+)$")
			if isManifestName(name) then
				ok("cp -f '" .. source .. "' '" .. storeDir() .. "/" .. name .. "'")
				manifests = manifests + 1
			elseif name:sub(-4) == ".lua" then
				ok("cp -f '" .. source .. "' '" .. stplugDir() .. "/" .. name .. "'")
				scripts = scripts + 1
			end
		end

		ok("rm -rf '" .. tmp .. "'")
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
	local apps, keys, pins = 0, 0, 0
	for _, name in ipairs(scripts) do
		local counts = scanScript(stplugDir() .. "/" .. name)
		apps, keys, pins = apps + counts.apps, keys + counts.keys, pins + counts.pins
	end

	print(string.format("stplug-in: %d script(s), %d app id(s), %d depot key(s), %d manifest pin(s)",
		#scripts, apps, keys, pins))
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

local function usage()
	print([[
ember — Steam library tooling

  ember import <file.lua|file.zip>   import a script or a manifest archive
  ember list                         show imported scripts and stored manifests
  ember status                       show client, store and depotcache state
]])
end

local command = arg[1]
if command == "import" then
	os.exit(cmdImport(arg[2]))
elseif command == "list" then
	os.exit(cmdList())
elseif command == "status" then
	os.exit(cmdStatus())
else
	usage()
	os.exit(command == nil and 0 or 1)
end
