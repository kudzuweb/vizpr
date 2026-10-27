# Manual hotkey test checklist (PR 2)

The pure state machine and edge tracker are covered by automated tests. The
CGEventTap shell needs real keystrokes and a real TCC grant, so it is verified by
hand on the target machine. Run these after granting Accessibility.

## Setup

```sh
./scripts/run-dev.sh
```

This launches the Debug app and streams its dev log. Each dictation action prints
as `hotkey action: startDictation | commit | cancel`. Keep this terminal visible.

If the menu-bar mic icon's menu still shows **"Grant Accessibility…"**, the grant
hasn't taken effect — quit Vizpr and relaunch (the TCC relaunch quirk). If it
shows **"Permission granted — relaunch to enable,"** relaunch.

## Behavior checks

- [ ] **Menu state**: with Accessibility granted, the menu shows only `Vizpr` /
      `Quit` — no grant item.
- [ ] **Tap → latch → commit**: quick-tap Fn (< ~0.2 s). Log shows
      `startDictation`. Tap Fn again → `commit`.
- [ ] **Hold → push-to-talk**: press and hold Fn (> ~0.2 s), then release. Log
      shows `startDictation` on press, `commit` on release.
- [ ] **Escape discards**: press Fn (`startDictation`), then Escape → `cancel`.
- [ ] **Secondary combo** (if testing without Fn): hold Ctrl+Opt, release → same
      tap/hold semantics, routed through the same actions.

## Safety checks (the load-bearing ones)

- [ ] **Fn never triggers the system globe/Dictation**: with the app running,
      press Fn alone. The macOS emoji/character viewer or Dictation must NOT
      appear. (Set System Settings → Keyboard → "Press 🌐 to" to anything; our tap
      suppresses Fn regardless.)
- [ ] **Zero swallowed keystrokes**: open TextEdit. Type a fast sentence. Then
      dictate (Fn) and immediately type another fast sentence. Every character
      must land — no drops, no stuck modifiers. This is the Wispr failure being
      inverted; spend real effort here.
- [ ] **Escape still reaches the app**: in an app where Escape does something
      (e.g. closing a Spotlight/Find bar), pressing Escape to cancel dictation
      should also reach that app — Escape is never suppressed.

## Permission flow (clean slate)

```sh
tccutil reset Accessibility com.kudzuweb.vizpr
tccutil reset ListenEvent com.kudzuweb.vizpr
```

- [ ] Relaunch: menu shows `Grant Accessibility…`. Click it → System Settings
      prompt. Grant, then relaunch when prompted. Menu clears, hotkey works.

## Tap safety (2026-10-27)

Neither check can be automated: the first needs a live tap, the second needs a
copy of the app that is deleted while running. Run both on a spare Mac or in a
VM, not on a machine whose keyboard you need: they exercise a tap that holds
input.

- [ ] **Bundle deleted while running**: launch a copy of the Debug app from a
      scratch folder, then `rm -rf` the copy. Vizpr quits within 5 s; the
      unified log (`log show --last 1m --predicate 'subsystem == "com.kudzuweb.vizpr"'`)
      has a `Vizpr's app files are gone` line. With the tap installed, the
      keyboard works the whole time.
- [ ] **Refused tap gives up**: with a tap that macOS keeps disabling, three
      timeout disables inside 30 s end in `giving up` in the dev log, a notice,
      and a menu showing `Restart Hotkey` instead of `Grant Accessibility…`.
      Changing a setting (an overlay drag) does not bring the tap back; `Restart
      Hotkey` does.
