# CaffeinateBar

Single-purpose native macOS menu bar toggle for `caffeinate`.

- Icon: SF Symbol coffee — `cup.and.saucer` (outlined = inactive) /
  `cup.and.saucer.fill` (filled = active)
- Menu: live status line (with countdown), Turn On Indefinitely,
  Turn On For… (15m / 30m / 1h / 2h / 5h), Turn Off, Quit
- Caffeinate Assertions submenu: `-d -i -m -s -u` toggles (persisted)
- Check External Every submenu: 5s / 10s (default) / 30s

## Minimal polling, not constant polling

- ONE `Timer` (default every 10s, tolerance set so the OS coalesces wakeups)
  that does a single `proc_listpids` + `proc_name` syscall sweep to spot a
  `caffeinate` started elsewhere (e.g. Terminal). No fork/exec, microseconds
  per tick, ~0% CPU.
- When our own child is running the tick skips the syscall entirely and only
  refreshes the countdown label.
- The menu also re-checks synchronously on open (`menuWillOpen`), so status
  is always exact when you look at it.
- Everything else is event-driven: menu actions + child `terminationHandler`.

## Sessions survive restarts

Timed sessions store their deadline; indefinite sessions store `wantedOn`.
Relaunching resumes with the remaining time.

## Build & run

```sh
./build.sh            # app only
./build.sh --dmg      # app + drag-and-drop installer (CaffeinateBar-2.0.dmg)
open CaffeinateBar.app
```

## Install

Open `CaffeinateBar-2.0.dmg` and drag CaffeinateBar into Applications.
Login at boot: Settings → General → Login Items → + → CaffeinateBar.

## App icon

`Assets/` holds the full icon pipeline:

- `make-icon.swift` — renders the 1024px coffee source (`icon-1024.png`)
- `caffenated.icon` — Icon Composer project (macOS 26 format)
- `caffenated-iOS-Default-1024@1x.png` — Icon Composer render export
- `AppIcon.icns` is generated at build time (`sips` + `iconutil`) —
  never committed, always reproducible via `./build.sh`

Debug aid: `defaults read com.slimane.caffeinatebar lastStatus` reports
`active-own` / `active-external` / `inactive`.
