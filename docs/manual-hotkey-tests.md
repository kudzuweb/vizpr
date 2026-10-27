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

### Safe on any Mac

These three checks cannot install a tap, so they are safe on the machine whose
keyboard you use. Setup: copy a fresh Debug build to a scratch folder, set its
`CFBundleIdentifier` to `com.kudzuweb.vizpr.saferun`, and re-sign it with
`codesign --force --deep -s -`. TCC has no Accessibility grant for that
identity, so `tapCreate` returns nil. Launch the executable directly with
`CFFIXED_USER_HOME=<scratch>/home`, which keeps its files out of your
Application Support, and arm a background `kill -9` of its pid at 30 s as a
backstop. Read the result with
`log show --last 1m --predicate 'subsystem == "com.kudzuweb.vizpr"'`.

- [ ] **Bundle deleted while running**: `rm -rf` the copy. Vizpr quits within
      5 s, and the log has a `Vizpr's app files are gone` line.
- [ ] **Executable replaced while running**: `mv` a fresh executable over
      `Contents/MacOS/Vizpr`. Same result.
- [ ] **Resource missing at launch**: launch a re-signed copy with
      `Contents/Resources/default.metallib` removed. It shows "Vizpr's app files
      are missing or damaged." and quits with no tap installed.

### Spare Mac or VM only

These two exercise a live tap that holds input. Do not run them on a machine
whose keyboard you need.

- [ ] **Keyboard works with a tap installed while the bundle is deleted**:
      launch an un-re-signed copy of the Debug app with Accessibility granted,
      then `rm -rf` the copy. The keyboard works the whole time and Vizpr
      quits within 5 s.
- [ ] **Refused tap gives up**: with a tap that macOS keeps disabling, three
      timeout disables inside 30 s end in `giving up` in the dev log, a notice,
      and a menu showing `Restart Hotkey` instead of `Grant Accessibility…`.
      Changing a setting (an overlay drag) does not bring the tap back; `Restart
      Hotkey` does.
