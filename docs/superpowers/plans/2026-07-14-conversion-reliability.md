# SwATR Conversion Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix case loss on Pause conversion, stray `v` on Shift+Pause, system-wide input freezes from hook-thread sleeps, and replace long-lived balloons with a ~1.2 s mini-notification.

**Architecture:** All waits on the main thread (which services the WH_KEYBOARD_LL hook) become message-pumping waits (`WaitPump`); conversion handlers get a reentrancy guard; Ctrl+C/Ctrl+V injection is spaced in time; a new focus-stealing-free popup unit `uToastForm.pas` replaces `ShowBalloonHint`.

**Tech Stack:** Delphi 13 (RAD Studio 37.0), VCL, Win32 API. Build via MSBuild + rsvars.bat. No unit-test framework exists in this repo and the changes are Win32 hook/injection behavior — the per-task gate is a clean Release compile; end-to-end behavior is verified manually in Task 5 (checklist from the spec).

**Spec:** `docs/superpowers/specs/2026-07-14-conversion-reliability-design.md`

## Global Constraints

- Never call `Sleep` on the main thread in conversion/clipboard paths — it stalls all keyboard input system-wide (LL hook lives on this thread).
- All synthetic input events must carry `dwExtraInfo := SWATTR_MAGIC`.
- Out of scope: clipboard history, RCtrl layout cycling, tray icon drawing, About dialog, `uConverter.pas` (its CMAP is already case-complete). `uHistoryForm.pas:281` `Sleep(80)` stays as is.
- Delphi pitfalls in this codebase: hook proc's `lParam` param shadows type `LPARAM`; `#NNNN` decimal escapes for non-ASCII in string literals kept as they are; PowerShell 5.1 has no `&&`.
- Build command (PowerShell, from `d:\Work\D13\SwATR`):
  ```powershell
  try { Stop-Process -Name SwATR -Force -ErrorAction Stop } catch {}
  & cmd /c "`"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat`" && msbuild SwATR.dproj /t:Build /p:Config=Release /p:Platform=Win32 /v:m"
  ```
  Expected: `Build succeeded.` and a fresh timestamp on `d:\Work\D13\SwATR\SwATR.exe`.

---

### Task 1: CapsLock toggle read in VkToChar

**Files:**
- Modify: `uMain.pas:343-356` (`VkToChar`)

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature changes — `VkToChar(vk, scan: UINT): WideChar` behavior fix only.

- [ ] **Step 1: Fix the CapsLock check**

In `VkToChar`, replace the line

```pascal
  if (GetAsyncKeyState(VK_CAPITAL) and $0001) <> 0 then KS[VK_CAPITAL] := $01;
```

with

```pascal
  // Toggle state: low bit of GetKeyState. GetAsyncKeyState's low bit is
  // "pressed since last call", not the toggle.
  if (GetKeyState(VK_CAPITAL) and 1) <> 0 then KS[VK_CAPITAL] := $01;
```

- [ ] **Step 2: Compile**

Run the build command from Global Constraints. Expected: `Build succeeded.`

- [ ] **Step 3: Commit**

```powershell
git add uMain.pas
git commit -m "Fix CapsLock detection in VkToChar (GetKeyState toggle bit)"
```

---

### Task 2: WaitPump / WaitShiftUp helpers, spaced SendCtrlKey, non-blocking clipboard retries

**Files:**
- Modify: `uMain.pas` — "Input helpers" section (currently starts at line 251), `SendCtrlKey` (296-308), `ClipGetText` (Sleep at 533), `ClipSetText` (Sleep at 576)

**Interfaces:**
- Consumes: existing `SWATTR_MAGIC` const, `ReleaseShift` (unchanged).
- Produces (used by Task 3):
  - `procedure WaitPump(Ms: Cardinal);` — waits ~Ms milliseconds while pumping messages.
  - `procedure WaitShiftUp(TimeoutMs: Cardinal);` — waits until physical L/R Shift released, or timeout.
  - `procedure SendCtrlKey(VK: WORD);` — same signature as today, now time-spaced.

- [ ] **Step 1: Add WaitPump and WaitShiftUp**

Insert at the top of the "Input helpers" section, immediately after the section banner comment (before `FillBackspaces`):

```pascal
// Waits ~Ms milliseconds WITHOUT blocking this thread's message pump.
// The WH_KEYBOARD_LL hook is serviced by this thread: a plain Sleep here
// makes Windows hold every keystroke system-wide until the hook timeout,
// then bypass (and eventually silently remove) the hook.
procedure WaitPump(Ms: Cardinal);
var
  Deadline: UInt64;
  M: TMsg;
begin
  Deadline := GetTickCount64 + Ms;
  repeat
    while PeekMessage(M, 0, 0, 0, PM_REMOVE) do
    begin
      if M.message = WM_QUIT then
      begin
        PostQuitMessage(Integer(M.wParam));
        Exit;
      end;
      TranslateMessage(M);
      DispatchMessage(M);
    end;
    if GetTickCount64 >= Deadline then
      Break;
    MsgWaitForMultipleObjects(0, Pointer(nil)^, False,
      DWORD(Deadline - GetTickCount64), QS_ALLINPUT);
  until False;
end;

// Wait until the physical Shift keys are released, up to TimeoutMs.
// Proceeds anyway on timeout (worst case equals current behavior).
procedure WaitShiftUp(TimeoutMs: Cardinal);
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + TimeoutMs;
  while ((GetAsyncKeyState(VK_LSHIFT) and $8000) <> 0) or
        ((GetAsyncKeyState(VK_RSHIFT) and $8000) <> 0) do
  begin
    if GetTickCount64 >= Deadline then
      Break;
    WaitPump(10);
  end;
end;
```

- [ ] **Step 2: Rewrite SendCtrlKey with time-spaced injection**

Replace the whole `SendCtrlKey` procedure (currently the single 4-event `SendInput` batch) with:

```pascal
// Sends Ctrl+<VK> with the modifier spaced out in time. A single 4-event
// batch can reach the target app with Ctrl no longer seen as held when
// hook processing is delayed — the app then types the bare letter.
procedure SendCtrlKey(VK: WORD);

  procedure SendOne(AVk: WORD; AFlags: DWORD);
  var
    Inp: TInput;
  begin
    FillChar(Inp, SizeOf(Inp), 0);
    Inp.Itype := INPUT_KEYBOARD;
    Inp.ki.wVk := AVk;
    Inp.ki.dwFlags := AFlags;
    Inp.ki.dwExtraInfo := SWATTR_MAGIC;
    SendInput(1, Inp, SizeOf(TInput));
  end;

begin
  SendOne(VK_CONTROL, 0);
  WaitPump(20);
  SendOne(VK, 0);
  SendOne(VK, KEYEVENTF_KEYUP);
  WaitPump(20);
  SendOne(VK_CONTROL, KEYEVENTF_KEYUP);
end;
```

Note: `SendCtrlKey` must appear AFTER `WaitPump` in the file (single-pass compiler).

- [ ] **Step 3: Replace clipboard retry sleeps**

In `ClipGetText`, replace

```pascal
    Sleep(30); // clipboard busy — wait and retry
```

with

```pascal
    WaitPump(30); // clipboard busy — wait and retry
```

In `ClipSetText`, replace

```pascal
    Sleep(30);
```

with

```pascal
    WaitPump(30);
```

(`ClipGetText`/`ClipSetText` appear later in the file than `WaitPump`, so no forward-declaration issues.)

- [ ] **Step 4: Compile**

Run the build command. Expected: `Build succeeded.`

- [ ] **Step 5: Commit**

```powershell
git add uMain.pas
git commit -m "Add message-pumping waits; space out Ctrl+key injection"
```

---

### Task 3: Reentrancy guard, Pause auto-repeat latch, non-blocking conversion handlers

**Files:**
- Modify: `uMain.pas` — globals block (currently lines 69-72), `LowLevelKeyboardProc` Pause handling (412-421), `WMConvertLast` (468-496), `WMConvertSelected` (581-617)

**Interfaces:**
- Consumes: `WaitPump`, `WaitShiftUp`, `SendCtrlKey` from Task 2; existing `ReleaseShift`, `ClipGetText`, `ClipSetText`, `ConvertText`, `IsUkrText`, `SwitchFgToLang`, `FillBackspaces`, `FillUnicodeText`.
- Produces: globals `Converting: Boolean` and `PauseDown: Boolean` (also read by Task 4? No — Task 4 only adds the toast; nothing else consumes these).

- [ ] **Step 1: Add guard globals**

In the Globals var block, extend:

```pascal
var
  HookHandle:   HHOOK;
  KeyBuffer:    string;
  RCtrlDown:    Boolean;
  Converting:   Boolean; // a conversion is in progress — drop re-triggers
  PauseDown:    Boolean; // Pause held — ignore auto-repeat keydowns
```

- [ ] **Step 2: Latch Pause in the hook**

In `LowLevelKeyboardProc`, insert a Pause keyup handler right AFTER the RCtrl block (`// ---- Right Ctrl: tap = switch layout ----` … `end;`) and BEFORE the `if (wParam = WM_KEYDOWN) or (wParam = WM_SYSKEYDOWN) then` block:

```pascal
  // Pause keyup: reset the first-press latch (keydown is consumed below,
  // so consume the matching keyup as well)
  if ((wParam = WM_KEYUP) or (wParam = WM_SYSKEYUP)) and
     (KHS^.vkCode = VK_PAUSE) then
  begin
    PauseDown := False;
    Result := 1;
    Exit;
  end;
```

Then replace the existing Pause keydown block

```pascal
    // ---- Pause / Shift+Pause ----
    if KHS^.vkCode = VK_PAUSE then
    begin
      if (GetAsyncKeyState(VK_SHIFT) and $8000) <> 0 then
        PostMessage(frmMain.Handle, WM_CONVERT_SELECTED, 0, 0)
      else
        PostMessage(frmMain.Handle, WM_CONVERT_LAST, 0, 0);
      Result := 1;
      Exit;
    end;
```

with

```pascal
    // ---- Pause / Shift+Pause ----
    if KHS^.vkCode = VK_PAUSE then
    begin
      // Trigger only on the first keydown (holding Pause auto-repeats)
      // and only when no conversion is already running.
      if not PauseDown then
      begin
        PauseDown := True;
        if not Converting then
        begin
          if (GetAsyncKeyState(VK_SHIFT) and $8000) <> 0 then
            PostMessage(frmMain.Handle, WM_CONVERT_SELECTED, 0, 0)
          else
            PostMessage(frmMain.Handle, WM_CONVERT_LAST, 0, 0);
        end;
      end;
      Result := 1;
      Exit;
    end;
```

- [ ] **Step 3: Guard WMConvertLast**

Replace the whole `WMConvertLast` body with (also removes the duplicated `ConvertText` call):

```pascal
procedure TfrmMain.WMConvertLast(var Msg: TMessage);
var
  Buf, Conv: string;
  Inp: array of TInput;
  Idx: Integer;
begin
  if Converting then Exit;
  Converting := True;
  try
    Buf := KeyBuffer;
    KeyBuffer := '';
    if Buf = '' then Exit;
    Conv := ConvertText(Buf);
    if Conv = Buf then Exit;

    SetLength(Inp, (Length(Buf) + Length(Conv)) * 2);
    Idx := 0;
    FillBackspaces(Length(Buf), Inp, Idx);
    FillUnicodeText(Conv, Inp, Idx);
    SendInput(Idx, Inp[0], SizeOf(TInput));

    KeyBuffer := Conv;

    // Switch layout to match the converted text
    if IsUkrText(Conv) then
      SwitchFgToLang($0422)   // Ukrainian
    else
      SwitchFgToLang($0409);  // English (US)

    TrayIcon1.BalloonTitle := 'SwATR';
    TrayIcon1.BalloonHint  := Buf + ' '#$2192' ' + Conv;
    TrayIcon1.ShowBalloonHint;
  finally
    Converting := False;
  end;
end;
```

(The balloon lines stay for now — Task 4 replaces them with the toast.)

- [ ] **Step 4: Guard and de-sleep WMConvertSelected**

Replace the whole `WMConvertSelected` body with:

```pascal
procedure TfrmMain.WMConvertSelected(var Msg: TMessage);
var
  Sel, Conv: string;
begin
  if Converting then Exit;
  Converting := True;
  try
    KeyBuffer := '';

    // Wait for the user to physically release Shift (held from
    // Shift+Pause); if still held after 400 ms, release it synthetically
    // so Ctrl+C is not seen as Ctrl+Shift+C by the target app.
    WaitShiftUp(400);
    ReleaseShift;
    WaitPump(30);

    ClipSetText('');           // clear so we can detect if copy succeeded
    SendCtrlKey(Ord('C'));
    WaitPump(250);             // wait for target app to write to clipboard

    if not ClipGetText(Sel) then Exit;
    if Sel = '' then Exit;

    Conv := ConvertText(Sel);
    if Conv = Sel then Exit;

    ClipSetText(Conv);
    SendCtrlKey(Ord('V'));

    // Switch layout to match the converted text
    if IsUkrText(Conv) then
      SwitchFgToLang($0422)
    else
      SwitchFgToLang($0409);

    TrayIcon1.BalloonTitle := 'SwATR';
    TrayIcon1.BalloonHint  :=
      IntToStr(Length(Sel)) + ' ' +
      #1089#1080#1084#1074#1086#1083#1110#1074 + ' ' +
      #1087#1077#1088#1077#1090#1074#1086#1088#1077#1085#1086;
    TrayIcon1.ShowBalloonHint;
  finally
    Converting := False;
  end;
end;
```

- [ ] **Step 5: Compile**

Run the build command. Expected: `Build succeeded.`

- [ ] **Step 6: Commit**

```powershell
git add uMain.pas
git commit -m "Non-blocking conversion handlers with reentrancy guard and Pause latch"
```

---

### Task 4: Mini-notification window (uToastForm) replaces balloons

**Files:**
- Create: `uToastForm.pas`
- Modify: `SwATR.dpr` (uses list), `uMain.pas` (implementation uses; both balloon call sites)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `procedure ShowToast(const AText: string);` — shows/updates a single always-on-top, non-activating popup near the tray corner; auto-hides after 1200 ms.

- [ ] **Step 1: Create uToastForm.pas**

```pascal
// SwATR — transient notification popup (replaces tray balloons)
// Author : Andrii (ATR) Tarasenko
// License: MIT
unit uToastForm;

interface

procedure ShowToast(const AText: string);

implementation

uses
  Winapi.Windows, Winapi.Messages, System.Classes,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics;

type
  TToastForm = class(TForm)
  private
    FLabel: TLabel;
    FTimer: TTimer;
    procedure OnHideTimer(Sender: TObject);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    procedure Present(const AText: string);
  end;

var
  Toast: TToastForm;

procedure TToastForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := WS_POPUP;
  // Never steal focus, no taskbar button, stay above normal windows
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE or
    WS_EX_TOOLWINDOW or WS_EX_TOPMOST;
end;

constructor TToastForm.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited;
  BorderStyle := bsNone;
  Color       := $00303030;
  Font.Name   := 'Segoe UI';
  Font.Size   := 10;
  Font.Color  := clWhite;

  FLabel := TLabel.Create(Self);
  FLabel.Parent   := Self;
  FLabel.AutoSize := True;
  FLabel.Left     := 12;
  FLabel.Top      := 8;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled  := False;
  FTimer.Interval := 1200;
  FTimer.OnTimer  := OnHideTimer;
end;

procedure TToastForm.OnHideTimer(Sender: TObject);
begin
  FTimer.Enabled := False;
  ShowWindow(Handle, SW_HIDE);
end;

procedure TToastForm.Present(const AText: string);
var
  WA: TRect;
begin
  HandleNeeded;
  FLabel.Caption := AText;
  ClientWidth    := FLabel.Width + 24;
  ClientHeight   := FLabel.Height + 16;

  WA   := Screen.WorkAreaRect;
  Left := WA.Right - Width - 16;
  Top  := WA.Bottom - Height - 16;

  // Show via WinAPI (not Visible := True) so VCL focus logic never runs
  SetWindowPos(Handle, HWND_TOPMOST, Left, Top, Width, Height,
    SWP_NOACTIVATE or SWP_SHOWWINDOW);

  FTimer.Enabled := False;  // restart the hide timer on repeated calls
  FTimer.Enabled := True;
end;

procedure ShowToast(const AText: string);
begin
  if Toast = nil then
    Toast := TToastForm.CreateNew(nil);
  Toast.Present(AText);
end;

end.
```

- [ ] **Step 2: Register the unit in SwATR.dpr**

In `SwATR.dpr`, extend the uses list:

```pascal
uses
  Vcl.Forms,
  uMain      in 'uMain.pas' {frmMain},
  uConverter in 'uConverter.pas',
  uClipHistory in 'uClipHistory.pas',
  uHistoryForm in 'uHistoryForm.pas',
  uToastForm in 'uToastForm.pas';
```

- [ ] **Step 3: Switch uMain call sites to ShowToast**

In `uMain.pas` implementation uses (currently `Vcl.Clipbrd, Vcl.StdCtrls, System.Win.Registry, uClipHistory, uHistoryForm;`) add `uToastForm`:

```pascal
uses
  Vcl.Clipbrd, Vcl.StdCtrls, System.Win.Registry,
  uClipHistory,
  uHistoryForm,
  uToastForm;
```

In `WMConvertLast`, replace

```pascal
    TrayIcon1.BalloonTitle := 'SwATR';
    TrayIcon1.BalloonHint  := Buf + ' '#$2192' ' + Conv;
    TrayIcon1.ShowBalloonHint;
```

with

```pascal
    ShowToast(Buf + ' '#$2192' ' + Conv);
```

In `WMConvertSelected`, replace

```pascal
    TrayIcon1.BalloonTitle := 'SwATR';
    TrayIcon1.BalloonHint  :=
      IntToStr(Length(Sel)) + ' ' +
      #1089#1080#1084#1074#1086#1083#1110#1074 + ' ' +
      #1087#1077#1088#1077#1090#1074#1086#1088#1077#1085#1086;
    TrayIcon1.ShowBalloonHint;
```

with

```pascal
    ShowToast(IntToStr(Length(Sel)) + ' ' +
      #1089#1080#1084#1074#1086#1083#1110#1074 + ' ' +
      #1087#1077#1088#1077#1090#1074#1086#1088#1077#1085#1086);
```

- [ ] **Step 4: Compile**

Run the build command. Expected: `Build succeeded.`

- [ ] **Step 5: Commit**

```powershell
git add uToastForm.pas SwATR.dpr uMain.pas
git commit -m "Replace tray balloons with 1.2s non-activating toast popup"
```

---

### Task 5: Version bump, Release build, manual verification

**Files:**
- Modify: `uMain.pas:14` (`APP_VERSION`)

**Interfaces:**
- Consumes: everything above.
- Produces: shippable `SwATR.exe` 1.3.1.

- [ ] **Step 1: Bump version**

```pascal
  APP_VERSION         = '1.3.1';
```

- [ ] **Step 2: Release build**

Run the build command. Expected: `Build succeeded.`, fresh `SwATR.exe` timestamp.

- [ ] **Step 3: Launch and verify manually (with the user)**

Start `d:\Work\D13\SwATR\SwATR.exe`. Checklist (from the spec) — ask the user to confirm each:

1. In Notepad type `Ghbdsn` (Shift for G), press Pause → `Привіт` (case preserved).
2. With CapsLock ON type `GHBDSN`, press Pause → `ПРИВІТ`.
3. Type `GhBdSn` (mixed via Shift), press Pause → `ПрИвІт`.
4. Press Pause rapidly 5-6 times: conversions toggle cleanly, no system-wide keyboard lag, hotkeys still work afterwards (hook not removed).
5. Hold Pause for 2 s: exactly one conversion (auto-repeat ignored).
6. Select text in Notepad, VS Code and a browser, press Shift+Pause (including holding Shift a beat too long) → converted text pasted, no stray `v`, no `Ctrl+Shift+C` side effects.
7. Toast popup appears bottom-right for ~1.2 s, does not steal focus from the app being typed in.

- [ ] **Step 4: Commit and merge the pre-existing working-tree changes**

The working tree already contained uncommitted fixes (VkToChar Shift state, SwitchFgToLang AttachThreadInput, .gitignore, .dproj icon/resources). After verification commit everything:

```powershell
git add -A
git commit -m "v1.3.1: preserve case on conversion, non-blocking hook waits, toast notifications"
```

Do NOT push — the user pushes manually (per user preference).
