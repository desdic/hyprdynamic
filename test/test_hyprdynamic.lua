-- Offline tests with a mocked `hl` API.  Run from repo root:  lua test/test_hyprdynamic.lua
package.preload["hyprdynamic"] = function()
	return dofile("init.lua")
end

local calls
local monitors
local workspaces
local handlers
local timers
local windows = {}
local named_rules = {}
-- optional workspace/focus simulation: { active = {mon -> ws}, owner = {"3" -> mon}, focused = mon }
local sim

-- Hyprland returns userdata: fields (and list items) only reachable via __index,
-- so `#`, pairs() and rawget() don't work on them. Proxies behave the same way.
local function proxy(t)
	return setmetatable({}, { __index = t })
end


local function sim_ws(id)
	local empty = sim.empty and sim.empty[id] or false
	return proxy({ id = tonumber(id), name = tostring(id), is_empty = empty, windows = empty and 0 or 1, special = false })
end

local function reset(mons, wss)
	sim = nil
	calls = { monitor = {}, monitor_order = {}, rule = {}, wrule = {}, move = {}, notify = {}, focus = {} }
	monitors = mons
	workspaces = wss or {}
	handlers = {}
	timers = {}
	windows = {}
	named_rules = {}
end

local function rule_handle(spec)
	return {
		spec = spec,
		enabled = true,
		set_enabled = function(self, v)
			self.enabled = v
		end,
	}
end

_G.hl = {
	get_monitors = function()
		return proxy(monitors)
	end,
	get_workspaces = function()
		if sim then
			local out = {}
			for id in pairs(sim.owner) do
				out[#out + 1] = sim_ws(id)
			end
			return proxy(out)
		end
		return workspaces
	end,
	monitor = function(spec)
		calls.monitor[spec.output] = spec
		calls.monitor_order[#calls.monitor_order + 1] = spec.output
	end,
	-- like Hyprland: a known name reuses (updates) the existing rule
	window_rule = function(spec)
		local h = spec.name and named_rules[spec.name]
		if h then
			h.spec = spec
			if spec.enabled ~= nil then
				h.enabled = spec.enabled
			end
			return h
		end
		h = rule_handle(spec)
		calls.wrule[#calls.wrule + 1] = h
		if spec.name then
			named_rules[spec.name] = h
		end
		return h
	end,
	get_windows = function()
		return proxy(windows)
	end,
	workspace_rule = function(spec)
		local h = rule_handle(spec)
		calls.rule[#calls.rule + 1] = h
		return h
	end,
	get_active_workspace = function(mon)
		if not sim then
			return nil
		end
		local id = sim.active[mon or sim.focused]
		return id and sim_ws(id) or nil
	end,
	dispatch = function(d)
		if d.kind == "focus" then
			calls.focus[#calls.focus + 1] = tostring(d.workspace)
			if sim then
				local id = tostring(d.workspace)
				-- like Hyprland: a new workspace is created on the monitor its rule binds it to
				local bound
				for _, r in ipairs(calls.rule) do
					if r.enabled and r.spec.workspace == id then
						bound = r.spec.monitor
					end
				end
				local mon = sim.owner[id] or bound or sim.focused
				sim.owner[id] = mon
				sim.active[mon] = id
				sim.focused = mon
				if handlers["workspace.active"] then
					handlers["workspace.active"]()
				end
			end
			return
		end
		calls.move[#calls.move + 1] = d
		-- like Hyprland: moving a hidden workspace doesn't make it visible
		if sim and d.kind == "workspace" then
			local old = sim.owner[d.workspace]
			sim.owner[d.workspace] = d.monitor
			if old and old ~= d.monitor and sim.active[old] == d.workspace then
				sim.active[old] = "6"
				sim.owner["6"] = old
				sim.empty = sim.empty or {}
				sim.empty["6"] = true
			end
		end
	end,
	dsp = {
		focus = function(a)
			a.kind = "focus"
			return a
		end,
		workspace = {
			move = function(a)
				a.kind = "workspace"
				return a
			end,
		},
		window = {
			move = function(a)
				a.kind = "window"
				-- apply it so later checks see the new state
				if a.workspace then
					a.window.workspace = { id = tonumber(a.workspace), name = a.workspace }
				end
				return a
			end,
		},
	},
	-- handlers[event]() runs every subscriber of that event
	on = function(event, cb)
		local list = rawget(handlers, event)
		if not list then
			list = setmetatable({}, {
				__call = function(self)
					for _, f in ipairs({ table.unpack(self) }) do
						f()
					end
				end,
			})
			handlers[event] = list
		end
		list[#list + 1] = cb
		return {
			remove = function()
				for i, f in ipairs(list) do
					if f == cb then
						table.remove(list, i)
						break
					end
				end
			end,
		}
	end,
	timer = function(cb, _)
		timers[#timers + 1] = cb
		return {}
	end,
	notification = {
		create = function(o)
			calls.notify[#calls.notify + 1] = o.text
		end,
	},
}

local LAPTOP = { name = "eDP-1", description = "Lenovo Group Limited 0x4146 foo" }
local LG = { name = "DP-3", description = "LG Electronics LG ULTRAGEAR 106NTQD8W884" }
local DL = { name = "DP-5", description = "Dell Inc. DELL U2722DE 78ML9H3" }
local DR = { name = "DP-6", description = "Dell Inc. DELL U2722DE 4M6LV83" }
local TV = { name = "HDMI-A-1", description = "Some TV" }

local function load_config()
	package.loaded["hyprdynamic"] = nil
	dofile("example.lua")
	return require("hyprdynamic")
end

-- enabled window rule with this name -> its spec (nil if none / several)
local function wrule(name)
	local found
	for _, r in ipairs(calls.wrule) do
		if r.enabled and r.spec.name == name then
			if found then
				return "duplicate"
			end
			found = r.spec
		end
	end
	return found
end

local function rules_for(mon)
	local out = {}
	for _, r in ipairs(calls.rule) do
		if r.enabled and r.spec.monitor == mon then
			out[#out + 1] = r.spec.workspace
		end
	end
	return table.concat(out, ",")
end

local failures = 0
local function check(name, cond)
	if cond then
		print("ok   " .. name)
	else
		print("FAIL " .. name)
		failures = failures + 1
	end
end

local function flush()
	local t = timers
	timers = {}
	for _, cb in ipairs(t) do
		cb()
	end
end

-- laptop only -> default
reset({ LAPTOP }, { { id = 1, name = "1" } })
local dm = load_config()
check("default selected", dm.current() == "default")
check("default laptop scale", calls.monitor["eDP-1"].scale == "2")
check("default workspaces 1-10 on laptop", rules_for("eDP-1") == "1,2,3,4,5,6,7,8,9,10")
check("config load does not move workspaces", #calls.move == 0)
handlers["hyprland.start"]()
handlers["monitor.added"]() -- coalesced; must not drop the startup flag
flush()
check("startup moves only the existing workspace", #calls.move == 1 and calls.move[1].workspace == "1")
check("startup is not a setup switch", dm.current() == "default" and #calls.notify == 1)
check("default: dino overridden to ws 9", wrule("dino").workspace == 9)
check("default: global tmux rule active", wrule("tmux").workspace == 3)
check("first ws is default rule", calls.rule[1].spec.default == true and calls.rule[2].spec.default == nil)

-- some open windows
local SPOTIFY = { class = "Spotify", title = "x", workspace = { id = 5, name = "5" } }
local TMUX = { class = "tmux", title = "t", workspace = { id = 3, name = "3" } }
local SCRATCH = { class = "spotify", title = "s", workspace = { id = -98, name = "special:magic", special = true } }
windows = { SPOTIFY, TMUX, SCRATCH }

local function window_moves()
	local out = {}
	for _, d in ipairs(calls.move) do
		if d.kind == "window" then
			out[#out + 1] = d
		end
	end
	return out
end

-- plug in LG -> home
monitors = { LAPTOP, LG }
handlers["monitor.added"]()
handlers["monitor.added"]() -- burst
check("debounced (not applied yet)", dm.current() == "default")
flush()
check("home selected", dm.current() == "home")
check("home LG mode", calls.monitor["DP-3"].mode == "3440x1440@85")
check("home ws on LG", rules_for("DP-3") == "1,2,3,4,5")
check("home ws on laptop", rules_for("eDP-1") == "8")
check("home: spotify overridden to ws 8", wrule("spotify").workspace == 8)
check("home: dino back to global ws 1", wrule("dino").workspace == 1)
check("home: no duplicate rules", wrule("tmux") ~= "duplicate" and wrule("spotify") ~= "duplicate")
check("home: open spotify moved to ws 8", SPOTIFY.workspace.id == 8)
check(
	"home: move is silent and targets the window",
	window_moves()[1].follow == false and window_moves()[1].window == SPOTIFY
)
check("home: tmux already right, not moved", TMUX.workspace.id == 3)
check("home: special-workspace window left alone", SCRATCH.workspace.special == true)
check("home: exactly one window moved", #window_moves() == 1)
check("notified", calls.notify[#calls.notify] == "hyprdynamic: setup 'home'")

-- reload with no change -> no re-apply
local n = #calls.rule
handlers["config.reloaded"]()
flush()
check("no-op on unchanged", #calls.rule == n)

-- office + unknown TV
monitors = { LAPTOP, DL, DR, TV }
handlers["monitor.added"]()
flush()
check("office selected", dm.current() == "office")
check("office left 1-3", rules_for("DP-5") == "1,2,3")
check("office right 4,5", rules_for("DP-6") == "4,5")
check("unknown TV gets fallback", calls.monitor["HDMI-A-1"] and calls.monitor["HDMI-A-1"].mode == "preferred")
check("office: spotify back to global ws 5", wrule("spotify").workspace == 5)
check("office: spotify moved back to ws 5", SPOTIFY.workspace.id == 5)
check("old home rules disabled", rules_for("DP-3") == "")

-- only one Dell -> default
monitors = { LAPTOP, DL }
handlers["monitor.removed"]()
flush()
check("partial office -> default", dm.current() == "default")

-- monitor alias resolution + disable via enabled = false
do
	reset({ LAPTOP, LG })
	package.loaded["hyprdynamic"] = nil
	local m = require("hyprdynamic")
	m.config({
		monitors = { laptop = { desc = "Lenovo" }, lg = { desc = "ULTRAGEAR" }, dell = { desc = "DELL" } },
		window_rules = {
			{ name = "a", match = { class = "a" }, monitor = "lg" },
			{ name = "b", match = { class = "b" }, monitor = "dell" },
			{ name = "c", match = { class = "c" }, float = true },
		},
		setups = {
			{ name = "s", requires = { "lg" }, window_rules = { { name = "c", enabled = false } } },
		},
		options = { notify = false, debounce_ms = 0 },
	})
	check("alias resolved in window rule", wrule("a") and wrule("a").monitor == "DP-3")
	check("rule for disconnected monitor skipped", wrule("b") == nil)
	check("enabled=false drops global rule", wrule("c") == nil)
end

local function fresh()
	package.loaded["hyprdynamic"] = nil
	return require("hyprdynamic")
end

-- outputs: fixed positions before "auto", deterministic order
do
	reset({ TV, LAPTOP, DL, DR })
	local m = fresh()
	m.config({
		monitors = { laptop = "Lenovo", dl = "78ML9H3", dr = "4M6LV83", tv = "Some TV" },
		setups = {
			{
				name = "s",
				requires = { "dl" },
				outputs = {
					tv = { position = "auto-right" },
					laptop = {},
					dr = { position = "2560x0" },
					dl = { position = "0x0" },
				},
			},
		},
		options = { notify = false, debounce_ms = 0 },
	})
	check("outputs: fixed first, then auto, alphabetical", table.concat(calls.monitor_order, ",") == "DP-5,DP-6,eDP-1,HDMI-A-1")
end

-- alias priority: specific desc wins over a generic one regardless of alias name
do
	reset({ LAPTOP, DL, DR })
	local m = fresh()
	m.config({
		monitors = {
			a_any_dell = { desc = "DELL" },
			dell_left = { desc = "DELL U2722DE 78ML9H3" },
			laptop = { name = "eDP-1" },
			broken = { match = function()
				error("boom")
			end },
		},
		setups = { { name = "office", requires = { "dell_left" } } },
		options = { notify = false, debounce_ms = 0 },
	})
	check("specific alias not stolen by generic one", m.current() == "office")
	check("generic alias gets the other Dell", m._internal.state ~= nil and m.status():find("DP%-6%s+a_any_dell") ~= nil)
	check("erroring match() doesn't break apply", m.current() == "office")
end

-- reloads keep manual workspace moves; monitor changes and explicit applies move
do
	reset({ LAPTOP, LG }, { { id = 1, name = "1" } })
	local m = fresh()
	local cfg = {
		monitors = { laptop = "Lenovo", lg = "ULTRAGEAR", tv = "Some TV" },
		setups = {
			{ name = "home", requires = { "lg" }, workspaces = { lg = { 1 }, tv = { 2 } } },
		},
		options = { notify = false, debounce_ms = 0 },
	}
	m.config(cfg)
	local before = #calls.move
	m.config(cfg) -- config reload with the module state kept
	check("reload: no workspace moves", #calls.move == before)
	handlers["config.reloaded"]()
	check("reload event: no workspace moves", #calls.move == before)
	monitors = { LAPTOP, LG, TV }
	handlers["monitor.added"]()
	check("monitor change in same setup moves workspaces", #calls.move > before)
	before = #calls.move
	m.apply({ force = true })
	check("explicit apply moves workspaces", #calls.move > before)
end

-- dynamic workspace targets are not used for moving windows
do
	reset({ LAPTOP })
	local m = fresh()
	m.config({
		monitors = { laptop = "Lenovo", lg = "ULTRAGEAR" },
		window_rules = {
			{ name = "fixed", match = { class = "foo" }, workspace = 4 },
			{ name = "dyn", match = { class = "foo" }, workspace = "empty" },
			{ name = "named", match = { class = "bar" }, workspace = "name:chat silent" },
		},
		setups = { { name = "home", requires = { "lg" } } },
		options = { notify = false, debounce_ms = 0 },
	})
	local FOO = { class = "foo", workspace = { id = 1, name = "1" } }
	local BAR = { class = "bar", workspace = { id = 1, name = "1" } }
	windows = { FOO, BAR }
	monitors = { LAPTOP, LG }
	handlers["monitor.added"]()
	check("dynamic last rule leaves window alone", FOO.workspace.id == 1)
	check("name: target still moves", BAR.workspace.name == "name:chat")
end

-- no monitors during config load: nothing applied, first real apply isn't a switch
do
	reset({})
	local m = fresh()
	local changes = {}
	m.config({
		monitors = { laptop = "Lenovo" },
		setups = {},
		default = { workspaces = { laptop = "1-3" } },
		options = {
			notify = false,
			debounce_ms = 0,
			on_change = function(old, new)
				changes[#changes + 1] = tostring(old) .. ">" .. tostring(new)
			end,
		},
	})
	check("no monitors: nothing applied", m.current() == nil and #calls.rule == 0)
	monitors = { { name = "FALLBACK", description = "" } }
	handlers["monitor.added"]()
	check("FALLBACK output ignored", m.current() == nil and calls.monitor["FALLBACK"] == nil)
	monitors = { LAPTOP }
	handlers["hyprland.start"]()
	check("first real apply reported as initial", m.current() == "default" and changes[1] == "nil>default")
end

-- Unplug / re-plug, replaying the event sequence recorded from Hyprland:
--  unplug: Hyprland moves DP-3's workspaces to the laptop and focuses the
--          laptop (showing empty 6) *before* monitor.removed fires
--  replug: Hyprland moves them back and focuses 3, then the old setup's rules
--          (1-10 on the laptop) pull them back; DP-3 gets stray workspace 11
do
	reset({ LAPTOP, LG }, {})
	local m = fresh()
	local cfg = {
		monitors = { laptop = "Lenovo", lg = "ULTRAGEAR" },
		setups = { { name = "home", requires = { "lg" }, workspaces = { lg = { 1, 2, 3, 4, 5 }, laptop = { 8 } } } },
		default = { workspaces = { laptop = "1-10" } },
		options = { notify = false, debounce_ms = 0 },
	}
	sim = {
		active = { ["eDP-1"] = "6", ["DP-3"] = "3" },
		owner = { ["1"] = "DP-3", ["2"] = "DP-3", ["3"] = "DP-3", ["4"] = "DP-3", ["5"] = "DP-3", ["6"] = "eDP-1" },
		focused = "DP-3",
		empty = { ["6"] = true },
	}
	m.config(cfg)
	flush()
	check("initial focus tracked", m._internal.state.focus == "3")

	-- unplug
	for _, id in ipairs({ "1", "2", "3", "4", "5" }) do
		sim.owner[id] = "eDP-1"
	end
	sim.active["DP-3"] = nil
	sim.focused = "eDP-1"
	handlers["monitor.focused"]()
	monitors = { LAPTOP }
	handlers["monitor.removed"]()
	flush()
	flush()
	check("unplug: switched to default", m.current() == "default")
	check("unplug: focus tracking ignored Hyprland's reshuffle", m._internal.state.focus == "3")
	check("unplug: back on ws 3", sim.focused == "eDP-1" and sim.active["eDP-1"] == "3")
	flush() -- commit our own focus change

	-- replug
	monitors = { LAPTOP, LG }
	for _, id in ipairs({ "1", "2", "3", "4", "5" }) do
		sim.owner[id] = "eDP-1"
	end
	sim.active["DP-3"] = "11"
	sim.owner["11"] = "DP-3"
	sim.empty["11"] = true
	sim.focused = "DP-3"
	handlers["monitor.added"]()
	handlers["monitor.focused"]()
	flush()
	flush()
	check("replug: switched to home", m.current() == "home")
	check("replug: LG no longer shows stray ws 11", sim.active["DP-3"] == "3")
	check("replug: focus back on ws 3", sim.focused == "DP-3")
	check("replug: laptop shows its own ws 8", sim.active["eDP-1"] == "8")
	local refocused_11 = false
	for _, f in ipairs(calls.focus) do
		refocused_11 = refocused_11 or f == "11"
	end
	check("replug: stray ws 11 never focused", not refocused_11)
end

-- hl.monitor() is skipped for a monitor that already runs as configured
do
	local LIVE_LG = {
		name = "DP-3",
		description = "LG Electronics LG ULTRAGEAR 106NTQD8W884",
		width = 3440,
		height = 1440,
		refresh_rate = 84.99,
		x = 2560,
		y = 160,
		scale = 1,
		enabled = true,
	}
	reset({ LAPTOP, LIVE_LG })
	local m = fresh()
	m.config({
		monitors = { laptop = "Lenovo", lg = "ULTRAGEAR" },
		setups = {
			{
				name = "home",
				requires = { "lg" },
				outputs = {
					laptop = { mode = "3840x2400@60", position = "0x0", scale = 1.5 },
					lg = { mode = "3440x1440@85", position = "2560x160", scale = 1 },
				},
			},
		},
		options = { notify = false, debounce_ms = 0 },
	})
	check("first apply configures the LG", calls.monitor["DP-3"] ~= nil)
	calls.monitor = {}
	m.apply({ force = true })
	check("unchanged LG is not reconfigured", calls.monitor["DP-3"] == nil)
	check("laptop (state unknown) is still configured", calls.monitor["eDP-1"] ~= nil)
	LIVE_LG.refresh_rate = 50
	calls.monitor = {}
	m.apply({ force = true })
	check("LG running a different mode is reconfigured", calls.monitor["DP-3"] ~= nil)
	LIVE_LG.refresh_rate = 85
	m.config({
		monitors = { laptop = "Lenovo", lg = "ULTRAGEAR" },
		setups = { { name = "home", requires = { "lg" }, outputs = { lg = { mode = "3440x1440@85", position = "2560x160", scale = 1 } } } },
		options = { notify = false, debounce_ms = 0 },
	})
	check("config reload re-sends monitor rules", calls.monitor["DP-3"] ~= nil)
end

-- loop guard: a monitor that keeps dropping and coming back pauses hyprdynamic
do
	reset({ LAPTOP, LG })
	local m = fresh()
	m.config({
		monitors = { laptop = "Lenovo", lg = "ULTRAGEAR" },
		setups = { { name = "home", requires = { "lg" }, outputs = { lg = { mode = "3440x1440@85" } } } },
		options = { notify = false, debounce_ms = 0, guard_max_events = 4 },
	})
	local st = m._internal.state
	for i = 1, 4 do
		monitors = (i % 2 == 1) and { LAPTOP } or { LAPTOP, LG }
		handlers[(i % 2 == 1) and "monitor.removed" or "monitor.added"]()
	end
	check("guard: 4 events still applied", not st.paused and m.current() == "home")
	monitors = { LAPTOP }
	calls.monitor = {}
	handlers["monitor.removed"]()
	check("guard: 5th event pauses", st.paused and m.current() == "home" and next(calls.monitor) == nil)
	monitors = { LAPTOP, LG }
	handlers["monitor.added"]()
	monitors = { LAPTOP }
	handlers["monitor.removed"]()
	check("guard: still paused while events keep coming", st.paused and m.current() == "home")
	-- only the timer from the last event may resume
	local t = timers
	timers = {}
	for i = 1, #t - 1 do
		t[i]()
	end
	check("guard: earlier timers don't resume", st.paused)
	t[#t]()
	check("guard: resumes after a quiet window and applies", not st.paused and m.current() == "default")
end

-- log_file: debug lines and warnings go to a file, which is rotated when too big
do
	local path = os.tmpname()
	os.remove(path)
	reset({ LAPTOP })
	local m = fresh()
	m.config({
		monitors = { laptop = "Lenovo" },
		setups = { { name = "home", requires = { "bogus" } } },
		options = { notify = false, debounce_ms = 0, log_file = path, log_file_max_kb = 1 },
	})
	local f = io.open(path)
	local text = f and f:read("a") or ""
	if f then
		f:close()
	end
	check("log_file: debug lines written", text:find("applying setup 'default' %(connected: eDP%-1%)") ~= nil)
	check("log_file: warnings written", text:find("WARNING: setup 'home'.requires: unknown monitor alias 'bogus'") ~= nil)
	check("log_file: lines are timestamped", text:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ") ~= nil)
	for _ = 1, 20 do
		m.apply({ force = true })
	end
	local rotated = io.open(path .. ".1")
	check("log_file: rotated past log_file_max_kb", rotated ~= nil)
	if rotated then
		rotated:close()
	end
	os.remove(path)
	os.remove(path .. ".1")
end

local rx = dm._internal.regex_match
check("regex full match", rx("^[Ss]potify$", "spotify") == true and rx("potify", "spotify") == false)
check(
	"regex alternation group",
	rx("(google-)?chrome|chromium", "google-chrome")
		and rx("(google-)?chrome|chromium", "chrome")
		and rx("(google-)?chrome|chromium", "chromium")
)
check("regex .* and escapes", rx("chrome-.*\\.slack\\.com.*", "chrome-group-onecom.slack.com__-Profile_1") == true)
check("regex literal dash/percent", rx("a-b%c", "a-b%c") == true)
check("regex unsupported -> nil", rx("a{2}", "aa") == nil)

check("range expand", table.concat(dm._internal.expand_workspaces({ 1, "3-5", "name:x" }), ",") == "1,3,4,5,name:x")

do
	check("api check: mock has full API", #dm._internal.missing_api() == 0)
	local saved_rule, saved_move = hl.workspace_rule, hl.dsp.window.move
	hl.workspace_rule, hl.dsp.window.move = nil, nil
	local missing = table.concat(dm._internal.missing_api(), ",")
	check("api check: reports missing functions", missing == "hl.workspace_rule,hl.dsp.window.move")
	reset({ LAPTOP })
	local ok = pcall(dm.config, { monitors = { laptop = { name = "eDP-1" } }, default = {} })
	check("api check: config doesn't crash", ok)
	check("api check: nothing applied", next(calls.monitor) == nil and dm._internal.state.config == nil)
	check("api check: warns", #calls.notify > 0 and calls.notify[#calls.notify]:find("hl.workspace_rule", 1, true) ~= nil)
	hl.workspace_rule, hl.dsp.window.move = saved_rule, saved_move
end

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
