# hyprdynamic

Dynamic monitor and workspace layouts for Hyprland's Lua config.

hyprdynamic looks at which monitors are connected, picks the first matching **setup**, then:

- applies `hl.monitor()` for each output in that setup (and a fallback spec for any connected monitor the setup doesn't configure)
- creates `hl.workspace_rule()`s binding workspaces to monitors, and disables the rules from the previous setup
- moves workspaces that are already open to their new monitor (on startup, when the setup or the set of connected monitors changes, and on an explicit `apply({ force = true })`, but not on a config reload, so manual moves are kept), then makes sure each monitor shows one of its own workspaces and puts focus back on the workspace you were on
- creates `hl.window_rule()`s from the global `window_rules` merged with the setup's own, and disables the previous ones
- falls back to `default` when no setup matches

It re-evaluates on `monitor.added`, `monitor.removed`, `config.reloaded` and `hyprland.start`. Bursts of events, such as when a dock connects, are debounced into a single update. If nothing has changed, it does nothing.

## Install

The repo is a Lua module: `init.lua` is the entry point, so `require("hyprdynamic")` works as long as the directory that *contains* `hyprdynamic/` is on `package.path` with an `?/init.lua` pattern.

Either symlink the repo into your Hypr config directory:

```sh
ln -s ~/git/hyprdynamic ~/.config/hypr/hyprdynamic
```

or add the parent directory to the search path at the top of `hyprland.lua`:

```lua
package.path = os.getenv("HOME") .. "/git/?/init.lua;" .. package.path
```

If `require("hyprdynamic")` fails with the symlink, Hyprland's default path is missing the `?/init.lua` pattern. Add it:

```lua
package.path = os.getenv("HOME") .. "/.config/hypr/?/init.lua;" .. package.path
```

Next, copy `example.lua` to `~/.config/hypr/conf/hyprdynamic.lua`, edit it, and in `hyprland.lua` replace `require("conf.dynamicmonitor")` with `require("conf.hyprdynamic")`.

## Config

See [`example.lua`](example.lua) for a full config.

| Key | Meaning |
|---|---|
| `monitors.<alias>` | `{ desc = "substring" }`, `{ name = "eDP-1" }`, `{ match = function(mon) end }`, or a bare string, which means `desc`. Each monitor belongs to one alias. The most specific alias claims it first: `name`, then the longest `desc`, then `match`. |
| `setups[]` | Checked in order. Put the more specific setups first. |
| `setups[].requires` | All of these aliases must be connected |
| `setups[].requires_any` | At least one of these must be connected |
| `setups[].excludes` | None of these may be connected |
| `setups[].when` | `function(ctx) return bool end`. `ctx.connected[alias]`, `ctx.by_alias[alias]`, `ctx.monitors` |
| `setups[].outputs.<alias>` | Any `hl.monitor` field (`mode`, `position`, `scale`, `transform`, `disabled`, `vrr`, ...). Outputs with an explicit `position` are applied first, then the `auto` ones, so automatic placement is the same every time. |
| `setups[].workspaces.<alias>` | `{1,2,3}`, `"1-5"`, `"name:music"`, or a mix |
| `window_rules[]` | Global window rules, active in every setup. Any `hl.window_rule` field works. |
| `setups[].window_rules[]` | Added to the global rules. A rule with the same `name` replaces the global one, and `{ name = "x", enabled = false }` turns it off for this setup. |
| window rule `monitor` | Can be a monitor alias. It's resolved to the real output name, and the rule is skipped while that monitor isn't connected. |
| `setups[].unknown` / `default.unknown` | Spec for connected monitors the setup doesn't configure |
| `default` | Same shape as a setup, used when nothing matches |

### Options

| Option | Default | |
|---|---|---|
| `events` | the four above | Events that trigger a re-evaluation |
| `move_existing` | `true` | Move open workspaces to their assigned monitor when the layout changes |
| `default_rule` | `true` | The first workspace per monitor gets `default = true` |
| `debounce_ms` | `300` | `0` applies immediately |
| `notify` | `true` | Show a Hyprland notification when the setup changes |
| `log` | `false` | Print debug lines to the Hyprland log |
| `log_file` | `false` | Also write debug lines and warnings, with timestamps, to this file, e.g. `"~/.cache/hyprdynamic.log"`. Unlike Hyprland's log, it survives a reboot. Works without `log = true` |
| `log_file_max_kb` | `1024` | When the file grows past this, it's moved to `<log_file>.1` and a new one is started |
| `move_windows` | `true` | On a setup switch, move open windows to the workspace (or monitor) their window rule now says. Windows on special workspaces aren't moved. |
| `match_mode` | `"full"` | How rule regexes are matched when moving windows: `"full"` or `"partial"` |
| `on_change` | `nil` | `function(old, new, ctx)`, e.g. to restart waybar |
| `settle_ms` | `100` | After moving workspaces, wait this long for Hyprland to settle before fixing what each monitor shows and restoring focus (see below) |
| `focus_settle_ms` | `500` | A change of focused workspace is only remembered if no monitor is plugged in or out within this time (see below) |
| `guard_max_events` | `8` | More monitor hotplug events than this within `guard_window_ms` pauses hyprdynamic (see below). `0` turns the guard off |
| `guard_window_ms` | `30000` | Time window for `guard_max_events`, and how long it must stay quiet before hyprdynamic resumes |

### Hotplug and focus

When a monitor is plugged in or out, Hyprland moves workspaces and focus around itself before hyprdynamic applies the new setup. A re-plugged monitor can end up showing a new, empty workspace (e.g. `11`), and focus can land on an empty workspace on another monitor.

To undo this, hyprdynamic keeps track of the workspace you're on. A focus change only counts once `focus_settle_ms` has passed without a hotplug, because Hyprland moves focus *before* it sends the `monitor.removed` event. After moving workspaces, and once `settle_ms` has passed:

- a monitor that shows an empty workspace that isn't in its `workspaces` list is switched to one that is: the one you were on if it belongs to that monitor, otherwise the first in its list
- focus goes back to the workspace you were on

This happens whenever open workspaces are moved: on startup, on a setup or monitor change, and on `apply({ force = true })`. Set `move_existing = false` to turn it off along with the moves.

### Monitors that blink or keep reconnecting

Some monitors, especially over USB-C or a dock, drop their link when they are reconfigured, which looks like a disconnect and reconnect. To avoid causing or feeding that:

- hyprdynamic only calls `hl.monitor()` for a monitor if the spec differs from what it last sent, or the monitor isn't running that way (mode, position, scale, transform or enabled differ). Specs like `preferred` or `auto` can't be checked, so they count as matching. A config reload sends every spec again.
- If more than `guard_max_events` monitor added/removed events arrive within `guard_window_ms`, hyprdynamic stops reacting to them and shows a warning. Once no hotplug event has arrived for `guard_window_ms`, it resumes and applies once. If a monitor keeps blinking while hyprdynamic is paused, the cause lies elsewhere (driver, cable, dock or bandwidth). `apply({ force = true })` still works while paused.

### Moving open windows

Hyprland only applies window rules when a window opens, so hyprdynamic moves windows that are already open itself. When the setup changes (but not on a config reload, so manual moves are kept), every open window is checked against the active rules. The last matching rule with a `workspace` (or a `monitor`, if it has no `workspace`) decides where the window goes, and the window is moved there silently. Only fixed workspaces (an id or `name:x`) are used. If the last matching rule has a dynamic target such as `empty`, `r+1` or `special:x`, the window is left where it is.

Matching happens in Lua, so only these `match` keys are supported for moving: `class`, `title`, `initial_class`, `initial_title`, `xwayland`, `float`, `pin`, `fullscreen`. The regexes can use literals, `.`, `[...]`, `\d \w \s`, `* + ?`, `^ $`, `|` and `( )` / `(?: )` groups. A rule using anything else, such as `tag` or `{2,3}`, still works as a normal window rule but isn't used for moving. Set `log = true` to see which rules were skipped.

### API

```lua
local hyprdynamic = require("hyprdynamic")
hyprdynamic.apply({ force = true })  -- re-apply now and move open workspaces back, e.g. from a keybind
hyprdynamic.current()                -- name of the active setup
hyprdynamic.status()                 -- what hyprdynamic sees, as a string
```

## Tests

```sh
lua test/test_hyprdynamic.lua
```

These run against a mocked `hl` API. The mock returns plain tables, while Hyprland returns userdata objects. Code that type-checks Hyprland objects has to accept both.

## License

BSD 3-Clause. See [`LICENSE`](LICENSE).
