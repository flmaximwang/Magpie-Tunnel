# Automated UI acceptance for the menu-bar app

Four files, no third-party dependencies, no changes to `Sources/MagpieTunnelStatus/`:

| file | what it is |
| --- | --- |
| `UIProbe.swift` | small read-only helper, compiled on the fly by the script (window list, AX tree, synthetic click, PNG statistics, `sample` classifier, control windows) |
| `ui_acceptance.sh` | the driver: isolated launch → click the status item → open the config / log window → verdict |
| `kill_acceptance.sh` | force-quit check: `kill -9` the app, then assert the daemon and every ssh child go away and a relaunch rebuilds them |
| `appearance_check.sh` | appearance check: capture the config window in the light or dark appearance and judge legibility |

```bash
Tests/manual-ui/ui_acceptance.sh                       # both windows, current dist/
Tests/manual-ui/ui_acceptance.sh --window config
Tests/manual-ui/ui_acceptance.sh --app /path/to/Other.app --keep --json
Tests/manual-ui/ui_acceptance.sh --control             # the screenshot-limitation experiments
Tests/manual-ui/kill_acceptance.sh                     # SIGKILL the app, verify daemon cleanup
Tests/manual-ui/appearance_check.sh --appearance light
Tests/manual-ui/appearance_check.sh --appearance dark --out /tmp/shots --json
```

Exit codes, all three scripts: `0` pass, `1` a check failed (blank window, unresponsive main thread,
missing cleanup), `2` inconclusive (the UI could not be driven, or the appearance branch was not
covered), `3` environment problem.

## What it checks

1. **Is the main thread responsive?** `/usr/bin/sample <pid> 1` is parsed by `classify`, which finds
   the main-thread block (labelled either `com.apple.main-thread` or `Main Thread  DispatchQueue_<multiple>`)
   and sums the frame counts that `sample` puts on each line. Verdicts: `responsive-idle`
   (≥ half the samples in `__CFRunLoopServiceMachPort` / `mach_msg2_trap`), `responsive-busy`
   (`-[NSApplication run]` on the stack but working), `thrashing-in-layout` (≥ a third of the
   samples in `-[NSView layout]` / `NSISEngine` / `CFRunLoopDoObserver` / `CADisplay` …),
   `not-in-event-loop`, `sample-unavailable`.
   `sample` is wrapped in `perl -e 'alarm 25; exec @ARGV'` because on a machine where the
   Developer Tools authorization prompt appears it never returns; the run then degrades
   instead of hanging.

2. **Did the window actually draw?** `CGWindowListCopyWindowInfo` gives the window id, then
   `screencapture -x -o -l <id>` captures the window into a PNG and `UIProbe image` decodes it:
   opaque ratio, luminance mean/std-dev, distinct colour buckets, near-white ratio.
   The app is dark-mode, so a window that failed to render is **transparent**, not white;
   the verdict therefore keys on coverage and colour variety:

   | verdict | meaning |
   | --- | --- |
   | `drawn` | opaque ≥ 0.5, ≥ 12 distinct colours, std-dev ≥ 3 |
   | `transparent-not-drawn` | `opaqueRatio < 0.5` — the backing store has nothing in it |
   | `flat-single-colour` | ≤ 2 colour buckets |
   | `nearly-empty` | std-dev < 3 |
   | `sparse` | < 12 colour buckets |
   | `zero-sized-window-never-laid-out` | the window exists in the CG list at 0×0 with `onscreen=false`; `screencapture` refuses it outright |
   | `capture-failed` | `screencapture` produced no file |

   `nearWhiteRatio` is reported but never decides the verdict.

3. **AX sanity**: element count and how many controls are squeezed to ≤ 3 pt (`collapsedControls`) —
   a form whose fields are 2×2 points is laid out at zero size even if the window looks non-empty.

4. **Log signatures** from `log show --predicate 'processID == <pid>'`:
   `NSUnknownKeyException`, `An uncaught exception was raised`,
   `It's not legal to call -layoutSubtreeIfNeeded …`, plus the first `ConfigWindowController` frame.

## Isolation (this is what makes it safe to run on a live machine)

- The bundle is **copied** into the temp dir; `CFBundleIdentifier` and `CFBundleName` are rewritten
  (`…uitest.acceptance`, `Magpie-UIAcceptance`) and it is ad-hoc signed, so it cannot collide with
  the installed app in LaunchServices.
- Every path is redirected into the temp dir, both on the command line and through the environment
  (`MAGPIE_TUNNEL_CONFIG`, `MAGPIE_TUNNEL_STATUS_DIR`, `MAGPIE_TUNNEL_LOG_DIR`,
  `MAGPIE_TUNNEL_LOCK_DIR`, `MAGPIE_TUNNEL_SSH_BIN`). The environment matters because the app
  spawns `magpie-tunneld` with **only** `--owner-pid`, so the daemon inherits the redirect from
  the environment. `~/.local`-style production paths (`~/Library/Application Support/MagpieWebTunnel`)
  are never opened.
- `MAGPIE_TUNNEL_SSH_BIN` points at a `exit 1` shell script, and the test targets use
  `example.invalid`, so no connection is ever attempted.
- The test config follows the real format `name|local_port|ssh_target|remote_port|web_key`
  (`Sources/MagpieTunnelCore/TargetsParser.swift:21-30`). A malformed row makes the app show
  "修正配置" instead of a table, which would hide the very row view this check exists for.
- Cleanup kills the launched pid and then any process whose command line mentions the temp dir.
  Nothing is matched by name, so the installed app and its daemon cannot be touched.
  Note: `DaemonController.ensureOwnedDaemon` terminates daemons it does not consider its own —
  another reason the environment redirect above is mandatory rather than optional.

## Driving the UI without accessibility permissions

The status item is a third-party `NSStatusItem`: its AX frame comes from the app itself
(`kAXMenuBarAttribute` → `AXMenuBarItem`), and the popover's buttons are found by walking
`kAXWindowsAttribute` — a popover is **not** in `AXChildren`, and System Events cannot address it
at all (`tell pop up … click button` fails with `-1719`).

The click path is a real `CGEvent` (`CGWarpMouseCursorPosition` + `mouseMoved`/`Down`/`Up` at the
element's AX centre) — no `lldb`, no Developer Tools authorization, no Apple Events. AXPress on the
same `AXMenuBarItem` (`UIProbe pressitem`) is the fallback; see the next section for when it is
needed, and `find`/`axhealth`/`axlatency` for the query side.

`UIProbe obstructors <pid>` is the read-only check for the case where the click never lands: it
reports the on-screen windows above the menu-bar level that cover the status item.

If the terminal is **not** accessibility-trusted (`AXIsProcessTrusted()` false, the `-25211`
case), showing the windows is impossible for any external process. The script then says so,
falls back to `--smoke-test`, and exits `2`:

```
ax-trusted: false
popover:   skipped — this process is not accessibility-trusted
smoke: icon=degraded 2 条隧道，0 条已连接
result:    inconclusive
```

`MAGPIE_UI_FORCE_HEADLESS=1` forces that path, so it can be tested on a machine where
accessibility *is* granted.

**A permanently-permission-free path needs one line in the main implementation**, e.g. in
`main.swift` after argument parsing:

```swift
if let name = options.openWindow {   // --open-config / --open-logs
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        (NSApp.delegate as? AppDelegate)?.openWindowForTesting(named: name)
    }
}
```

with an `@objc` wrapper around the existing private `showConfigurationWindow()` / `showLogWindow()`.
That is deliberately **not** added here: this directory only holds test tooling, and
`Sources/MagpieTunnelStatus/` belongs to another subtask. Everything above works today without it.

## Synthetic clicks that get swallowed by an overlay

A synthetic click is delivered to the **topmost window under the pointer**, not to the element the
coordinates were taken from. A screen-capture tool (`capcap.app` was the case here), a window-manager
strip or any other window sitting above the menu-bar window level therefore receives the click and
the status item never opens — not with the test app, and not with the installed one either. That is
an environment property of the machine, not a defect in the app, so the script treats it as such.

`open_popover()` now tries two paths per attempt (three attempts):

1. `probe click <centerX> <centerY>`, then poll `probe find <pid> "隧道配置"` 10 × 0.2 s.
2. If the click lost, `probe pressitem <pid>` (AXPress on the status item — it never goes through
   hit-testing, so an overlay cannot intercept it), then the same 10 × 0.2 s poll.

The path that won is reported twice: as a log line and in the report.

```
  status item is covered by a full-screen overlay (pid=932 owner=capcap layer=25 bounds=224,0,1279,208); falling back to AXPress
popover:   opened via AXPress (click was swallowed), buttons reachable at 899,209.5
```

```json
"popover": {"method": "AXPress", "obstructed": true,
            "windows": [{"owner": "capcap", "pid": 932, "layer": 25, "bounds": "224,0,1279,208"}]}
```

`method` is `synthetic-click`, `AXPress`, `failed` (both paths lost) or `skipped` (no AX trust).
If both paths fail **and** something covers the status item, the run is `inconclusive` with an
explicit environment verdict rather than a plain "popover could not open":

```
ENV: status item click is being swallowed by capcap (layer 25)
popover:   could not open — the status item is covered, UI automation is impossible here
```

and a check `{"error":"click-swallowed-by-overlay","owner":"capcap","layer":25,…}` is added to
`checks`. If both paths fail with **nothing** covering the item, the old
`{"error":"popover-stuck"}` is recorded instead — the app failed to react on its own.

### The obstruction check

`UIProbe obstructors <pid>` is a read-only subcommand (it only reads the window list, it never
clicks or activates anything):

```bash
xcrun swiftc -O Tests/manual-ui/UIProbe.swift -o /tmp/ui-probe
/tmp/ui-probe obstructors 33244                       # probe the status item itself
/tmp/ui-probe obstructors 33244 --at 20 16.5          # a point outside the overlay
/tmp/ui-probe obstructors 33244 --min-layer 1000      # the stricter layer threshold
```

It takes the status item's AX centre (`statusitem`) unless `--at <x> <y>` is given, then walks
`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` and reports every
on-screen window whose layer is at least `--min-layer` (default: one above
`CGWindowLevelForKey(.mainMenuWindow)` = 25 on this machine) and whose bounds contain that point:

```json
{"obstructed":true,"x":1175,"y":16.5,"menuBarLayer":24,"minLayer":25,
 "windows":[{"pid":932,"owner":"capcap","layer":25,"bounds":"224,0,1279,208","alpha":1}]}
```

The default threshold is deliberately "one above the menu bar", not the literal `layer >= 1000`:
the capture overlay here sat at layer 25, so a `>= 1000` test would have missed it. Use
`--min-layer 1000` when you want to look for high-level panels only. The check runs once per
`open_popover` call, and only after the first click has already failed — there is no point paying
for it when the click path works.

## Result on this machine

`dist/Magpie-WebUI-Tunnel.app` (1.2.1/5) → `pass`; both windows `drawn`
(config `opaqueRatio` 0.9994 / 286 colour buckets, logs 0.9995 / 251), main thread `responsive-idle`
in both samples, popover `method: "AXPress"` (the click is swallowed here, see above).

An older build that has no `TunnelCellView` symbol (kept for reference at
`/tmp/uitest/known-bad/KnownBad.app`) → `fail`, reproducibly: the log window is `drawn`, but the
config window shows up as `0×0`, `onscreen=false`,
`zero-sized-window-never-laid-out`, and the log scan finds
`NSUnknownKeyException` ×3, `An uncaught exception was raised` ×1, and the frame
`ConfigWindowController.tableView(_:viewFor:row:)` under `-[NSTableView layout]`.

## Why "blank" is a real blank and not a screenshot limitation

`--control` builds three windows in a helper process (accessory activation policy, i.e. the same
`LSUIElement` situation) and captures them through the identical pipeline:

| control | expectation | measured |
| --- | --- | --- |
| `element` | ordinary accessory-policy window | `drawn`, opaque 0.9987, 79 buckets |
| `offorder` | content set, `orderFront` never called | `drawn`, opaque 0.9987, 28 buckets |
| `occluded` | fully covered by an opaque black window | `drawn`, opaque 0.9987, 72 buckets |

Plus, earlier manual experiments: `screencapture -l` on an ordinary app window (Terminal) gave
non-white 0.9844; a window with no subviews still captured its title bar (std-dev 6.97);
`ghostwin` (never ordered front, `isVisible=false`) captured its content; `poprobe`
(`LSUIElement=true` → `NSPopover` → `makeKeyAndOrderFront`) captured the window at opaque 0.9992.

An empty capture instead looks exactly like `{"opaqueRatio":0,"distinctColorBuckets":1,"lumaStdDev":0,"meanLuma":0}`
— the whole PNG is one fully transparent colour. So `screencapture -l` works for `LSUIElement`
windows, for windows that were never ordered front, and for occluded windows; a transparent
result means the window's backing store was never painted.

Cross-checks on the broken build agree: `screencapture -R "54,609,720,508"` over the window's screen
rectangle captured the desktop behind it (the window was not composited on screen), and the AX tree
of the "white" window was full of 2×2-point controls — the form was collapsed to zero width.
And the main thread was **not** wedged: `sample` showed it parked in
`__CFRunLoopServiceMachPort`/`mach_msg2_trap` with periodic `tick` work, so the user's
"卡死" was a blank-but-alive window rather than a hang.


## Force-quit and appearance acceptance

Two more checks, each isolated the same way as `ui_acceptance.sh`: a temp dir, a copy of the
bundle with its own bundle id, every path redirected. Neither flips a system setting.

### `kill_acceptance.sh` — the app is force-quit

A SIGKILLed app cannot run its own cleanup, so the check exercises the daemon's owner watchdog
instead: `<lock-dir>/daemon.owner` holds `daemonPID|appPID|epoch`, the daemon polls that pid
every 2 s, and when the app dies it must take every ssh child down, write `down|<epoch>|守护退出`
to each status file and remove the lock files.

1. build a sandbox: `status/`, `logs/`, `lock/`, a two-row `targets.conf` and a mock ssh;
2. launch `Contents/MacOS/MagpieTunnelStatus` directly (not `open -n -a`: `open` hands back no
   pid, and this run has to `kill -9` exactly the process it started);
3. poll up to 15 s for both status files to read `up|…|port=<local port>`;
4. record the daemon pid, the ssh child pids and the local ports each of them holds;
5. `kill -9` the app;
6. poll up to 12 s until the daemon and **every** recorded ssh child are gone, the ports are free
   again and `lock/daemon.owner` has been removed;
7. assert both status files read `down|…|守护退出`;
8. relaunch the same bundle with the same arguments, wait for both rows to return to `up`, assert
   the daemon pid is **new** and two fresh ssh children cover the same two ports;
9. `kill -TERM` the app and assert the same clean disappearance.

The mock ssh has to differ from `ui_acceptance.sh`'s `exit 1` stub, which is enough to show a
`down` row but never reaches `up`. This one parses the daemon's `-L 127.0.0.1:<local>:127.0.0.1:<remote>`
argument, binds `<local>` with `nc -k -l` so the daemon's port probe succeeds, and exits on
`SIGTERM` the way real ssh does.

**Process matching is the trap here.** `pkill -f mock-ssh` also matches the installed app's
tunnels, `/tmp/ac5`, `/tmp/ac6`, `/tmp/ac7` and any other isolated instance on the machine, and a
match either kills a stranger or fails this run for someone else's process. Every lookup is
therefore anchored to this run's absolute temp path (`ps -axww -o pid=,command=` filtered by
`index(cmd, pattern)`), and the pattern for the ssh children includes the `-N` that only they
carry (the app and the daemon merely pass `--ssh-bin <mock-ssh>`, so they never match it).
Two consequences worth knowing:

- shell basenames must **not** be excluded from the match: the mock ssh is a bash script, so `ps`
  reports it as `/bin/bash <tmp>/mock-ssh -N …`; filtering out `bash` hides every child the check
  is looking for.
- a leftover listener cannot be found by name at all (it is `nc`, whose argv holds no path), so
  the run also asserts the two local ports are free — that catches an orphan a name pattern
  misses.

Exit codes: `0` pass, `1` a check failed, `3` environment problem. `--json` prints the report on
stdout and keeps every diagnostic on stderr.

### `appearance_check.sh` — light and dark

`--appearance light|dark|auto` (default appearance: the host's own, via `auto`). The window is
opened and captured by `ui_acceptance.sh --window config`, so both scripts agree on what `drawn`
means; this script only adds the appearance variant and the verdict.

It must not call `defaults write -g AppleInterfaceStyle`: that changes every app on the machine
and outlives the run. The per-bundle switch is instead the old Aqua compatibility key:

| requested | variant bundle | result |
| --- | --- | --- |
| `light` | `plutil -replace NSRequiresAquaSystemAppearance -bool YES`, then `codesign --force --deep -s -` | AppKit resolves `NSAppearanceNameAqua` for that process: a real light window, independent of the host |
| `dark` | unchanged | the copy follows the host; covered when the host is dark, not covered when it is light |
| `auto` | unchanged | judges whichever appearance the host has |

Measured on this machine (dark host): light copy `meanLuma` 233.9, `nearWhiteRatio` 0.138, 252
colour buckets; unchanged copy 49.9 / 0.0004 / 286; both `drawn`. The light screenshot shows white
text fields, dark labels and the blue selection, i.e. the real Aqua rendering.

`NSRequiresAquaSystemAppearance = NO` — the value that sounds like "support both" — does **not**
lighten a dark system (measured: still `NSAppearanceNameDarkAqua`). The gate is `YES`.

#### Known limitations

- **Dark on a light host is not covered.** No per-bundle plist key forces Dark; `NSRequiresAqua…=NO`
  means "supports dark mode" and keeps following the system. The run reports
  `dark: not-covered (requires manual system appearance switch)` and exits `2` rather than
  pretending to pass. To cover it: switch the system appearance by hand, then run
  `appearance_check.sh --appearance dark`.
- **`-AppleInterfaceStyle Light` on the command line does not work.** Passing it directly sets
  `UserDefaults` but leaves `NSApp.effectiveAppearance` on the system value, and `open -n -a <app>
  --args -AppleInterfaceStyle Light` kills the app outright (Trace/BPT trap: 5). `export
  AppleInterfaceStyle=…` has no effect either. Hence the plist route above.
- **A wrong per-app default is easy to mistake for a fix**: `defaults write <bundleid>
  AppleInterfaceStyle Light` changes nothing for this app (measured — the window stayed dark).
- The verdict is statistical (coverage, colour variety, luminance spread and mean luminance), not
  OCR: it proves the window drew and which appearance it is in, not that every label is spelled
  correctly.
- `MAGPIE_APPEARANCE_HOST=light|dark` overrides the *detected* host only, so the not-covered
  branch can be exercised on a machine whose system appearance is the other one. It never changes
  anything real: the run labels it `simulated by MAGPIE_APPEARANCE_HOST`, skips the dark verdict
  (the dark branch is the host's own appearance, so the pixels would be meaningless) and reports
  `inconclusive`. The light branch is host-independent and is still judged normally.

## Requirements

`xcrun swiftc` (Xcode or the command line tools — call it through `xcrun`, a bare toolchain path
loses `SDKROOT` and fails to find the standard library), `jq`, `screencapture`, `/usr/bin/sample`,
`log`. Tested on macOS 27.0.1 / Swift 6.4.
