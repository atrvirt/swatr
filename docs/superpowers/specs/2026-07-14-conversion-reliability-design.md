# SwATR — Conversion Reliability, Case Preservation, Mini-Notification

**Date:** 2026-07-14
**Status:** Approved by user (design discussion 2026-07-14)

## Problem

Three user-reported defects in the layout-conversion feature (Pause / Shift+Pause):

1. **Case loss.** Converting the last typed word (Pause) produces all-lowercase
   output even when the word was typed with Shift or CapsLock. Root cause:
   `VkToChar` originally read `GetKeyboardState` from SwATR's own thread, where
   Shift is never pressed. A working-tree fix (uncommitted, never built —
   SwATR.exe is dated 22.06, the fix 26.06) reads Shift via `GetAsyncKeyState`,
   but its CapsLock check uses `GetAsyncKeyState(VK_CAPITAL) and $0001`, which
   is NOT the toggle bit (that flag means "pressed since last call" and is
   unreliable). CapsLock-typed words would still lose case.

2. **Stray `v` inserted on Shift+Pause.** `WMConvertSelected` blocks the main
   thread with `Sleep(250)` plus retry sleeps. The main thread also services
   the WH_KEYBOARD_LL hook, so while it sleeps the hook cannot respond; Windows
   holds every keystroke system-wide up to LowLevelHooksTimeout (~300 ms per
   event), then bypasses the hook with erratic inter-event delays. The injected
   Ctrl↓ / V↓ / V↑ / Ctrl↑ batch can reach the target app with Ctrl no longer
   seen as held → a literal `v` is typed. Contributing factors: physical Shift
   auto-repeat re-asserts Shift after the synthetic release (Ctrl+C becomes
   Ctrl+Shift+C, which is a different command in Chrome/VS Code), and Pause
   auto-repeat queues multiple `WM_CONVERT_SELECTED` messages.

3. **System-wide input freeze on repeated Pause.** Same root cause as (2):
   every sleep on the hook thread stalls ALL keyboard input in Windows.
   Queued repeat invocations compound the stall to seconds; repeated hook
   timeouts make Windows silently unhook SwATR entirely (dead until restart).

4. **Notification balloon lives too long.** Balloon/toast duration is
   OS-controlled (~5–10 s), too intrusive for a per-word action.

## Design

All changes are in `uMain.pas` (plus a new tiny notification unit or an
in-file implementation — implementer's choice, prefer a separate unit
`uToastForm.pas` only if it keeps uMain smaller).

### 1. Non-blocking waits — `WaitPump`

Replace every `Sleep` in the conversion/clipboard paths (`WMConvertSelected`,
`ClipGetText`, `ClipSetText`, post-`ReleaseShift` delay) with:

```pascal
procedure WaitPump(Ms: Cardinal);
// Loop until deadline: MsgWaitForMultipleObjectsEx(0, nil, remaining,
// QS_ALLINPUT, MWMO_INPUTAVAILABLE) + PeekMessage/Translate/Dispatch drain.
```

The message pump keeps the LL hook callback serviced at all times. The hook
never times out; system input is never delayed.

Reentrancy note: pumping dispatches queued window messages, including further
`WM_CONVERT_*`. Guarded by item 2.

### 2. Reentrancy / auto-repeat guard

- Global `Converting: Boolean`. `WMConvertLast` / `WMConvertSelected` exit
  immediately if set; set on entry, cleared in `finally`.
- In the hook, trigger Pause handling only on the first WM_KEYDOWN
  (track `PauseDown: Boolean`, set on keydown, cleared on keyup); auto-repeat
  keydowns are still consumed (`Result := 1`) but do not post messages.

### 3. Robust copy/paste injection

- Before sending Ctrl+C: keep the synthetic `ReleaseShift`, then wait (via
  `WaitPump` polling `GetAsyncKeyState`) until physical Shift is up, timeout
  ~400 ms. Proceed anyway on timeout.
- Send modifiers spaced: Ctrl↓ — WaitPump(20) — key↓ key↑ — WaitPump(20) —
  Ctrl↑, each its own `SendInput` call (replaces the single 4-event batch in
  `SendCtrlKey`). Same helper used for both C and V.
- Keep the existing `SWATTR_MAGIC` marking on all injected events.

### 4. Case preservation in `VkToChar`

- Keep the existing working-tree Shift fix (`GetAsyncKeyState(VK_SHIFT)`).
- Change CapsLock read to `(GetKeyState(VK_CAPITAL) and 1) <> 0`
  (toggle bit; maintained globally for lock keys).

No changes needed in `uConverter.pas` — the CMAP table is already
case-complete in both directions.

### 5. Mini-notification window (replaces balloons)

- Borderless always-on-top popup near the tray corner (bottom-right work
  area), created with `WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW` — never takes
  focus, no taskbar button.
- Content: single line, e.g. `Ghbdsn → Привіт` (Pause) or
  `N символів перетворено` (Shift+Pause). Follows app font; padding ~8 px.
- Auto-hides after ~1.2 s via TTimer. A new notification while one is visible
  replaces the text and restarts the timer (single window instance).
- Both `TrayIcon1.ShowBalloonHint` call sites switch to this window; balloon
  code removed.

### 6. Build & verify

- Rebuild SwATR.exe (Release) from current sources.
- Manual verification checklist:
  - `Ghbdsn` + Pause → `Привіт`; `GHBDSN` (CapsLock) + Pause → `ПРИВІТ`;
    mixed `GhBdSn` → `ПрИвІт`.
  - Rapid repeated Pause presses: no system-wide keyboard lag; conversions
    toggle cleanly; hook stays alive afterwards.
  - Shift+Pause on selected text in Notepad, VS Code, browser: converted
    text pasted, no stray `v`, works while Shift held a beat too long.
  - Mini-notification appears ~1.2 s, steals no focus.

## Out of scope

- No changes to clipboard history, layout cycling (RCtrl), tray icon, About.
- No redesign of KeyBuffer tracking beyond the CapsLock line.

## Error handling

- Copy failure (empty clipboard after Ctrl+C): silent exit, as today.
- `Converting` guard cleared in `finally` so a failure never wedges the
  feature.
- Timeout waiting for physical Shift release: proceed with the copy anyway
  (worst case equals current behavior).
