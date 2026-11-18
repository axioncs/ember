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

-- Directory holding this CLI file. Assets shipped beside it (the CDP client, the
-- badge script) are found relative to it, which is the only lookup that still
-- works when the agent runs inside Steam's container: no session variables there.
local function scriptDir()
	local self = (arg and arg[0]) or ""
	local dir = self:match("^(.*)/[^/]+$")
	return dir or "."
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
	local out = { apps = {}, keys = {}, pins = {}, pinGid = {} }
	local content = readFile(path)
	if not content then return out end

	-- The script is named after the app it unlocks; some generators only put the
	-- app id inside a depot-key line, so the filename is authoritative.
	local stem = path:match("([^/]+)%.lua$")
	if stem and stem:match("^%d+$") then
		out.apps[stem] = true
	end

	for raw in content:gmatch("[^\n]+") do
		-- The for control variable is const in Lua 5.4; never assign to it.
		local line = trim(raw:gsub("%-%-.*$", ""))
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
				out.pinGid[parts[1]] = parts[2]
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

-- Steam's content manifest starts with the 32-bit magic 0x71F617D0.
local function looksLikeManifest(path)
	local f = io.open(path, "rb")
	if not f then return false end
	local magic = f:read(4)
	f:close()
	return magic == "\208\23\246\113"
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

		local manifests, scripts, rejected = 0, 0, 0
		for _, source in ipairs(sources) do
			local name = source:match("([^/]+)$")
			if isManifestName(name) then
				if looksLikeManifest(source) then
					ok("cp -f '" .. source .. "' '" .. storeDir() .. "/" .. name .. "'")
					manifests = manifests + 1
				else
					rejected = rejected + 1
				end
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
		if rejected > 0 then
			print(string.format("skipped %d file(s) that are not Steam manifests", rejected))
		end
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

-- The rclone remote (e.g. "gdrive", "onedrive") the user configured, and the
-- folder inside it. Both are read here rather than shelled out: the CLI must
-- work with only lua and rclone on PATH, and these are the only keys it needs.
--
-- The folder inside it. Namespaced to ember on purpose: another save-sync tool
-- uses a different folder name, and its files look nothing like ember's, so
-- sharing one would make each tool treat the other's data as stale and delete
-- it. It is a separate key because rclone remotes are written both as a bare
-- name ("gdrive") and with a path ("gdrive:backups/ember"), and appending to
-- either form cannot work for both.
local function cloudConfig(key)
	-- Environment wins over the file: the NixOS module sets these, and a
	-- declarative option has to beat a value left in config.yaml.
	local env = os.getenv("EMBER_CLOUD_" .. key:sub(6):upper())
	if env and env ~= "" then return env end

	local content = readFile(configDir() .. "/config.yaml")
	if not content then return nil end
	for line in content:gmatch("([^\n]+)") do
		local value = line:match("^%s*" .. key .. "%s*:%s*(.-)%s*$")
		if value and value ~= "" then return value end
	end
	return nil
end

local function cloudRemote()
	return cloudConfig("CloudRemote") or ""
end

-- Cloud is on unless the config or the NixOS option says otherwise. Mirrors
-- the core's own rule, so `status` and the library agree.
local function cloudEnabled()
	local env = os.getenv("EMBER_CLOUD")
	if env ~= nil and env ~= "" then
		local v = env:lower()
		return not (v == "0" or v == "no" or v == "false")
	end

	local content = readFile(configDir() .. "/config.yaml")
	if content then
		for line in content:gmatch("([^\n]+)") do
			local value = line:match("^%s*Cloud%s*:%s*(.-)%s*$")
			if value then
				local v = value:lower()
				return not (v == "0" or v == "no" or v == "false")
			end
		end
	end
	return true
end

local function cloudRemoteFolder()
	return cloudConfig("CloudFolder") or "ember-cloud"
end

local function cloudRoot()
	return configDir() .. "/cloud"
end

-- A bare remote name is "name:"; a remote that already carries a path is used
-- as written. Either way the trailing slash makes rclone copy contents, not
-- the directory itself.
local function cloudRemotePath()
	local remote = cloudRemote()
	if remote == "" then return "" end
	-- A bare name ("gdrive") takes the folder at its root; a remote written
	-- with a path ("gdrive:backups") gets the folder appended below it.
	local prefix = remote:match(":") and (remote .. "/") or (remote .. ":")
	return prefix .. cloudRemoteFolder()
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
			-- Any path ending in ember-core: the NixOS module uses a store path,
			-- the installer uses ~/.local/share/ember.
			local hit = sh("grep -o '/[^ ]*ember-core[^ ]*' /proc/" .. pid .. "/maps 2>/dev/null | head -1")
			hit = trim(hit)
			if hit ~= "" then
				corePath = hit
				break
			end
		end
		if corePath ~= "" then
			line("core", corePath:match("([^/]+/[^/]+/[^/]+)$") or corePath, "ok")
		else
			-- Distinguish "never asked to load" from "asked and failed".
			local audit = ""
			for _, pid in ipairs(pids) do
				audit = trim(sh("tr '\\0' '\\n' < /proc/" .. pid .. "/environ 2>/dev/null | sed -n 's/^LD_AUDIT=//p' | head -1"))
				if audit ~= "" then
					break
				end
			end
			if audit == "" then
				line("core", "client started without ember - launch it with steam-ember", "fail")
			else
				line("core", "LD_AUDIT set but not loaded - see the terminal output", "fail")
			end
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

	-- Cloud saves for added games are served from the local store by the core;
	-- moving them off the machine is the CLI's job, and it needs rclone.
	if isDir(configDir() .. "/cloud") then
		local hasRclone = trim(sh("command -v rclone 2>/dev/null")) ~= ""
		local remote = cloudRemote()
		if not hasRclone then
			line("cloud", "rclone not installed - saves stay local", "warn")
		elseif remote == "" then
			line("cloud", "no CloudRemote set - saves stay local", "warn")
		else
			line("cloud", string.format("%s (%s)", remote, cloudRemotePath() .. "/"), "ok")
		end
	else
		line("cloud", "no store yet", "info")
	end

	-- Every pin has to have its manifest in the store, or the install fails with
	-- "No connection" when Steam asks the server for a manifest request code.
	local storeSet = {}
	for _, name in ipairs(stored) do storeSet[name] = true end
	local totalPins, missingPins = 0, 0
	local missingByApp = {}
	for _, name in ipairs(scripts) do
		local sc = scanScript(stplugDir() .. "/" .. name)
		local appMissing = 0
		for depot, gid in pairs(sc.pinGid) do
			totalPins = totalPins + 1
			if not storeSet[depot .. "_" .. gid .. ".manifest"] then
				missingPins = missingPins + 1
				appMissing = appMissing + 1
			end
		end
		if appMissing > 0 then
			table.insert(missingByApp, string.format("%s (%d)", name:gsub("%.lua$", ""), appMissing))
		end
	end
	line("coverage", string.format("%d of %d pin(s) have a manifest",
		totalPins - missingPins, totalPins), missingPins == 0 and "ok" or "warn")
	if missingPins > 0 then
		line("", "incomplete: " .. table.concat(missingByApp, ", "), "info")
	end

	local log = sh("cat " .. home() .. "/.ember.log 2>/dev/null | tr -d '\\0'")
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

local function cmdRemove(appid)
	if not appid or not appid:match("^%d+$") then
		io.stderr:write("ember: usage: ember remove <appid>\n")
		return 2
	end

	local script = stplugDir() .. "/" .. appid .. ".lua"
	if not isFile(script) then
		io.stderr:write("ember: nothing imported for " .. appid .. "\n")
		return 1
	end

	local sc = scanScript(script)

	-- A depot manifest can be pinned by more than one app, so keep whatever the
	-- remaining scripts still reference.
	local keep = {}
	for _, name in ipairs(listFiles(stplugDir(), ".lua")) do
		if name ~= appid .. ".lua" then
			local other = scanScript(stplugDir() .. "/" .. name)
			for depot, gid in pairs(other.pinGid) do
				keep[depot .. "_" .. gid .. ".manifest"] = true
			end
		end
	end

	local removed = 0
	for depot, gid in pairs(sc.pinGid) do
		local name = depot .. "_" .. gid .. ".manifest"
		if not keep[name] and isFile(storeDir() .. "/" .. name) then
			ok("rm -f '" .. storeDir() .. "/" .. name .. "'")
			removed = removed + 1
		end
	end

	ok("rm -f '" .. script .. "'")
	ok("touch '" .. configDir() .. "/config.yaml'")

	print(string.format("removed %s: 1 script, %d manifest(s)", appid, removed))
	return 0
end

local function dataDir()
	local xdg = os.getenv("XDG_DATA_HOME")
	return (xdg and xdg ~= "" and xdg or (home() .. "/.local/share")) .. "/ember"
end

local function installedVersion()
	local text = readFile(dataDir() .. "/VERSION")
	return text and trim(text) or ""
end

local function latestVersion()
	local body = sh("curl -fsSL https://api.github.com/repos/axioncs/ember/releases/latest 2>/dev/null")
	return body:match('"tag_name"%s*:%s*"([^"]+)"') or ""
end

local function cmdUpdate(checkOnly)
	-- On NixOS the library comes from the flake; installing over it would be
	-- overwritten on the next rebuild anyway.
	if isFile("/etc/NIXOS") then
		print("ember is managed by the NixOS module here.")
		print("  cd ~/nixos && nix flake update ember && nh os switch ~/nixos")
		return 1
	end

	local installed = installedVersion()
	local latest = latestVersion()
	if latest == "" then
		io.stderr:write("ember: cannot reach github.com to check for releases\n")
		return 1
	end

	print(string.format("installed  %s", installed ~= "" and installed or "unknown"))
	print(string.format("latest     %s", latest))

	if installed == latest then
		print("up to date")
		return 0
	end

	if checkOnly then
		print("a newer release is available: ember update")
		return 0
	end

	print("")
	local flags = ""
	local chosen = readFile(dataDir() .. "/install-flags")
	if chosen then flags = trim(chosen) end
	local cmd = "curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh"
	if flags ~= "" then cmd = string.format("%s -s -- %s", cmd, flags) end
	local ok_run = os.execute(cmd)
	return ok_run == true and 0 or 1
end

local function humanSize(n)
	local units = { "B", "KiB", "MiB", "GiB", "TiB" }
	local value, unit = tonumber(n) or 0, 1
	while value >= 1024 and unit < #units do
		value = value / 1024
		unit = unit + 1
	end
	if unit == 1 then return string.format("%d %s", value, units[unit]) end
	return string.format("%.1f %s", value, units[unit])
end

-- ---------------------------------------------------------------------------
-- Cloud saves: rclone-backed sync of the added-app save store
--
-- The core serves Cloud.* RPCs from <config>/cloud for apps the account does
-- not own, so saves accumulate as plain files there. Nothing in this file
-- touches the network: every command is one rclone invocation, which keeps
-- OAuth, token refresh, retry and every provider rclone supports out of the
-- client and out of ember. The layout on the remote mirrors the local one,
-- <account>/<app>/…, so the remote stays readable without ember.
-- ---------------------------------------------------------------------------

local function cloudReady(needStore)
	if not cloudEnabled() then
		io.stderr:write("ember: cloud saves are off (Cloud: no)\n")
		io.stderr:write("ember: set Cloud: yes in " .. configDir() .. "/config.yaml first\n")
		return false
	end
	if trim(sh("command -v rclone 2>/dev/null")) == "" then
		io.stderr:write("ember: rclone is not installed\n")
		io.stderr:write("ember: install it, then: rclone config\n")
		return false
	end
	if cloudRemote() == "" then
		io.stderr:write("ember: no CloudRemote in " .. configDir() .. "/config.yaml\n")
		io.stderr:write("ember: add  CloudRemote: <name>  naming a remote from 'rclone listremotes'\n")
		return false
	end
	-- A pull creates the store; only a push needs one to exist already.
	if needStore and not isDir(cloudRoot()) then
		io.stderr:write("ember: no save store yet at " .. cloudRoot() .. "\n")
		io.stderr:write("ember: launch an added game once, then sync\n")
		return false
	end
	return true
end

-- Account ids of the saves in a directory tree. Both layouts are recognised:
-- ember's <account>/<app>/ and the per-account folders another save-sync tool
-- leaves behind, so a collision is caught either way.
local function cloudAccountsAt(path)
	local found = {}
	local listing = trim(sh("rclone lsf --dirs-only '" .. path .. "' 2>/dev/null"))
	for name in listing:gmatch("([^\n]+)") do
		local id = (name:gsub("/$", ""))
		if id:match("^%d+$") then table.insert(found, id) end
	end
	table.sort(found)
	return found
end

local function cmdCloudPush()
	if not cloudReady(true) then return 1 end
	local src, dst = cloudRoot() .. "/", cloudRemotePath() .. "/"

	-- sync makes the remote match the local store, so anything already there
	-- that ember did not put there is deleted. Refuse when the remote belongs to
	-- a different account: that is either someone else's saves or another
	-- tool's, and neither is recoverable.
	local remote = cloudAccountsAt(dst)
	if #remote > 0 then
		local localIds = {}
		for account in sh("ls -1 '" .. cloudRoot() .. "' 2>/dev/null"):gmatch("([^\n]+)") do
			if account:match("^%d+$") then table.insert(localIds, account) end
		end
		local mine = {}
		for _, id in ipairs(localIds) do mine[id] = true end

		local foreign = {}
		for _, id in ipairs(remote) do
			if not mine[id] then table.insert(foreign, id) end
		end

		if #foreign > 0 then
			io.stderr:write("ember: " .. dst .. " holds saves for another account: " ..
				table.concat(foreign, ", ") .. "\n")
			io.stderr:write("ember: pushing would delete them, because sync makes the remote\n")
			io.stderr:write("ember: match this machine. Move them aside first:\n")
			io.stderr:write("ember:   rclone move " .. dst .. " " .. dst .. "old\n")
			io.stderr:write("ember: or set CloudFolder to an empty folder of its own.\n")
			return 1
		end
	end

	print("pushing " .. src .. " -> " .. dst)
	local pipe = io.popen("rclone sync --stats-one-line '" .. src .. "' '" .. dst .. "' 2>&1")
	local out = pipe:read("a")
	local code = pipe:close()
	print(trim(out or ""))
	return code and 0 or 1
end

local function cmdCloudPull()
	if not cloudReady(false) then return 1 end
	local src, dst = cloudRemotePath() .. "/", cloudRoot() .. "/"
	print("pulling " .. src .. " -> " .. dst)
	local pipe = io.popen("rclone sync --stats-one-line '" .. src .. "' '" .. dst .. "' 2>&1")
	local out = pipe:read("a")
	local code = pipe:close()
	print(trim(out or ""))
	return code and 0 or 1
end

local function cmdCloudStatus()
	if not cloudEnabled() then
		print("cloud saves:   off (Cloud: no)")
		return 0
	end

	local store = cloudRoot()
	if not isDir(store) then
		print("cloud store:   none yet")
		local remote = cloudRemote()
		if remote ~= "" then
			print(string.format("  remote:      %s (%s)", remote, cloudRemotePath() .. "/"))
		else
			print("  remote:      not configured (CloudRemote)")
		end
		return 0
	end

	-- Walked in Lua: the CLI may have only lua and rclone on PATH, and a
	-- `find` that is not there silently reports zero blobs.
	local apps, blobs, bytes = 0, 0, 0
	for account in sh("ls -1 '" .. store .. "' 2>/dev/null"):gmatch("([^\n]+)") do
		local accountPath = store .. "/" .. account
		if isDir(accountPath) then
			for app in sh("ls -1 '" .. accountPath .. "' 2>/dev/null"):gmatch("([^\n]+)") do
				local appPath = accountPath .. "/" .. app
				if isDir(appPath) then
					apps = apps + 1
					local manifest = readFile(appPath .. "/manifest")
					if manifest then bytes = bytes + #manifest end
					local cn = readFile(appPath .. "/cn")
					if cn then bytes = bytes + #cn end
					blobs = blobs + 2
					for blob in sh("ls -1 '" .. appPath .. "/blobs' 2>/dev/null"):gmatch("([^\n]+)") do
						local path = appPath .. "/blobs/" .. blob
						local f = io.open(path, "rb")
						if f then
							bytes = bytes + (f:seek("end") or 0)
							f:close()
							blobs = blobs + 1
						end
					end
				end
			end
		end
	end

	print(string.format("cloud store:   %s", store))
	print(string.format("  apps:        %d", apps))
	print(string.format("  blobs:       %d (%s)", blobs, humanSize(bytes)))

	local remote = cloudRemote()
	if remote == "" then
		print("  remote:      not configured (CloudRemote)")
		return 0
	end
	local dst = cloudRemotePath() .. "/"
	-- -R: lsf is non-recursive by default, and the store is account/app/blobs.
	local listing = trim(sh("rclone lsf -R --files-only --format sp '" .. dst .. "' 2>/dev/null"))
	local remoteCount, remoteBytes = 0, 0
	if listing ~= "" then
		for line in listing:gmatch("([^\n]+)") do
			-- `--format sp` separates the two fields with ';'.
			local size = line:match("^([%d]+);")
			if size then
				remoteBytes = remoteBytes + tonumber(size)
				remoteCount = remoteCount + 1
			end
		end
	end
	if remoteCount == 0 then
		print(string.format("  remote:      %s (%s) empty or unreachable", remote, dst))
	else
		print(string.format("  remote:      %s (%s), %d blob(s)", remote, dst, remoteCount))
		print(string.format("  compare:     %s local, %s remote", humanSize(bytes), humanSize(remoteBytes)))

		-- A count gap this large is almost never "this machine is behind": it
		-- means the folder holds saves for another account, or another tool's
		-- data. Say so here, because push would delete it.
		-- Any account folder up here that this machine does not have is data
		-- ember did not write, and sync would delete it. Check unconditionally:
		-- a count gap is a hint, the account id is the proof.
		local foreign = {}
		for _, id in ipairs(cloudAccountsAt(dst)) do
			local mine = false
			for account in sh("ls -1 '" .. cloudRoot() .. "' 2>/dev/null"):gmatch("([^\n]+)") do
				if account == id then mine = true end
			end
			if not mine then table.insert(foreign, id) end
		end
		if #foreign > 0 then
			print(string.format("  WARNING:     holds saves for another account (%s)",
				table.concat(foreign, ", ")))
			print("               push would delete them. Move them aside first.")
		end
	end
	return 0
end

local function cmdCloudSetup()
	if trim(sh("command -v rclone 2>/dev/null")) == "" then
		io.stderr:write("ember: rclone is not installed\n")
		io.stderr:write("ember: install it, then: rclone config\n")
		return 1
	end

	local listing = trim(sh("rclone listremotes 2>/dev/null"))
	if listing == "" then
		print("No rclone remotes are configured yet.")
		print("")
		print("  1. rclone config      - add one; the login happens in your browser")
		print("  2. ember cloud setup  - pick it here")
		return 0
	end

	print("Configured rclone remotes:")
	local names = {}
	for name in listing:gmatch("([^\n]+)") do
		table.insert(names, (name:gsub(":$", "")))
		print(string.format("  %d) %s", #names, names[#names]))
	end

	io.write("\nSelect [skip]: ")
	local choice = io.read("*l") or ""
	choice = trim(choice)
	if choice == "" then
		print("Skipped.")
		return 0
	end
	local index = tonumber(choice)
	if not index or not names[index] then
		io.stderr:write("ember: no such remote: " .. choice .. "\n")
		return 1
	end

	local chosen = names[index]
	local path = configDir() .. "/config.yaml"
	local content = readFile(path) or ""

	-- Rewrite the key rather than append: two CloudRemote lines leave the
	-- first one winning, which reads as "the setting did nothing".
	if content:match("^\n?CloudRemote:.*$") then
		content = content:gsub("(^|\n)CloudRemote:.*\n?", "%1CloudRemote: " .. chosen .. "\n", 1)
	else
		content = content .. "\n# rclone remote ember cloud syncs saves with\nCloudRemote: " .. chosen .. "\n"
	end

	mkdirp(configDir())
	local f = io.open(path, "w")
	if not f then
		io.stderr:write("ember: cannot write " .. path .. "\n")
		return 1
	end
	f:write(content)
	f:close()

	print("cloud remote: " .. chosen)
	print("upload with:  ember cloud push")
	return 0
end

local function cmdCloud()
	print([[
ember cloud <command>

  setup           choose which rclone remote saves sync to
  push            upload the save store to the configured rclone remote
  pull            download the remote over the local store
  status          show local and remote save counts

Configure: rclone config, then add CloudRemote: <name> to
~/.config/ember/config.yaml
]])
	return 0
end

-- ---------------------------------------------------------------------------
-- UI layer: endpoint discovery
--
-- Store pages, settings panels and themes are rendered by steamwebhelper, not by
-- the client process, so anything that changes them needs a Chromium DevTools
-- (CDP) connection to that process. The endpoint only exists when remote
-- debugging is enabled; this section finds it and says what is missing, and the
-- injector is built on the connection it returns.
-- ---------------------------------------------------------------------------

-- Pulls the port out of a webhelper command line. Pure so the fixture test can
-- drive it; both spellings occur (`--flag=N` and `--flag N`).
local function parseDebugPort(raw)
	if type(raw) ~= "string" then return nil end
	local value = raw:match("%-%-remote%-debugging%-port=(%d+)")
	if not value then value = raw:match("%-%-remote%-debugging%-port%s+(%d+)") end
	if not value then return nil end
	local port = tonumber(value)
	if not port or port < 1024 or port > 65535 then return nil end
	return port
end

-- Extracts the string fields of every object in a `/json/list` response. A full
-- JSON decoder for one fixed response shape would be more code than this and no
-- safer: the only consumer is a status listing.
local function parseTargets(body)
	local targets = {}
	if type(body) ~= "string" then return targets end
	for object in body:gmatch("{.-}") do
		local function field(name)
			return object:match('"' .. name .. '"%s*:%s*"([^"]*)"')
		end
		local title = field("title")
		local url = field("url")
		if title or url then
			table.insert(targets, {
				title = title,
				url = url,
				kind = field("type"),
				ws = field("webSocketDebuggerUrl"),
			})
		end
	end
	return targets
end

local function webhelpers()
	local helpers = {}
	for pid in sh("pgrep -f 'steamwebhelpe[r]' 2>/dev/null"):gmatch("%d+") do
		local cmdline = sh("tr '\\0' ' ' < /proc/" .. pid .. "/cmdline 2>/dev/null")
		table.insert(helpers, { pid = pid, port = parseDebugPort(cmdline) })
	end
	return helpers
end

-- The shim publishes the endpoint it opened, with the owner pid and the kernel's
-- start ticks (field 22 of /proc/<pid>/stat) so a file left behind by a previous
-- session cannot be mistaken for a live one.
local function readContract()
	local text = readFile(configDir() .. "/cef_port")
	if not text then return nil end
	local port = tonumber(text:match("^%s*(%d+)"))
	if not port or port < 1024 or port > 65535 then return nil end

	local pid, ticks = text:match("owner%s+(%d+)%s+(%d+)")
	if pid then
		local stat = readFile("/proc/" .. pid .. "/stat")
		if not stat then return nil end
		local rest = stat:match("%)%s+(.*)$")
		if rest then
			-- The state field is 3, so field 22 is the 20th token after the comm.
			local index, live = 1, nil
			for value in rest:gmatch("%S+") do
				if index == 20 then
					live = value
					break
				end
				index = index + 1
			end
			if live ~= nil and live ~= ticks then return nil end
		end
	end

	local how = "contract " .. configDir() .. "/cef_port"
	if pid then how = how .. " (pid " .. pid .. ")" end
	return port, how
end

-- The endpoint the client actually published, and how we know. Without a flag
-- on some webhelper there is nothing to go on but Steam's default port, which
-- this reports as an assumption rather than a fact.
local function cdpEndpoint()
	local port, how = readContract()
	if port then return port, how end

	local helpers = webhelpers()
	for _, helper in ipairs(helpers) do
		if helper.port then
			return helper.port, "passed to webhelper pid " .. helper.pid
		end
	end
	return 8080, "assumed, no webhelper carries --remote-debugging-port"
end

-- Where the pieces of the UI layer live. The release artifact puts the CDP
-- client and the badge script beside the CLI; a source checkout has them under
-- packages/. Neither is required for the rest of the CLI to work.
local function cdpTool()
	local override = os.getenv("EMBER_CDPD")
	if override and override ~= "" and isFile(override) then return override end
	for _, candidate in ipairs({
		scriptDir() .. "/ember-cdpd",
		dataDir() .. "/ember-cdpd",
		home() .. "/.local/share/ember/ember-cdpd",
	}) do
		if isFile(candidate) then return candidate end
	end
	local found = trim(sh("command -v ember-cdpd 2>/dev/null"))
	return found ~= "" and found or nil
end

local function badgeAsset()
	local override = os.getenv("EMBER_BADGE")
	if override and override ~= "" and isFile(override) then return override end
	for _, candidate in ipairs({
		scriptDir() .. "/badge.js",
		dataDir() .. "/badge.js",
		home() .. "/.local/share/ember/badge.js",
		"packages/cdp/badge.js",
	}) do
		if isFile(candidate) then return candidate end
	end
	return nil
end

-- The store page ember can draw on. Steam keeps one webview per page it has
-- visited, so several may match; the last one in the list is the newest.
local function storeTarget(appid)
	local body = sh("curl -sS --max-time 2 'http://127.0.0.1:8080/json/list' 2>/dev/null")
	local chosen
	for _, target in ipairs(parseTargets(body)) do
		local id = (target.url or ""):match("^https://store%.steampowered%.com/app/(%d+)")
		if id and target.ws and (not appid or id == appid) then
			chosen = { appid = id, ws = target.ws, url = target.url }
		end
	end
	return chosen
end

-- Runs the CDP client against a JS file and returns what the page returned.
local function evaluateFile(ws, path)
	local binary = cdpTool()
	if not binary then return nil, "ember-cdpd is not installed" end

	local out = os.tmpname()
	local saved = os.tmpname()
	local captured = io.open(saved, "w")
	if captured then captured:close() end

	local ran = ok(
		("'%s' --ws '%s' --eval-file '%s' > '%s' 2>'%s'"):format(binary, ws, path, out, saved)
	)
	local text = trim(readFile(out) or "")
	local err = trim(readFile(saved) or "")
	os.remove(out)
	os.remove(saved)
	if not ran and text == "" then return nil, err ~= "" and err or "no response from the page" end
	return text
end

-- The tier, fetched here rather than in the page: the store page's CSP refuses
-- the request (verified: `fetch(protondb)` fails, `fetch(api.steampowered.com)`
-- passes), and a host-side fetch has no such restriction.
local function protondbTier(appid)
	local body = sh(("curl -fsS --max-time 6 'https://www.protondb.com/api/v1/reports/summaries/%s.json' 2>/dev/null"):format(appid))
	if body == "" then return nil end
	local tier = body:match('"tier"%s*:%s*"([%w_]+)"')
	if not tier then return nil end
	return tier, (body:gsub("[\r\n]+", " "))
end

local function selfPid()
	local stat = readFile("/proc/self/stat")
	return stat and stat:match("^(%d+)") or nil
end

-- One agent per user. mkdir is atomic; a lock whose pid is gone is stale.
local function claimAgent()
	local dir = configDir() .. "/ui-agent.lock"
	local pidfile = dir .. "/pid"
	local existing = trim(readFile(pidfile) or "")
	if existing ~= "" and isDir("/proc/" .. existing) then return nil end
	ok("rm -rf '" .. dir .. "'")
	if not ok("mkdir -p '" .. dir .. "'") then return nil end
	local handle = io.open(pidfile, "w")
	if handle then
		handle:write((selfPid() or "0") .. "\n")
		handle:close()
	end
	return dir
end

local function releaseAgent(dir) ok("rm -rf '" .. dir .. "'") end

local function buildBadgeSource(asset, appid, tierJson)
	local template = readFile(asset)
	if not template then return nil end
	local source = (template:gsub("__EMBER_APPID__", appid))
	return (source:gsub("__EMBER_TIER_JSON__", function() return tierJson or "null" end))
end

local function evaluateSource(ws, source)
	local path = os.tmpname()
	local handle = io.open(path, "w")
	if not handle then return nil, "cannot write a temporary script" end
	handle:write(source)
	handle:close()
	local result, err = evaluateFile(ws, path)
	os.remove(path)
	return result, err
end

local function renderBadge(target)
	local asset = badgeAsset()
	if not asset then return nil, "badge.js is not installed" end
	local _, json = protondbTier(target.appid)
	local source = buildBadgeSource(asset, target.appid, json)
	if not source then return nil, "cannot read " .. asset end
	return evaluateSource(target.ws, source)
end

local function cmdUIAttach(appid)
	local target = storeTarget(appid)
	if not target then
		io.stderr:write("ember ui: no store app page is open in Steam; open one and retry\n")
		return 1
	end
	local result, err = renderBadge(target)
	if not result then
		io.stderr:write("ember ui: " .. tostring(err) .. "\n")
		return 1
	end
	print(("app %s: %s"):format(target.appid, result))
	return result:match("^ok") and 0 or 1
end

-- The agent runs detached, inside Steam's container, with stdout on /dev/null.
-- Without a file there is no way to tell "never started" from "started and
-- exited", which is exactly the question its own launcher raises.
local function agentLog(message)
	local path = configDir() .. "/ui-agent.log"
	local handle = io.open(path, "a")
	if handle then
		handle:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. message .. "\n")
		handle:close()
	end
end

-- Draws on every store page that is open, for as long as the client lives. This
-- is what makes the badge appear by itself: the launcher starts the agent with
-- Steam, it re-attaches when a page is created and redraws after a navigation
-- replaces the header. Exits when the client is gone, so nothing lingers.
local function cmdUIWatch(interval, quiet)
	interval = interval or 2
	local lock = claimAgent()
	if not lock then
		if not quiet then print("ember ui: an agent is already running") end
		return 0
	end

	local asset = badgeAsset()
	if not asset then
		agentLog("badge.js missing; scriptDir=" .. scriptDir() .. " dataDir=" .. dataDir())
		io.stderr:write("ember ui: badge.js is not installed\n")
		releaseAgent(lock)
		return 1
	end
	agentLog("started pid " .. (selfPid() or "?") .. ", every " .. interval .. "s")
	if not quiet then print("ember ui: watching store pages every " .. interval .. "s") end

	local tiers = {}
	local seen_client, idle = false, 0
	while true do
		-- Started by the launcher, which runs before the client is up: give it a
		-- grace window rather than exiting on the first empty check.
		if ok("pgrep -f 'steamrt64/stea[m]' >/dev/null 2>&1") then
			seen_client = true
			idle = 0
		elseif seen_client then
			break
		else
			idle = idle + 1
			if idle * interval > 120 then break end
		end

		local body = sh("curl -sS --max-time 2 'http://127.0.0.1:8080/json/list' 2>/dev/null")
		for _, target in ipairs(parseTargets(body)) do
			local appid = (target.url or ""):match("^https://store%.steampowered%.com/app/(%d+)")
			if appid and target.ws then
				local cached = tiers[appid]
				if not cached then
					local seen, json = protondbTier(appid)
					cached = { json = json, tier = seen }
					tiers[appid] = cached
				end
				local source = buildBadgeSource(asset, appid, cached.json)
				if source then
					local result = evaluateSource(target.ws, source)
					if result and not result:match("^keep") and not quiet then
						print(("app %s: %s"):format(appid, result))
					end
				end
			end
		end

		os.execute("sleep " .. interval)
	end

	releaseAgent(lock)
	agentLog("client gone, exiting")
	return 0
end

local function cmdUI(sub, arg2)
	if sub == "attach" then return cmdUIAttach(arg2) end
	if sub == "watch" then
		local quiet = (arg2 == "--quiet") or (arg3 == "--quiet")
		local seconds = tonumber(arg2) or (arg3 and tonumber(arg3))
		return cmdUIWatch(seconds, quiet)
	end
	if sub ~= nil and sub ~= "status" then
		io.stderr:write("ember ui: unknown subcommand: " .. tostring(sub) .. "\n")
		return 2
	end

	local marker = steamRoot() .. "/.cef-enable-remote-debugging"
	print(string.format("%-18s%s", "marker", isFile(marker) and marker or "absent (" .. marker .. ")"))

	local helpers = webhelpers()
	if #helpers == 0 then
		print(string.format("%-18s%s", "webhelper", "not running"))
	else
		for _, helper in ipairs(helpers) do
			print(string.format("%-18s%s", "webhelper",
				"pid " .. helper.pid .. ", port " .. (helper.port and tostring(helper.port) or "none")))
		end
	end

	local port, how = cdpEndpoint()
	print(string.format("%-18s%s", "endpoint", port .. " (" .. how .. ")"))

	local body = sh("curl -sS --max-time 2 'http://127.0.0.1:" .. port .. "/json/list' 2>/dev/null")
	local targets = parseTargets(body)
	if #targets == 0 then
		print(string.format("%-18s%s", "targets", "none, the endpoint is not answering"))
		print("")
		print("The DevTools endpoint is closed. Steam only opens it when remote")
		print("debugging is enabled, and ember does not enable it yet: the marker")
		print("and the webhelper flag both have to be checked against the running")
		print("client before that switch is written.")
		return 1
	end

	print(string.format("%-18s%s", "targets", tostring(#targets)))
	for _, target in ipairs(targets) do
		print(string.format("  %-9s %s", target.kind or "?", target.title or target.url or "?"))
	end
	return 0
end

local function usage()
	print([[
ember — Steam library tooling

  ember import <file.lua|file.zip>   import a script or a manifest archive
  ember remove <appid>               drop an imported app and its manifests
  ember list                         show imported scripts and stored manifests
  ember status                       show client, store and depotcache state
  ember ui [status]                  show the store-page injection endpoint
  ember cloud <push|pull|status>     sync saves to your own storage (rclone)
  ember doctor                       check the whole stack and say what is wrong
  ember update [--check]             update to the latest release
]])
end

-- Tests load this file for its parsers instead of running a command.
if os.getenv("EMBER_CLI_LIBRARY_ONLY") then
	return { parse_debug_port = parseDebugPort, parse_targets = parseTargets }
end

local command = arg[1]
if command == "import" then
	os.exit(cmdImport(arg[2]))
elseif command == "remove" then
	os.exit(cmdRemove(arg[2]))
elseif command == "list" then
	os.exit(cmdList())
elseif command == "status" then
	os.exit(cmdStatus())
elseif command == "doctor" then
	os.exit(cmdDoctor())
elseif command == "update" then
	os.exit(cmdUpdate(arg[2] == "--check"))
elseif command == "ui" then
	os.exit(cmdUI(arg[2], arg[3]))
elseif command == "cloud" then
	local sub = arg[2]
	if sub == "setup" then os.exit(cmdCloudSetup())
	elseif sub == "push" then os.exit(cmdCloudPush())
	elseif sub == "pull" then os.exit(cmdCloudPull())
	elseif sub == "status" then os.exit(cmdCloudStatus())
	else os.exit(cmdCloud()) end
else
	usage()
	os.exit(command == nil and 0 or 1)
end
