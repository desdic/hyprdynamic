-- hyprdynamic: dynamic monitor & workspace layouts for Hyprland (Lua config)
--
-- Picks a "setup" based on which monitors are connected, applies monitor
-- layouts and workspace rules for it, and moves open workspaces to the right
-- monitor. Re-evaluates on monitor hotplug, config reload and startup.
--
-- Usage:
--   local hyprdynamic = require("hyprdynamic")
--   hyprdynamic.config({ monitors = {...}, setups = {...}, default = {...}, options = {...} })
--
-- See README.md / example.lua for the full config format.

local M = {}

local defaults = {
	events = { "monitor.added", "monitor.removed", "config.reloaded", "hyprland.start" },
	move_existing = true, -- move already-open workspaces to their assigned monitor
	default_rule = true, -- first workspace in each monitor's list gets `default = true`
	debounce_ms = 300, -- coalesce bursts of hotplug events (docks); 0 = apply immediately
	notify = true, -- show a Hyprland notification when the setup changes
	notify_timeout = 3000,
	log = false, -- print debug output (visible in the Hyprland log)
	log_file = false, -- also write debug output and warnings to this file, e.g. "~/.cache/hyprdynamic.log"
	log_file_max_kb = 1024, -- when the file grows past this, it is moved to <log_file>.1 and a new one started
	on_change = nil, -- function(old_name, new_name, ctx)
	move_windows = true, -- on setup change, move open windows to the workspace/monitor their window rule now says
	match_mode = "full", -- how window rule regexes are matched when moving windows: "full" or "partial"
	settle_ms = 100, -- after moving workspaces, wait this long before fixing up what each monitor shows
	focus_settle_ms = 500, -- a focus change counts only if no hotplug follows within this time
	guard_max_events = 8, -- more monitor hotplug events than this within guard_window_ms pauses hyprdynamic; 0 = off
	guard_window_ms = 30000,
}

local state = {
	config = nil,
	opts = nil,
	subscriptions = {},
	rules = {}, -- workspace rule handles created by the last apply
	window_rules = {}, -- window rule handles created by the last apply
	signature = nil, -- identifies the last applied state, to skip no-op re-applies
	monitors_sig = nil, -- connected monitors at the last apply
	setup_name = nil,
	generation = 0, -- debounce token
	pending = nil, -- merged options of scheduled-but-not-yet-run applies
	focus = nil, -- workspace the user was last on (see track_focus)
	focus_gen = 0,
	hotplug = 0, -- bumped on every monitor added/removed
	hotplug_times = {}, -- os.time() of recent hotplug events (loop guard)
	paused = false, -- loop guard tripped: event-driven applies are skipped
	guard_gen = 0,
	applied = {}, -- output name -> spec key of the last hl.monitor() we sent for it
}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local log_file_failed = nil -- path we couldn't open; warn once per path

--- Append a line to `log_file`, if set. Survives reboots, unlike Hyprland's
--- own log in $XDG_RUNTIME_DIR.
local function write_log_file(line)
	local path = state.opts and state.opts.log_file
	if type(path) ~= "string" or path == "" then
		return
	end
	if path:sub(1, 2) == "~/" then
		path = (os.getenv("HOME") or "") .. path:sub(2)
	end

	local f = io.open(path, "a")
	if not f then
		if log_file_failed ~= path then
			log_file_failed = path
			print("[hyprdynamic] WARNING: cannot open log_file " .. path)
		end
		return
	end
	local size = f:seek("end")
	if size and size > (state.opts.log_file_max_kb or 1024) * 1024 then
		f:close()
		os.remove(path .. ".1")
		os.rename(path, path .. ".1")
		f = io.open(path, "a")
		if not f then
			return
		end
	end
	f:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
	f:close()
end

local function log(fmt, ...)
	if not state.opts then
		return
	end
	local file = state.opts.log_file
	if not (state.opts.log or file) then
		return
	end
	local line = string.format(fmt, ...)
	if state.opts.log then
		print("[hyprdynamic] " .. line)
	end
	write_log_file(line)
end

local function notify(text, color)
	if not (state.opts and state.opts.notify) then
		return
	end
	pcall(hl.notification.create, {
		text = "hyprdynamic: " .. text,
		timeout = state.opts.notify_timeout,
		color = color,
	})
end

local function warn(fmt, ...)
	local msg = string.format(fmt, ...)
	print("[hyprdynamic] WARNING: " .. msg)
	write_log_file("WARNING: " .. msg)
	if state.opts and state.opts.notify then
		pcall(hl.notification.create, {
			text = "hyprdynamic: " .. msg,
			timeout = 8000,
			color = "rgba(ff5555ff)",
		})
	end
end

local function merge(base, over)
	local out = {}
	for k, v in pairs(base or {}) do
		out[k] = v
	end
	for k, v in pairs(over or {}) do
		out[k] = v
	end
	return out
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

--- Call an `hl` getter and copy its result into a plain Lua list. Hyprland
--- returns userdata objects, so instead of type checks this just tries to
--- iterate the result. Returns nil if the call or the iteration fails.
local function hl_list(fn, ...)
	local ok, res = pcall(fn, ...)
	if not ok or res == nil then
		return nil
	end
	local copied, out = pcall(function()
		local t = {}
		for _, v in ipairs(res) do
			t[#t + 1] = v
		end
		return t
	end)
	return copied and out or nil
end

--- Expand a workspace spec into a list of workspace identifiers (strings).
--- Accepts: 3, "3", "1-5", "name:music", "special:scratch", or a list of those.
local function expand_workspaces(spec)
	local out = {}
	local function add(item)
		if type(item) == "number" then
			out[#out + 1] = tostring(math.floor(item))
		elseif type(item) == "string" then
			local a, b = item:match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
			if a then
				a, b = tonumber(a), tonumber(b)
				local step = a <= b and 1 or -1
				for i = a, b, step do
					out[#out + 1] = tostring(i)
				end
			else
				out[#out + 1] = item
			end
		elseif type(item) == "table" then
			for _, v in ipairs(item) do
				add(v)
			end
		end
	end
	add(spec)
	return out
end

---------------------------------------------------------------------------
-- monitor discovery
---------------------------------------------------------------------------

--- Does a connected monitor match an alias definition?
local function matches(mon, def)
	if def.name and mon.name == def.name then
		return true
	end
	if def.desc and mon.description and mon.description:find(def.desc, 1, true) then
		return true
	end
	if def.match then
		local ok, res = pcall(def.match, mon)
		if not ok then
			warn("monitor match() failed for %s: %s", tostring(mon.name), tostring(res))
			return false
		end
		if res then
			return true
		end
	end
	return false
end

--- How specific an alias definition is: `name` beats `desc`, a longer `desc`
--- beats a shorter one, and a `match` function comes last. More specific
--- aliases claim their monitor first, so a generic `desc = "DELL"` alias can't
--- steal the monitor of a `desc = "DELL U2722DE 78ML9H3"` alias.
local function alias_priority(def)
	if def.name then
		return math.huge
	end
	if def.desc then
		return #def.desc
	end
	return -1
end

local function aliases_by_priority(defs)
	local keys = sorted_keys(defs)
	local prio = {}
	for _, k in ipairs(keys) do
		prio[k] = alias_priority(defs[k])
	end
	table.sort(keys, function(a, b)
		if prio[a] ~= prio[b] then
			return prio[a] > prio[b]
		end
		return a < b
	end)
	return keys
end

--- Build the context: which aliases are connected and which monitor each maps to.
local function build_context()
	-- all = true so monitors we disabled ourselves still count as connected
	local raw = hl_list(hl.get_monitors, { all = true }) or hl_list(hl.get_monitors) or {}

	-- Hyprland adds a FALLBACK output when nothing is connected; it isn't a real monitor
	local monitors = {}
	for _, mon in ipairs(raw) do
		if mon.name ~= "FALLBACK" then
			monitors[#monitors + 1] = mon
		end
	end

	local ctx = {
		monitors = monitors, -- raw HL.Monitor list
		connected = {}, -- alias -> true
		by_alias = {}, -- alias -> HL.Monitor
		unmatched = {}, -- HL.Monitor[] not matched by any alias
	}

	local claimed = {}
	for _, alias in ipairs(aliases_by_priority(state.config.monitors)) do
		local def = state.config.monitors[alias]
		for _, mon in ipairs(monitors) do
			if not claimed[mon.name] and matches(mon, def) then
				ctx.connected[alias] = true
				ctx.by_alias[alias] = mon
				claimed[mon.name] = true
				break
			end
		end
	end

	for _, mon in ipairs(monitors) do
		if not claimed[mon.name] then
			ctx.unmatched[#ctx.unmatched + 1] = mon
		end
	end

	return ctx
end

---------------------------------------------------------------------------
-- setup selection
---------------------------------------------------------------------------

local function setup_matches(setup, ctx)
	for _, alias in ipairs(setup.requires or {}) do
		if not ctx.connected[alias] then
			return false
		end
	end

	if setup.requires_any and #setup.requires_any > 0 then
		local any = false
		for _, alias in ipairs(setup.requires_any) do
			if ctx.connected[alias] then
				any = true
				break
			end
		end
		if not any then
			return false
		end
	end

	for _, alias in ipairs(setup.excludes or {}) do
		if ctx.connected[alias] then
			return false
		end
	end

	if setup.when then
		local ok, res = pcall(setup.when, ctx)
		if not ok then
			warn("setup '%s': when() failed: %s", tostring(setup.name), tostring(res))
			return false
		end
		if not res then
			return false
		end
	end

	return true
end

local function pick_setup(ctx)
	for _, setup in ipairs(state.config.setups) do
		if setup_matches(setup, ctx) then
			return setup
		end
	end
	return state.config.default
end

---------------------------------------------------------------------------
-- applying
---------------------------------------------------------------------------

local function to_monitor_spec(output, spec)
	local out = { output = output }
	for k, v in pairs(spec) do
		if k == "scale" and type(v) == "number" then
			out.scale = tostring(v)
		else
			out[k] = v
		end
	end
	if not out.disabled then
		out.mode = out.mode or "preferred"
		out.position = out.position or "auto"
		out.scale = out.scale or "auto"
	end
	return out
end

--- Identifies the set of connected monitors.
local function monitors_signature(ctx)
	local parts = {}
	for _, mon in ipairs(ctx.monitors) do
		parts[#parts + 1] = mon.name .. "=" .. (mon.description or "")
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

--- Order in which a setup's outputs are applied: aliases with an explicit
--- position first, then those placed automatically (Hyprland positions an
--- "auto" monitor relative to the ones already laid out), alphabetical within
--- each group so the result is the same on every apply.
local function output_order(outputs)
	local fixed, auto = {}, {}
	for _, alias in ipairs(sorted_keys(outputs)) do
		local pos = outputs[alias].position
		if pos == nil or tostring(pos):match("^auto") then
			auto[#auto + 1] = alias
		else
			fixed[#fixed + 1] = alias
		end
	end
	for _, alias in ipairs(auto) do
		fixed[#fixed + 1] = alias
	end
	return fixed
end

local function disable_all(handles)
	for _, rule in ipairs(handles) do
		pcall(function()
			rule:set_enabled(false)
		end)
	end
end

local function clear_rules()
	disable_all(state.rules)
	state.rules = {}
end

local function spec_key(ms)
	local parts = {}
	for _, k in ipairs(sorted_keys(ms)) do
		parts[#parts + 1] = k .. "=" .. tostring(ms[k])
	end
	return table.concat(parts, ";")
end

--- Is the monitor already running the way `ms` says? Only checks what can be
--- read back (mode, position, scale, transform, enabled); "preferred",
--- "auto" and the like count as matching.
local function monitor_matches(mon, ms)
	local ok, res = pcall(function()
		if ms.disabled then
			return mon.enabled == false
		end
		if mon.enabled == false then
			return false
		end
		local w, h, r = tostring(ms.mode or ""):match("^(%d+)x(%d+)@?([%d%.]*)")
		if w then
			if tonumber(w) ~= mon.width or tonumber(h) ~= mon.height then
				return false
			end
			if r ~= "" and math.abs(tonumber(r) - (mon.refresh_rate or 0)) > 1 then
				return false
			end
		end
		local x, y = tostring(ms.position or ""):match("^(%-?%d+)x(%-?%d+)$")
		if x and (tonumber(x) ~= mon.x or tonumber(y) ~= mon.y) then
			return false
		end
		local scale = tonumber(ms.scale)
		if scale and math.abs(scale - (mon.scale or 0)) > 0.01 then
			return false
		end
		if tonumber(ms.transform) and tonumber(ms.transform) ~= mon.transform then
			return false
		end
		return true
	end)
	return ok and res == true
end

--- hl.monitor(), unless we already sent this exact spec and the monitor is
--- running that way: every hl.monitor() can make Hyprland reconfigure the
--- output, and some monitors drop their link (and blink) when that happens.
local function apply_monitor(label, mon, ms)
	local key = spec_key(ms)
	if state.applied[mon.name] == key and monitor_matches(mon, ms) then
		log("monitor %s (%s): already configured, skipped", label, mon.name)
		return
	end
	log(
		"monitor %s (%s): %s %s x%s%s",
		label,
		mon.name,
		tostring(ms.mode),
		tostring(ms.position),
		tostring(ms.scale),
		ms.disabled and " [disabled]" or ""
	)
	local ok, err = pcall(hl.monitor, ms)
	if ok then
		state.applied[mon.name] = key
	else
		state.applied[mon.name] = nil
		warn("hl.monitor failed for '%s': %s", label, tostring(err))
	end
end

local function apply_outputs(setup, ctx)
	local configured = {}
	local outputs = setup.outputs or {}

	for _, alias in ipairs(output_order(outputs)) do
		local spec = outputs[alias]
		local mon = ctx.by_alias[alias]
		if mon then
			configured[mon.name] = true
			apply_monitor(alias, mon, to_monitor_spec(mon.name, spec))
		elseif not state.config.monitors[alias] then
			warn("setup '%s' references unknown monitor alias '%s'", tostring(setup.name), alias)
		end
	end

	-- anything connected that this setup doesn't configure
	local unknown = setup.unknown or state.config.default.unknown or {}
	for _, mon in ipairs(ctx.monitors) do
		if not configured[mon.name] then
			apply_monitor("(unconfigured)", mon, to_monitor_spec(mon.name, unknown))
		end
	end
end

local function existing_workspaces()
	local set = {}
	local list = hl_list(hl.get_workspaces)
	if list then
		for _, ws in ipairs(list) do
			if ws.id then
				set[tostring(ws.id)] = true
			end
			if ws.name then
				set[ws.name] = true
				set["name:" .. ws.name] = true
			end
		end
	end
	return set
end

--- Identifier we use for a workspace: "3" for numbered, "name:x" for named.
local function ws_ident(ws)
	if not ws then
		return nil
	end
	if ws.id and ws.id > 0 then
		return tostring(ws.id)
	end
	if ws.name and ws.name ~= "" then
		return "name:" .. ws.name
	end
	return nil
end

local function ws_in(ws, set)
	if not ws then
		return false
	end
	return (ws.id and set[tostring(ws.id)]) or (ws.name and (set[ws.name] or set["name:" .. ws.name])) or false
end

local function active_workspace(monitor)
	local ok, ws
	if monitor then
		ok, ws = pcall(hl.get_active_workspace, monitor)
	else
		ok, ws = pcall(hl.get_active_workspace)
	end
	if ok then
		return ws
	end
	return nil
end

local function focus_workspace(ident)
	pcall(hl.dispatch, hl.dsp.focus({ workspace = tonumber(ident) or ident }))
end

--- Snapshot of what is on screen before workspaces get moved around.
local function visible_snapshot(ctx)
	local snap = { focused = ws_ident(active_workspace()), visible = {} }
	for _, mon in ipairs(ctx.monitors) do
		local id = ws_ident(active_workspace(mon.name))
		if id then
			snap.visible[id] = true
		end
	end
	return snap
end

--- Run `fn` after `ms` milliseconds (right away if timers aren't available).
local function after(ms, fn)
	if ms <= 0 or not pcall(hl.timer, fn, { timeout = ms, type = "oneshot" }) then
		fn()
	end
end

--- Remember which workspace the user is on. Hyprland reshuffles workspaces
--- and focus itself around a hotplug — partly *before* the monitor.removed /
--- monitor.added event arrives — so a focus change only counts once it has
--- stood for `focus_settle_ms` without a hotplug in between.
local function track_focus()
	local ws = active_workspace()
	if not ws or ws.special then
		return
	end
	local id = ws_ident(ws)
	state.focus_gen = state.focus_gen + 1
	local gen, hotplug = state.focus_gen, state.hotplug
	after(state.opts.focus_settle_ms or 0, function()
		if gen == state.focus_gen and hotplug == state.hotplug then
			state.focus = id
		end
	end)
end

--- When a monitor is plugged in, Hyprland gives it a workspace before we get
--- to apply the new setup — with the old setup's rules active that is the
--- first unbound ID (e.g. 11). Moving our workspaces to the monitor doesn't
--- make them visible, so the monitor keeps showing that stray workspace.
--- Switch such monitors to one of their own workspaces (preferring the one the
--- user was on, then one that was on screen), then give focus back to the
--- workspace the user was on.
local function fix_visible_workspaces(assigned, snap)
	local focus = state.focus or snap.focused
	for _, entry in ipairs(assigned) do
		local ws = active_workspace(entry.mon.name)
		local stray = ws and not ws.special and not ws_in(ws, entry.set) and (ws.is_empty or ws.windows == 0)
		if stray then
			local target
			if focus and entry.set[focus] then
				target = focus
			else
				for _, id in ipairs(entry.list) do
					if snap.visible[id] then
						target = id
						break
					end
				end
			end
			target = target or entry.list[1]
			log("monitor %s shows workspace %s; switching to %s", entry.mon.name, tostring(ws_ident(ws)), target)
			focus_workspace(target)
			-- focus was on the stray workspace (it gets destroyed): keep it on this monitor
			if focus == ws_ident(ws) then
				focus = target
			end
		end
	end

	if focus and existing_workspaces()[focus] and ws_ident(active_workspace()) ~= focus then
		log("restore focus to workspace %s", focus)
		focus_workspace(focus)
	end
end

local function apply_workspaces(setup, ctx, move)
	clear_rules()

	local opts = state.opts
	local existing = move and existing_workspaces() or {}
	local snap = move and visible_snapshot(ctx) or nil
	local assigned = {} -- { mon, list, set } per monitor that got workspaces
	local outputs = setup.outputs or {}

	for _, alias in ipairs(sorted_keys(setup.workspaces or {})) do
		local mon = ctx.by_alias[alias]
		local out_spec = outputs[alias]
		if not mon then
			log("workspaces for '%s' skipped: not connected", alias)
		elseif out_spec and out_spec.disabled then
			warn("setup '%s' assigns workspaces to disabled monitor '%s'", tostring(setup.name), alias)
		else
			local list = expand_workspaces(setup.workspaces[alias])
			local set = {}
			for _, ws in ipairs(list) do
				set[ws] = true
			end
			if #list > 0 then
				assigned[#assigned + 1] = { mon = mon, list = list, set = set }
			end
			for i, ws in ipairs(list) do
				local ok, rule = pcall(hl.workspace_rule, {
					workspace = ws,
					monitor = mon.name,
					default = opts.default_rule and i == 1 or nil,
				})
				if ok and rule then
					state.rules[#state.rules + 1] = rule
				elseif not ok then
					warn("workspace_rule %s -> %s failed: %s", ws, mon.name, tostring(rule))
				end

				if move and existing[ws] then
					log("move workspace %s -> %s", ws, mon.name)
					pcall(hl.dispatch, hl.dsp.workspace.move({ workspace = ws, monitor = mon.name }))
				end
			end
		end
	end

	if move then
		-- let Hyprland finish processing the moves first
		after(opts.settle_ms or 0, function()
			fix_visible_workspaces(assigned, snap)
		end)
	end
end

--- Merge global window rules with the setup's: a setup rule whose `name`
--- matches a global rule replaces it; `{ name = "x", enabled = false }`
--- drops it for this setup. Unnamed rules are always appended.
local function merged_window_rules(setup)
	local list, index = {}, {}
	local function add(rule)
		if rule.name and index[rule.name] then
			list[index[rule.name]] = rule
		else
			list[#list + 1] = rule
			if rule.name then
				index[rule.name] = #list
			end
		end
	end
	for _, rule in ipairs(state.config.window_rules or {}) do
		add(rule)
	end
	for _, rule in ipairs(setup.window_rules or {}) do
		add(rule)
	end
	return list
end

--- Returns the list of resolved rule specs that are active for this setup.
--- Hyprland reuses an existing rule when `hl.window_rule` gets a `name` it has
--- seen before, so named rules are updated in place (and explicitly enabled);
--- only rules that are no longer active get disabled.
local function apply_window_rules(setup, ctx)
	local old = state.window_rules
	state.window_rules = {}
	local active_specs = {}
	local kept = {}

	for _, rule in ipairs(merged_window_rules(setup)) do
		local spec = merge(rule)
		local skip = spec.enabled == false

		-- `monitor = "<alias>"` -> real output name; skip if not connected
		if not skip and type(spec.monitor) == "string" and state.config.monitors[spec.monitor] then
			local mon = ctx.by_alias[spec.monitor]
			if mon then
				spec.monitor = mon.name
			else
				log("window rule '%s' skipped: monitor '%s' not connected", tostring(spec.name), rule.monitor)
				skip = true
			end
		end

		if not skip then
			spec.enabled = true
			local ok, handle = pcall(hl.window_rule, spec)
			if ok and handle then
				pcall(function()
					handle:set_enabled(true)
				end)
				state.window_rules[#state.window_rules + 1] = { name = spec.name, handle = handle }
				active_specs[#active_specs + 1] = spec
				if spec.name then
					kept[spec.name] = true
				end
			elseif not ok then
				warn("window_rule '%s' failed: %s", tostring(spec.name), tostring(handle))
			end
		end
	end

	for _, entry in ipairs(old) do
		if not (entry.name and kept[entry.name]) then
			pcall(function()
				entry.handle:set_enabled(false)
			end)
		end
	end

	return active_specs
end

---------------------------------------------------------------------------
-- moving existing windows
---------------------------------------------------------------------------

-- Translate a (subset of) RE2 regex into a list of Lua patterns (alternatives).
-- Supports: literals, ., [classes], \d \w \s \D \W \S, escaped punctuation,
-- * + ? (also lazy), ^ / $ at the ends, | and (groups) incl. (?:...) and (...)?
-- Returns nil, err for anything else ({n,m}, backrefs, quantified groups, ...).
local MAX_ALTERNATIVES = 64

local function split_top(s, sep)
	local parts, depth, start, i = {}, 0, 1, 1
	local in_class = false
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 1
		elseif in_class then
			if c == "]" then
				in_class = false
			end
		elseif c == "[" then
			in_class = true
			if s:sub(i + 1, i + 1) == "^" then
				i = i + 1
			end
			if s:sub(i + 1, i + 1) == "]" then
				i = i + 1
			end
		elseif c == "(" then
			depth = depth + 1
		elseif c == ")" then
			depth = depth - 1
		elseif c == sep and depth == 0 then
			parts[#parts + 1] = s:sub(start, i - 1)
			start = i + 1
		end
		i = i + 1
	end
	parts[#parts + 1] = s:sub(start)
	return parts
end

local ESCAPES = { d = "%d", D = "%D", s = "%s", S = "%S", w = "[%w_]", W = "[^%w_]" }
local CLASS_ESCAPES = { d = "%d", D = "%D", s = "%s", S = "%S", w = "%w_" }

local function escape_atom(c, in_class)
	local map = in_class and CLASS_ESCAPES or ESCAPES
	if map[c] then
		return map[c]
	end
	if c:match("%w") then
		return nil
	end
	return "%" .. c
end

local parse_alt

local function parse_seq(s)
	local acc = { "" }
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		local atom, alts

		if c == "(" then
			local depth, j = 1, i + 1
			while j <= #s and depth > 0 do
				local d = s:sub(j, j)
				if d == "\\" then
					j = j + 1
				elseif d == "(" then
					depth = depth + 1
				elseif d == ")" then
					depth = depth - 1
				end
				j = j + 1
			end
			if depth ~= 0 then
				return nil, "unbalanced ("
			end
			local inner = s:sub(i + 1, j - 2)
			if inner:sub(1, 2) == "?:" then
				inner = inner:sub(3)
			elseif inner:sub(1, 1) == "?" then
				return nil, "unsupported group (" .. inner:sub(1, 2)
			end
			local err
			alts, err = parse_alt(inner)
			if not alts then
				return nil, err
			end
			i = j
			local q = s:sub(i, i)
			if q == "?" then
				alts[#alts + 1] = ""
				i = i + 1
				if s:sub(i, i) == "?" then
					i = i + 1
				end
			elseif q == "*" or q == "+" or q == "{" then
				return nil, "quantified groups are not supported"
			end
		elseif c == "[" then
			local j = i + 1
			local body = {}
			if s:sub(j, j) == "^" then
				body[#body + 1] = "^"
				j = j + 1
			end
			if s:sub(j, j) == "]" then
				body[#body + 1] = "%]"
				j = j + 1
			end
			while j <= #s and s:sub(j, j) ~= "]" do
				local d = s:sub(j, j)
				if d == "\\" then
					local e = escape_atom(s:sub(j + 1, j + 1), true)
					if not e then
						return nil, "unsupported escape \\" .. s:sub(j + 1, j + 1)
					end
					body[#body + 1] = e
					j = j + 2
				else
					body[#body + 1] = (d == "%") and "%%" or d
					j = j + 1
				end
			end
			if j > #s then
				return nil, "unbalanced ["
			end
			atom = "[" .. table.concat(body) .. "]"
			i = j + 1
		elseif c == "\\" then
			atom = escape_atom(s:sub(i + 1, i + 1), false)
			if not atom then
				return nil, "unsupported escape \\" .. s:sub(i + 1, i + 1)
			end
			i = i + 2
		elseif c == "^" or c == "$" then
			if (c == "^" and i == 1) or (c == "$" and i == #s) then
				i = i + 1
			else
				return nil, "anchor in the middle of a regex"
			end
		elseif c:match("[%)%]{}|*+?]") then
			return nil, "unexpected '" .. c .. "'"
		else
			atom = c:match("[%%%-]") and ("%" .. c) or c
			i = i + 1
		end

		if atom then
			local q = s:sub(i, i)
			if q == "*" or q == "+" or q == "?" then
				atom = atom .. q
				i = i + 1
				if s:sub(i, i) == "?" then -- lazy; same result under anchored matching
					i = i + 1
				end
			elseif q == "{" then
				return nil, "{n,m} quantifiers are not supported"
			end
			alts = { atom }
		end

		if alts then
			local next_acc = {}
			for _, a in ipairs(acc) do
				for _, b in ipairs(alts) do
					next_acc[#next_acc + 1] = a .. b
				end
			end
			if #next_acc > MAX_ALTERNATIVES then
				return nil, "too many alternatives"
			end
			acc = next_acc
		end
	end
	return acc
end

parse_alt = function(s)
	local out = {}
	for _, part in ipairs(split_top(s, "|")) do
		local seqs, err = parse_seq(part)
		if not seqs then
			return nil, err
		end
		for _, p in ipairs(seqs) do
			out[#out + 1] = p
		end
	end
	return out
end

local regex_cache = {}

--- Does `value` match the Hyprland regex `re`? Returns nil, err if unsupported.
local function regex_match(re, value)
	local mode = state.opts and state.opts.match_mode or "full"
	local key = mode .. "\0" .. re
	local pats = regex_cache[key]
	if pats == nil then
		local alts, err = parse_alt(re)
		if not alts then
			regex_cache[key] = { err = err }
			return nil, err
		end
		pats = {}
		for _, a in ipairs(alts) do
			if mode == "partial" then
				-- keep the user's own anchors in partial mode
				local p = a
				if re:sub(1, 1) == "^" then
					p = "^" .. p
				end
				if re:sub(-1) == "$" and re:sub(-2) ~= "\\$" then
					p = p .. "$"
				end
				pats[#pats + 1] = p
			else
				pats[#pats + 1] = "^" .. a .. "$"
			end
		end
		regex_cache[key] = pats
	end
	if pats.err then
		return nil, pats.err
	end
	value = value or ""
	for _, p in ipairs(pats) do
		if value:find(p) then
			return true
		end
	end
	return false
end

local STRING_PROPS =
	{ class = "class", title = "title", initial_class = "initial_class", initial_title = "initial_title" }
local BOOL_PROPS = {
	xwayland = function(w)
		return w.xwayland
	end,
	float = function(w)
		return w.floating
	end,
	floating = function(w)
		return w.floating
	end,
	pin = function(w)
		return w.pinned
	end,
	pinned = function(w)
		return w.pinned
	end,
	fullscreen = function(w)
		return w.fullscreen ~= nil and w.fullscreen ~= 0 and w.fullscreen ~= false
	end,
}

local function truthy(v)
	return v == true or v == 1 or v == "1" or v == "true" or v == "yes" or v == "on"
end

--- true / false, or nil + reason if the rule can't be evaluated in Lua.
local function window_matches(win, match)
	for key, want in pairs(match or {}) do
		if STRING_PROPS[key] then
			local ok, err = regex_match(tostring(want), win[STRING_PROPS[key]])
			if ok == nil then
				return nil, string.format("%s regex '%s': %s", key, tostring(want), err)
			elseif not ok then
				return false
			end
		elseif BOOL_PROPS[key] then
			if (BOOL_PROPS[key](win) and true or false) ~= truthy(want) then
				return false
			end
		else
			return nil, "match key '" .. key .. "' is not supported for moving windows"
		end
	end
	return true
end

--- Returns the rule's target workspace if it is a fixed one (an id or
--- "name:x"), or nil, true for dynamic targets like "empty", "r+1", "previous"
--- or "special:x" — those would move the window again on every switch.
local function parse_rule_workspace(ws)
	if ws == nil then
		return nil
	end
	ws = tostring(ws):gsub("%s+silent%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if ws == "" then
		return nil
	end
	if ws:match("^%d+$") or ws:match("^name:.") then
		return ws
	end
	return nil, true
end

local function on_workspace(win, target)
	local ws = win.workspace
	if not ws then
		return false
	end
	if ws.id and tostring(ws.id) == target then
		return true
	end
	if ws.name and (ws.name == target or "name:" .. ws.name == target) then
		return true
	end
	return false
end

--- Move open windows to where the (now active) window rules say they belong.
local function move_windows(specs)
	local windows = hl_list(hl.get_windows)
	if not windows then
		return
	end

	local warned = {}
	for _, win in ipairs(windows) do
		local skip = win.hidden or win.mapped == false or (win.workspace and win.workspace.special)
		if not skip then
			-- last matching rule with a target wins
			local target_ws, target_mon, rule_name
			for _, spec in ipairs(specs) do
				local ws, dynamic = parse_rule_workspace(spec.workspace)
				if ws or dynamic or spec.monitor then
					local m, err = window_matches(win, spec.match)
					if m == nil then
						local id = tostring(spec.name) .. err
						if not warned[id] then
							warned[id] = true
							log("rule '%s' not used for moving windows: %s", tostring(spec.name), err)
						end
					elseif m and dynamic then
						-- the last matching rule has no fixed target: leave the window where it is
						target_ws, target_mon, rule_name = nil, nil, nil
					elseif m then
						target_ws, target_mon, rule_name = ws, spec.monitor, spec.name
					end
				end
			end

			if target_ws and not on_workspace(win, target_ws) then
				log("move window '%s' -> workspace %s (rule %s)", tostring(win.class), target_ws, tostring(rule_name))
				pcall(hl.dispatch, hl.dsp.window.move({ workspace = target_ws, window = win, follow = false }))
			elseif not target_ws and target_mon and not (win.monitor and win.monitor.name == target_mon) then
				log("move window '%s' -> monitor %s (rule %s)", tostring(win.class), target_mon, tostring(rule_name))
				pcall(hl.dispatch, hl.dsp.window.move({ monitor = target_mon, window = win, follow = false }))
			end
		end
	end
end

--- Evaluate and apply.
---   opts.force  re-apply even if nothing changed. Also moves open workspaces
---               back to their monitors, unless it comes from a config (re)load.
function M.apply(opts)
	opts = opts or {}
	if not state.config then
		return
	end

	if state.paused and not opts.force then
		log("paused by the hotplug loop guard; not applying")
		return
	end

	local ctx = build_context()
	if #ctx.monitors == 0 then
		-- e.g. during early config load, or everything unplugged: nothing to lay
		-- out, and picking `default` here would look like a setup switch later
		log("no monitors connected; waiting")
		return
	end

	local setup = pick_setup(ctx)
	local mons = monitors_signature(ctx)
	local sig = tostring(setup.name) .. "|" .. mons

	if not (opts.force or opts.startup) and sig == state.signature then
		log("no change (%s)", setup.name)
		return
	end

	local old, old_mons = state.setup_name, state.monitors_sig
	local setup_changed = old ~= nil and old ~= setup.name
	local monitors_changed = old_mons ~= nil and old_mons ~= mons
	local names = {}
	for _, mon in ipairs(ctx.monitors) do
		names[#names + 1] = mon.name
	end
	log("applying setup '%s' (connected: %s)", tostring(setup.name), table.concat(names, ", "))

	-- Move open workspaces only when the layout actually changed (or on
	-- startup / an explicit re-apply), so a config reload doesn't undo manual moves.
	local move_ws = state.opts.move_existing
		and (setup_changed or monitors_changed or opts.startup or (opts.force and not opts.from_config))

	apply_outputs(setup, ctx)
	apply_workspaces(setup, ctx, move_ws)
	local specs = apply_window_rules(setup, ctx)

	state.signature = sig
	state.monitors_sig = mons
	state.setup_name = setup.name

	-- only on a real switch, so a config reload doesn't undo manual moves
	if setup_changed and state.opts.move_windows then
		move_windows(specs)
	end

	if old ~= setup.name then
		notify("setup '" .. tostring(setup.name) .. "'")
		if state.opts.on_change then
			local ok, err = pcall(state.opts.on_change, old, setup.name, ctx)
			if not ok then
				warn("on_change failed: %s", tostring(err))
			end
		end
	end
end

--- Schedule an apply, coalescing bursts of events. Options of all coalesced
--- calls are merged, so e.g. a `startup` flag isn't lost to a later event.
function M.schedule(opts)
	state.pending = merge(state.pending, opts)
	local function run()
		local o = state.pending or {}
		state.pending = nil
		M.apply(o)
	end

	local delay = state.opts and state.opts.debounce_ms or 0
	if delay <= 0 then
		return run()
	end

	state.generation = state.generation + 1
	local token = state.generation
	local ok = pcall(hl.timer, function()
		if token == state.generation then
			run()
		end
	end, { timeout = delay, type = "oneshot" })

	if not ok then
		run()
	end
end

--- Loop guard: a monitor that drops its link whenever it is reconfigured
--- would make hyprdynamic reconfigure it again on every reconnect, forever.
--- Too many hotplug events in a short time pause hyprdynamic until there has
--- been a quiet `guard_window_ms`; then it applies once more.
local function on_hotplug()
	state.hotplug = state.hotplug + 1

	local max = state.opts.guard_max_events or 0
	if max <= 0 then
		return
	end
	local window_ms = state.opts.guard_window_ms or 30000
	local now = os.time()
	local recent = {}
	for _, t in ipairs(state.hotplug_times) do
		if (now - t) * 1000 < window_ms then
			recent[#recent + 1] = t
		end
	end
	recent[#recent + 1] = now
	state.hotplug_times = recent
	log("%d hotplug event(s) within the last %ds", #recent, window_ms // 1000)

	if #recent > max and not state.paused then
		state.paused = true
		warn(
			"%d monitor hotplug events within %ds; pausing until monitors stay put for %ds",
			#recent,
			window_ms // 1000,
			window_ms // 1000
		)
	end

	if state.paused then
		state.guard_gen = state.guard_gen + 1
		local gen = state.guard_gen
		after(window_ms, function()
			if gen == state.guard_gen and state.paused then
				state.paused = false
				state.hotplug_times = {}
				log("hotplug events have settled; resuming")
				notify("monitors settled; resuming")
				M.schedule({})
			end
		end)
	end
end

---------------------------------------------------------------------------
-- config validation
---------------------------------------------------------------------------

local function validate(cfg)
	local errors = {}
	local function err(fmt, ...)
		errors[#errors + 1] = string.format(fmt, ...)
	end

	if type(cfg.monitors) ~= "table" then
		err("`monitors` must be a table of alias = { desc = ... }")
		cfg.monitors = {}
	end
	for alias, def in pairs(cfg.monitors) do
		if type(def) == "string" then
			cfg.monitors[alias] = { desc = def }
		elseif type(def) ~= "table" or not (def.desc or def.name or def.match) then
			err("monitor '%s' needs `desc`, `name` or `match`", tostring(alias))
		end
	end

	cfg.setups = cfg.setups or {}
	for i, setup in ipairs(cfg.setups) do
		setup.name = setup.name or ("setup" .. i)
		if not (setup.requires or setup.requires_any or setup.when) then
			err("setup '%s' has no `requires`, `requires_any` or `when`; it would always match", setup.name)
		end
		for _, key in ipairs({ "requires", "requires_any", "excludes" }) do
			for _, alias in ipairs(setup[key] or {}) do
				if not cfg.monitors[alias] then
					err("setup '%s'.%s: unknown monitor alias '%s'", setup.name, key, alias)
				end
			end
		end
		for alias in pairs(setup.workspaces or {}) do
			if not cfg.monitors[alias] then
				err("setup '%s'.workspaces: unknown monitor alias '%s'", setup.name, alias)
			end
		end
	end

	cfg.default = cfg.default or {}
	cfg.default.name = cfg.default.name or "default"

	local function check_window_rules(where, rules)
		if rules == nil then
			return
		end
		if type(rules) ~= "table" then
			err("%s.window_rules must be a list", where)
			return
		end
		for i, rule in ipairs(rules) do
			if type(rule) ~= "table" then
				err("%s.window_rules[%d] must be a table", where, i)
			elseif not rule.match and rule.enabled ~= false then
				err("%s.window_rules[%d] (%s) has no `match`", where, i, tostring(rule.name))
			end
		end
	end
	check_window_rules("config", cfg.window_rules)
	for _, setup in ipairs(cfg.setups) do
		check_window_rules("setup '" .. setup.name .. "'", setup.window_rules)
	end
	check_window_rules("default", cfg.default.window_rules)
	cfg.default.unknown = cfg.default.unknown or { mode = "preferred", position = "auto", scale = "auto" }

	return errors
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

function M.config(cfg)
	cfg = cfg or {}
	state.opts = merge(defaults, cfg.options)

	local errors = validate(cfg)
	for _, e in ipairs(errors) do
		warn("%s", e)
	end

	state.config = cfg
	state.signature = nil
	state.applied = {} -- a (re)loaded config starts without our monitor rules

	-- (re)register event handlers
	for _, sub in ipairs(state.subscriptions) do
		pcall(function()
			sub:remove()
		end)
	end
	state.subscriptions = {}

	local function subscribe(event, fn)
		local ok, sub = pcall(hl.on, event, fn)
		if ok and sub then
			state.subscriptions[#state.subscriptions + 1] = sub
		elseif not ok then
			warn("could not subscribe to '%s': %s", event, tostring(sub))
		end
	end

	local hotplug_events = { ["monitor.added"] = true, ["monitor.removed"] = true }
	for _, event in ipairs(state.opts.events) do
		subscribe(event, function()
			log("event %s", event)
			if hotplug_events[event] then
				on_hotplug()
			end
			M.schedule({ startup = event == "hyprland.start" or nil })
		end)
	end
	-- hotplug events are needed to tell user focus changes from Hyprland's
	-- reshuffles, even if they don't trigger an apply
	local listed = {}
	for _, e in ipairs(state.opts.events) do
		listed[e] = true
	end
	for event in pairs(hotplug_events) do
		if not listed[event] then
			subscribe(event, on_hotplug)
		end
	end
	subscribe("workspace.active", track_focus)
	subscribe("monitor.focused", track_focus)

	-- the active workspace isn't known while the config is loading (and timers
	-- created then don't fire), so pick it up once loading has finished
	local function init_focus()
		if not state.focus then
			local ws = active_workspace()
			if ws and not ws.special then
				state.focus = ws_ident(ws)
			end
		end
	end
	init_focus()
	subscribe("config.reloaded", init_focus)
	subscribe("hyprland.start", init_focus)

	-- apply right away so the layout is correct during config load
	M.apply({ force = true, from_config = true })
	return M
end

--- Name of the currently active setup.
function M.current()
	return state.setup_name
end

--- Debug helper: what hyprdynamic sees right now.
function M.status()
	if not state.config then
		return "hyprdynamic: not configured"
	end
	local ctx = build_context()
	local lines = { "hyprdynamic: active setup = " .. tostring(state.setup_name) }
	for _, mon in ipairs(ctx.monitors) do
		local alias = "-"
		for a, m in pairs(ctx.by_alias) do
			if m == mon then
				alias = a
			end
		end
		lines[#lines + 1] = string.format("  %-10s %-12s %s", mon.name, alias, mon.description or "")
	end
	return table.concat(lines, "\n")
end

M._internal = { expand_workspaces = expand_workspaces, regex_match = regex_match, state = state }

-- alias
M.setup = M.config

return M
