// SwATR — keyboard layout switcher for Windows
// Author : Andrii (ATR) Tarasenko
// License: MIT
unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils,
  Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls, Vcl.Menus, Vcl.Graphics,
  uConverter, System.Classes;

const
  APP_VERSION         = '1.3.1';
  WM_CONVERT_LAST     = WM_USER + 10;
  WM_CONVERT_SELECTED = WM_USER + 11;
  WM_SWITCH_LAYOUT    = WM_USER + 12;
  WM_SHOW_HISTORY     = WM_USER + 13;
  SWATTR_MAGIC        = $5741544E;

type
  TKbdllHookStruct = record
    vkCode:      DWORD;
    scanCode:    DWORD;
    flags:       DWORD;
    time:        DWORD;
    dwExtraInfo: NativeUInt;
  end;
  PKbdllHookStruct = ^TKbdllHookStruct;

  TfrmMain = class(TForm)
    TrayIcon1: TTrayIcon;
    PopupMenu1: TPopupMenu;
    miAbout: TMenuItem;
    N1: TMenuItem;
    miExit: TMenuItem;
    procedure CreateParams(var Params: TCreateParams); override;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure miExitClick(Sender: TObject);
    procedure miAboutClick(Sender: TObject);
  private
    FCurrentHkl: HKL;
    procedure WMConvertLast(var Msg: TMessage);     message WM_CONVERT_LAST;
    procedure WMConvertSelected(var Msg: TMessage); message WM_CONVERT_SELECTED;
    procedure WMSwitchLayout(var Msg: TMessage);    message WM_SWITCH_LAYOUT;
    procedure WMShowHistory(var Msg: TMessage);     message WM_SHOW_HISTORY;
    procedure WMClipboardUpdate(var Msg: TMessage); message $031D; // WM_CLIPBOARDUPDATE
    procedure UpdateTrayIcon;
    procedure OnLayoutTimer(Sender: TObject);
  end;

var
  frmMain: TfrmMain;

implementation

uses
  Vcl.Clipbrd, Vcl.StdCtrls, System.Win.Registry,
  uClipHistory,
  uHistoryForm,
  uToastForm;

{$R *.dfm}

// -----------------------------------------------------------------------
// Globals
// -----------------------------------------------------------------------

var
  HookHandle:   HHOOK;
  KeyBuffer:    string;
  RCtrlDown:    Boolean;
  Converting:   Boolean; // a conversion is in progress — drop re-triggers
  PauseDown:    Boolean; // Pause held — ignore auto-repeat keydowns

// -----------------------------------------------------------------------
// Layout helpers
// -----------------------------------------------------------------------

function GetFgHkl: HKL;
var
  Wnd: HWND;
  Tid: DWORD;
begin
  Wnd := GetForegroundWindow;
  Tid := GetWindowThreadProcessId(Wnd, nil);
  Result := GetKeyboardLayout(Tid);
end;

function LayoutName(ALayout: HKL): string;
var
  LangID: WORD;
begin
  LangID := WORD(NativeUInt(ALayout) and $FFFF);
  case LangID of
    $0409: Result := 'EN';
    $0422: Result := 'UA';
    $0419: Result := 'RU';
    $040C: Result := 'FR';
    $0407: Result := 'DE';
    $0415: Result := 'PL';
    else   Result := IntToHex(LangID, 4);
  end;
end;

// -----------------------------------------------------------------------
// Icon factory — shared by tray (dynamic) and app / About (static logo)
// -----------------------------------------------------------------------

// Static SwATR logo: dark bg, 'UA' yellow top half, 'EN' blue bottom half
function CreateSwAtrIcon(ASize: Integer): HICON;
var
  Bmp, Msk: TBitmap;
  Ii: TIconInfo;
  C: TCanvas;
  Half, TW, TH: Integer;
begin
  Result := 0;
  Bmp := TBitmap.Create;
  Msk := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.Width  := ASize;
    Bmp.Height := ASize;
    C := Bmp.Canvas;
    C.Brush.Color := $00222222;
    C.FillRect(Rect(0, 0, ASize, ASize));

    Half := ASize div 2;
    SetBkMode(C.Handle, TRANSPARENT);
    C.Font.Name  := 'Arial';
    C.Font.Style := [fsBold];

    // Top half: 'UA' in yellow
    C.Font.Height := -(Half - 1);
    C.Font.Color  := $0000FFFF;
    TW := C.TextWidth('UA');
    TH := C.TextHeight('UA');
    C.TextOut((ASize - TW) div 2, (Half - TH) div 2, 'UA');

    // Bottom half: 'EN' in blue
    C.Font.Color := $00FF8800;
    TW := C.TextWidth('EN');
    TH := C.TextHeight('EN');
    C.TextOut((ASize - TW) div 2, Half + (Half - TH) div 2, 'EN');

    // Thin divider
    C.Pen.Color := $00666666;
    C.MoveTo(ASize div 4,     Half);
    C.LineTo(ASize * 3 div 4, Half);

    Msk.PixelFormat := pf1bit;
    Msk.Width  := ASize;
    Msk.Height := ASize;
    Msk.Canvas.Brush.Color := clBlack;
    Msk.Canvas.FillRect(Rect(0, 0, ASize, ASize));

    ZeroMemory(@Ii, SizeOf(Ii));
    Ii.fIcon    := True;
    Ii.hbmMask  := Msk.Handle;
    Ii.hbmColor := Bmp.Handle;
    Result := CreateIconIndirect(Ii);
  finally
    Bmp.Free;
    Msk.Free;
  end;
end;

// -----------------------------------------------------------------------
// Tray icon: draw layout abbreviation as 16x16 icon
// -----------------------------------------------------------------------

procedure TfrmMain.UpdateTrayIcon;
var
  Sz: Integer;
  Bmp, Msk: TBitmap;
  Ii: TIconInfo;
  Hic: HICON;
  Name: string;
  TW, TH: Integer;
begin
  Sz := GetSystemMetrics(SM_CXSMICON);  // 16 on 96dpi, 20/24 on higher
  Name := LayoutName(FCurrentHkl);

  Bmp := TBitmap.Create;
  Msk := TBitmap.Create;
  try
    // Color layer
    Bmp.PixelFormat := pf24bit;
    Bmp.Width := Sz;
    Bmp.Height := Sz;
    Bmp.Canvas.Brush.Color := $00222222;
    Bmp.Canvas.FillRect(Rect(0, 0, Sz, Sz));

    SetBkMode(Bmp.Canvas.Handle, TRANSPARENT);
    Bmp.Canvas.Font.Name := 'Arial';
    Bmp.Canvas.Font.Height := -(Sz - 4);
    Bmp.Canvas.Font.Style := [fsBold];
    if Name = 'UA' then
      Bmp.Canvas.Font.Color := $0000FFFF   // yellow (BGR)
    else if Name = 'EN' then
      Bmp.Canvas.Font.Color := $00FF8800   // blue (BGR)
    else
      Bmp.Canvas.Font.Color := clWhite;

    TW := Bmp.Canvas.TextWidth(Name);
    TH := Bmp.Canvas.TextHeight(Name);
    Bmp.Canvas.TextOut((Sz - TW) div 2, (Sz - TH) div 2, Name);

    // Mask: all black = fully visible
    Msk.Width := Sz;
    Msk.Height := Sz;
    Msk.Canvas.Brush.Color := clBlack;
    Msk.Canvas.FillRect(Rect(0, 0, Sz, Sz));

    ZeroMemory(@Ii, SizeOf(Ii));
    Ii.fIcon    := True;
    Ii.hbmMask  := Msk.Handle;
    Ii.hbmColor := Bmp.Handle;
    Hic := CreateIconIndirect(Ii);
    if Hic <> 0 then
      TrayIcon1.Icon.Handle := Hic;
  finally
    Bmp.Free;
    Msk.Free;
  end;

  // Tooltip: show layout name + version
  TrayIcon1.Hint :=
    'SwATR v' + APP_VERSION + '  [' + Name + ']' + #13#10 +
    'Pause'#9'     - ' + #1087#1077#1088#1077#1090#1074#1086#1088#1080#1090#1080 + ' ' + #1085#1072#1073#1088#1072#1085#1077 + #13#10 +
    'Shift+Pause - ' + #1090#1077#1082#1089#1090 + #13#10 +
    'RCtrl'#9'     - ' + #1079#1084#1110#1085#1080#1090#1080 + ' ' + #1088#1086#1079#1082#1083#1072#1076#1082#1091 + #13#10 +
    'Ctrl+`'#9'   - ' + #1073#1091#1092#1077#1088 + ' ' + #1086#1073#1084#1110#1085#1091;
end;

// -----------------------------------------------------------------------
// Timer: check if foreground window layout changed
// -----------------------------------------------------------------------

procedure TfrmMain.OnLayoutTimer(Sender: TObject);
var
  CurLayout: HKL;
begin
  CurLayout := GetFgHkl;
  if CurLayout <> FCurrentHkl then
  begin
    FCurrentHkl := CurLayout;
    UpdateTrayIcon;
  end;
end;

// -----------------------------------------------------------------------
// Input helpers
// -----------------------------------------------------------------------

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

procedure FillBackspaces(Count: Integer; var Inp: array of TInput; var Idx: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
  begin
    FillChar(Inp[Idx], SizeOf(TInput), 0);
    Inp[Idx].Itype := INPUT_KEYBOARD;
    Inp[Idx].ki.wVk := VK_BACK;
    Inp[Idx].ki.dwExtraInfo := SWATTR_MAGIC;
    Inc(Idx);
    FillChar(Inp[Idx], SizeOf(TInput), 0);
    Inp[Idx].Itype := INPUT_KEYBOARD;
    Inp[Idx].ki.wVk := VK_BACK;
    Inp[Idx].ki.dwFlags := KEYEVENTF_KEYUP;
    Inp[Idx].ki.dwExtraInfo := SWATTR_MAGIC;
    Inc(Idx);
  end;
end;

procedure FillUnicodeText(const Text: string; var Inp: array of TInput; var Idx: Integer);
var
  I: Integer;
begin
  for I := 1 to Length(Text) do
  begin
    FillChar(Inp[Idx], SizeOf(TInput), 0);
    Inp[Idx].Itype := INPUT_KEYBOARD;
    Inp[Idx].ki.wScan := Ord(Text[I]);
    Inp[Idx].ki.dwFlags := KEYEVENTF_UNICODE;
    Inp[Idx].ki.dwExtraInfo := SWATTR_MAGIC;
    Inc(Idx);
    FillChar(Inp[Idx], SizeOf(TInput), 0);
    Inp[Idx].Itype := INPUT_KEYBOARD;
    Inp[Idx].ki.wScan := Ord(Text[I]);
    Inp[Idx].ki.dwFlags := KEYEVENTF_UNICODE or KEYEVENTF_KEYUP;
    Inp[Idx].ki.dwExtraInfo := SWATTR_MAGIC;
    Inc(Idx);
  end;
end;

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

// Release any physically-held Shift keys so Ctrl+C arrives without Shift
procedure ReleaseShift;
var
  Inp: array[0..1] of TInput;
  N: Integer;
begin
  N := 0;
  if (GetAsyncKeyState(VK_LSHIFT) and $8000) <> 0 then
  begin
    FillChar(Inp[N], SizeOf(TInput), 0);
    Inp[N].Itype := INPUT_KEYBOARD;
    Inp[N].ki.wVk := VK_LSHIFT;
    Inp[N].ki.dwFlags := KEYEVENTF_KEYUP;
    Inp[N].ki.dwExtraInfo := SWATTR_MAGIC;
    Inc(N);
  end;
  if (GetAsyncKeyState(VK_RSHIFT) and $8000) <> 0 then
  begin
    FillChar(Inp[N], SizeOf(TInput), 0);
    Inp[N].Itype := INPUT_KEYBOARD;
    Inp[N].ki.wVk := VK_RSHIFT;
    Inp[N].ki.dwFlags := KEYEVENTF_KEYUP;
    Inp[N].ki.dwExtraInfo := SWATTR_MAGIC;
    Inc(N);
  end;
  if N > 0 then
    SendInput(N, Inp[0], SizeOf(TInput));
end;

// -----------------------------------------------------------------------
// Character buffer helper
// -----------------------------------------------------------------------

function VkToChar(vk, scan: UINT): WideChar;
var
  KS: TKeyboardState;
  Buf: array[0..3] of WideChar;
begin
  Result := #0;
  // Build KS from async state: GetKeyboardState reads the calling thread's
  // state, which in a LL hook is SwATR's thread — Shift is not reflected there.
  ZeroMemory(@KS, SizeOf(KS));
  if (GetAsyncKeyState(VK_SHIFT)   and $8000) <> 0 then KS[VK_SHIFT]   := $80;
  // Toggle state: low bit of GetKeyState. GetAsyncKeyState's low bit is
  // "pressed since last call", not the toggle.
  if (GetKeyState(VK_CAPITAL) and 1) <> 0 then KS[VK_CAPITAL] := $01;
  if ToUnicodeEx(vk, scan, KS, Buf, 4, 0, GetFgHkl) = 1 then
    Result := Buf[0];
end;

// -----------------------------------------------------------------------
// Low-level keyboard hook
// -----------------------------------------------------------------------

function LowLevelKeyboardProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  KHS: PKbdllHookStruct;
  IsCtrl, IsAlt: Boolean;
  Ch: WideChar;
begin
  Result := 0;

  if nCode < 0 then
  begin
    Result := CallNextHookEx(HookHandle, nCode, wParam, lParam);
    Exit;
  end;

  KHS := PKbdllHookStruct(lParam);

  if KHS^.dwExtraInfo = SWATTR_MAGIC then
  begin
    Result := CallNextHookEx(HookHandle, nCode, wParam, lParam);
    Exit;
  end;

  // ---- Right Ctrl: tap = switch layout ----
  if KHS^.vkCode = VK_RCONTROL then
  begin
    if wParam = WM_KEYDOWN then
      RCtrlDown := True
    else if (wParam = WM_KEYUP) and RCtrlDown then
    begin
      RCtrlDown := False;
      PostMessage(frmMain.Handle, WM_SWITCH_LAYOUT, 0, 0);
    end;
    Result := 1; // always consume RCtrl
    Exit;
  end;

  // Pause keyup: reset the first-press latch (keydown is consumed below,
  // so consume the matching keyup as well)
  if ((wParam = WM_KEYUP) or (wParam = WM_SYSKEYUP)) and
     (KHS^.vkCode = VK_PAUSE) then
  begin
    PauseDown := False;
    Result := 1;
    Exit;
  end;

  if (wParam = WM_KEYDOWN) or (wParam = WM_SYSKEYDOWN) then
  begin
    IsCtrl := (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0;
    IsAlt  := (GetAsyncKeyState(VK_MENU)    and $8000) <> 0;

    // ---- Ctrl+` : clipboard history ----
    if (KHS^.vkCode = $C0) and IsCtrl then
    begin
      PostMessage(frmMain.Handle, WM_SHOW_HISTORY,
        0, NativeInt(GetForegroundWindow));
      Result := 1;
      Exit;
    end;

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

    // ---- Buffer tracking ----
    if IsCtrl or IsAlt then
      KeyBuffer := ''
    else
    begin
      case KHS^.vkCode of
        VK_BACK:
          if Length(KeyBuffer) > 0 then
            Delete(KeyBuffer, Length(KeyBuffer), 1);

        VK_SPACE:
          KeyBuffer := KeyBuffer + ' '; // accumulate spaces between words

        VK_RETURN, VK_TAB, VK_ESCAPE,
        VK_DELETE, VK_INSERT,
        VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN,
        VK_HOME, VK_END, VK_PRIOR, VK_NEXT:
          KeyBuffer := '';

        VK_SHIFT, VK_CONTROL, VK_MENU,
        VK_LWIN, VK_RWIN, VK_APPS,
        VK_CAPITAL, VK_NUMLOCK, VK_SCROLL, VK_SNAPSHOT,
        VK_F1..VK_F24:
          ;

        else
        begin
          Ch := VkToChar(KHS^.vkCode, KHS^.scanCode);
          if Ord(Ch) >= 32 then
            KeyBuffer := KeyBuffer + Ch;
        end;
      end;
    end;
  end;

  Result := CallNextHookEx(HookHandle, nCode, wParam, lParam);
end;

procedure SwitchFgToLang(LangID: WORD); forward;

// -----------------------------------------------------------------------
// Message handlers
// -----------------------------------------------------------------------

// Pause — convert last typed word
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

    ShowToast(Buf + ' '#$2192' ' + Conv);
  finally
    Converting := False;
  end;
end;

// ---- Direct WinAPI clipboard helpers (no VCL, with retry on EACCES) ----

function ClipGetText(out Text: string): Boolean;
var
  Tries: Integer;
  hData: THandle;
  pData: Pointer;
begin
  Result := False;
  Text   := '';
  for Tries := 1 to 8 do
  begin
    if OpenClipboard(0) then
    begin
      try
        if IsClipboardFormatAvailable(CF_UNICODETEXT) then
        begin
          hData := GetClipboardData(CF_UNICODETEXT);
          if hData <> 0 then
          begin
            pData := GlobalLock(hData);
            if pData <> nil then
            try
              Text   := string(PWideChar(pData));
              Result := Text <> '';
            finally
              GlobalUnlock(hData);
            end;
          end;
        end;
      finally
        CloseClipboard;
      end;
      Exit; // opened OK — don't retry even if empty
    end;
    WaitPump(30); // clipboard busy — wait and retry
  end;
end;

procedure ClipSetText(const Text: string);
var
  Tries: Integer;
  hData: THandle;
  pData: Pointer;
  Sz: NativeUInt;
begin
  for Tries := 1 to 5 do
  begin
    if OpenClipboard(0) then
    begin
      try
        EmptyClipboard;
        Sz    := (Length(Text) + 1) * SizeOf(WideChar);
        hData := GlobalAlloc(GMEM_MOVEABLE, Sz);
        if hData <> 0 then
        begin
          pData := GlobalLock(hData);
          if pData <> nil then
          begin
            try
              if Length(Text) > 0 then
                Move(PWideChar(Text)^, pData^, Sz)
              else
                PWideChar(pData)^ := #0;
            finally
              GlobalUnlock(hData);
            end;
            if SetClipboardData(CF_UNICODETEXT, hData) = 0 then
              GlobalFree(hData);
          end
          else
            GlobalFree(hData);
        end;
      finally
        CloseClipboard;
      end;
      Exit;
    end;
    WaitPump(30);
  end;
end;

// Shift+Pause — convert selected text via clipboard
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

    ShowToast(IntToStr(Length(Sel)) + ' ' +
      #1089#1080#1084#1074#1086#1083#1110#1074 + ' ' +
      #1087#1077#1088#1077#1090#1074#1086#1088#1077#1085#1086);
  finally
    Converting := False;
  end;
end;

// Switch foreground window to a specific language (by LANGID, e.g. $0422=UA, $0409=EN)
// Silently skips if that layout is not installed.
procedure SwitchFgToLang(LangID: WORD);
var
  FgWnd:   HWND;
  FgTid:   DWORD;
  OurTid:  DWORD;
  Buf:     array[0..31] of HKL;
  Cnt, I:  Integer;
  Target:  HKL;
begin
  FgWnd := GetForegroundWindow;
  if FgWnd = 0 then Exit;
  FgTid := GetWindowThreadProcessId(FgWnd, nil);

  Cnt := GetKeyboardLayoutList(32, Buf[0]);
  Target := 0;
  for I := 0 to Cnt - 1 do
    if WORD(NativeUInt(Buf[I]) and $FFFF) = LangID then
    begin
      Target := Buf[I];
      Break;
    end;

  if Target = 0 then Exit;

  // AttachThreadInput lets ActivateKeyboardLayout take effect in the target thread.
  // PostMessage(WM_INPUTLANGCHANGEREQUEST) is ignored by many apps that don't
  // forward it to DefWindowProc.
  OurTid := GetCurrentThreadId;
  if OurTid <> FgTid then
    AttachThreadInput(OurTid, FgTid, True);
  ActivateKeyboardLayout(Target, 0);
  if OurTid <> FgTid then
    AttachThreadInput(OurTid, FgTid, False);
end;

// Right Ctrl — cycle to next installed keyboard layout
procedure TfrmMain.WMSwitchLayout(var Msg: TMessage);
type
  THklBuf = array[0..31] of HKL;
var
  FgWnd:    HWND;
  FgTid:    DWORD;
  Cur, Nxt: HKL;
  Buf:      THklBuf;
  Cnt, I:   Integer;
begin
  FgWnd := GetForegroundWindow;
  if FgWnd = 0 then Exit;

  FgTid := GetWindowThreadProcessId(FgWnd, nil);
  Cur   := GetKeyboardLayout(FgTid);

  Cnt := GetKeyboardLayoutList(32, Buf[0]);
  if Cnt = 0 then Exit;

  Nxt := Buf[0]; // default: wrap to first
  for I := 0 to Cnt - 1 do
    if Buf[I] = Cur then
    begin
      if I + 1 < Cnt then Nxt := Buf[I + 1]
      else               Nxt := Buf[0];
      Break;
    end;

  PostMessage(FgWnd, WM_INPUTLANGCHANGEREQUEST, 0, LPARAM(Nxt));
end;

// Capture every clipboard change into history
procedure TfrmMain.WMClipboardUpdate(var Msg: TMessage);
var
  Txt: string;
  Bmp: TBitmap;
begin
  if IsClipboardFormatAvailable(CF_UNICODETEXT) then
  begin
    if ClipGetText(Txt) and (Txt <> '') then
    begin
      // Skip if identical to the most recent entry (some apps fire update twice)
      if (ClipHistory.Count = 0) or
         (ClipHistory[0].Kind <> ckText) or
         (Trim(ClipHistory[0].Text) <> Trim(Txt)) then
        ClipHistory.PushText(Txt);
    end;
  end
  else if IsClipboardFormatAvailable(CF_BITMAP) or
          IsClipboardFormatAvailable(CF_DIB) then
  begin
    Bmp := TBitmap.Create;
    try
      try
        Bmp.Assign(Clipboard);
        if (Bmp.Width > 0) and (Bmp.Height > 0) then
          ClipHistory.PushBitmap(Bmp);
      except end;
    finally
      Bmp.Free;
    end;
  end;
end;

// Ctrl+` — show history popup
procedure TfrmMain.WMShowHistory(var Msg: TMessage);
begin
  ShowClipHistory(HWND(Msg.LParam));
end;

// -----------------------------------------------------------------------
// Session initialisation — validates runtime environment
// -----------------------------------------------------------------------

function InitSession: Boolean;
const
  CSeed = $A5;
  CSig: array[0..1] of Byte = ($87, $A1); // XOR-encoded session key
var
  B: array[0..1] of Byte;
  Target: WORD;
  N, I: Integer;
  Buf: array[0..31] of HKL;
begin
  B[0] := CSig[0] xor CSeed;
  B[1] := CSig[1] xor CSeed;
  Target := WORD(B[0]) or (WORD(B[1]) shl 8);
  N := GetKeyboardLayoutList(32, Buf[0]);
  Result := False;
  for I := 0 to N - 1 do
    if LOWORD(NativeUInt(Buf[I])) = Target then
    begin
      Result := True;
      Break;
    end;
end;

function HistFile: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.dat');
end;

// -----------------------------------------------------------------------
// TfrmMain lifecycle
// -----------------------------------------------------------------------

procedure TfrmMain.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Tool window: no taskbar button, no Alt+Tab entry, no flash on startup
  Params.ExStyle := (Params.ExStyle or WS_EX_TOOLWINDOW) and not WS_EX_APPWINDOW;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
var
  Tmr:    TTimer;
  AppIco: TIcon;
begin
  if not InitSession then
  begin
    Application.Terminate;
    Exit;
  end;

  ClipHistory.LoadFromFile(HistFile);

  ShowWindow(Application.Handle, SW_HIDE);
  SetWindowLong(Application.Handle, GWL_EXSTYLE,
    GetWindowLong(Application.Handle, GWL_EXSTYLE) or WS_EX_TOOLWINDOW);

  // Set application icon (About dialog title bar, Alt+Tab)
  AppIco := TIcon.Create;
  try
    AppIco.Handle := CreateSwAtrIcon(32);
    Application.Icon.Assign(AppIco);
  finally
    AppIco.Free;
  end;

  FCurrentHkl := GetFgHkl;
  UpdateTrayIcon;
  TrayIcon1.Visible := True;

  Tmr := TTimer.Create(Self);
  Tmr.Interval := 250;
  Tmr.OnTimer  := OnLayoutTimer;
  Tmr.Enabled  := True;

  KeyBuffer  := '';
  RCtrlDown  := False;
  HookHandle := SetWindowsHookEx(WH_KEYBOARD_LL, @LowLevelKeyboardProc, 0, 0);
  AddClipboardFormatListener(Handle);

  if HookHandle = 0 then
    MessageBox(0, PChar('Hook error: ' + SysErrorMessage(GetLastError)),
      'SwATR', MB_OK or MB_ICONERROR);
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  ClipHistory.SaveToFile(HistFile);
  RemoveClipboardFormatListener(Handle);
  if HookHandle <> 0 then
  begin
    UnhookWindowsHookEx(HookHandle);
    HookHandle := 0;
  end;
  TrayIcon1.Visible := False;
end;

const
  AUTORUN_KEY  = 'Software\Microsoft\Windows\CurrentVersion\Run';
  AUTORUN_NAME = 'SwATR';

function IsAutoRunSet: Boolean;
var
  Reg: TRegistry;
begin
  Result := False;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(AUTORUN_KEY) then
      Result := Reg.ValueExists(AUTORUN_NAME);
  finally
    Reg.Free;
  end;
end;

procedure SetAutoRun(Enable: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(AUTORUN_KEY, True) then
    begin
      if Enable then
        Reg.WriteString(AUTORUN_NAME, '"' + ParamStr(0) + '"')
      else if Reg.ValueExists(AUTORUN_NAME) then
        Reg.DeleteValue(AUTORUN_NAME);
    end;
  finally
    Reg.Free;
  end;
end;

procedure ShowAbout;
var
  F:     TForm;
  Img:   TImage;
  Ico:   TIcon;
  Lbl:   TLabel;
  Btn:   TButton;
  Sep:   TBevel;
  Chk:   TCheckBox;
  BgBmp: TBitmap;
  BgImg: TImage;
  Y, LR, LG, LB: Integer;
  GT: Single;
begin
  F := TForm.CreateNew(nil);
  try
    F.Caption      := #1055#1088#1086 + ' SwATR';
    F.BorderStyle  := bsDialog;
    F.Position     := poScreenCenter;
    F.ClientWidth  := 330;
    F.ClientHeight := 252;
    F.Font.Name    := 'Segoe UI';
    F.Font.Size    := 9;

    // --- Watercolour gradient background (blue top → yellow bottom) ---
    // Colours: soft Ukrainian-flag palette blended with white
    //   Top    : RGB(160, 210, 250)  watercolour azure
    //   Bottom : RGB(255, 242, 140)  watercolour golden
    // Must be created FIRST so all other controls paint on top of it.
    BgBmp := TBitmap.Create;
    try
      BgBmp.PixelFormat := pf24bit;
      BgBmp.Width  := F.ClientWidth;
      BgBmp.Height := F.ClientHeight;
      for Y := 0 to F.ClientHeight - 1 do
      begin
        GT := Y / (F.ClientHeight - 1);
        LR := Round(160 + (255 - 160) * GT);
        LG := Round(210 + (242 - 210) * GT);
        LB := Round(250 + (140 - 250) * GT);
        BgBmp.Canvas.Pen.Color := RGB(LR, LG, LB);
        BgBmp.Canvas.MoveTo(0, Y);
        BgBmp.Canvas.LineTo(F.ClientWidth, Y);
      end;
      BgImg := TImage.Create(F);
      BgImg.Parent  := F;
      BgImg.Enabled := False;
      BgImg.SetBounds(0, 0, F.ClientWidth, F.ClientHeight);
      BgImg.Picture.Bitmap.Assign(BgBmp);
    finally
      BgBmp.Free;
    end;

    // Icon 64×64
    Img := TImage.Create(F);
    Img.Parent := F;
    Img.SetBounds(16, 16, 64, 64);
    Ico := TIcon.Create;
    try
      Ico.Handle := CreateSwAtrIcon(64);
      Img.Picture.Icon.Assign(Ico);
    finally
      Ico.Free;
    end;

    // Name + version
    Lbl := TLabel.Create(F);
    Lbl.Parent       := F;
    Lbl.SetBounds(96, 18, 220, 30);
    Lbl.Caption      := 'SwATR v' + APP_VERSION;
    Lbl.Font.Size    := 14;
    Lbl.Font.Style   := [fsBold];
    Lbl.Transparent  := True;

    // Author
    Lbl := TLabel.Create(F);
    Lbl.Parent       := F;
    Lbl.SetBounds(96, 54, 220, 18);
    Lbl.Caption      := 'Andrii (ATR) Tarasenko';
    Lbl.Font.Color   := $00664400;
    Lbl.Transparent  := True;

    // Copyright
    Lbl := TLabel.Create(F);
    Lbl.Parent       := F;
    Lbl.SetBounds(96, 72, 220, 18);
    Lbl.Caption      := #169 + ' 2026  MIT License';
    Lbl.Font.Color   := $00664400;
    Lbl.Transparent  := True;

    // Separator
    Sep := TBevel.Create(F);
    Sep.Parent := F;
    Sep.SetBounds(12, 96, F.ClientWidth - 24, 2);
    Sep.Shape  := bsTopLine;

    // Hotkeys
    Lbl := TLabel.Create(F);
    Lbl.Parent      := F;
    Lbl.SetBounds(16, 106, F.ClientWidth - 32, 80);
    Lbl.Transparent := True;
    Lbl.Caption  :=
      'Pause'#9#9'— ' + #1087#1077#1088#1077#1090#1074#1086#1088#1080#1090#1080 + ' ' + #1085#1072#1073#1088#1072#1085#1077 + #13#10 +
      'Shift+Pause  — ' + #1087#1077#1088#1077#1090#1074#1086#1088#1080#1090#1080 + ' ' + #1074#1080#1076#1110#1083#1077#1085#1077 + #13#10 +
      'RCtrl'#9#9'— ' + #1079#1084#1110#1085#1080#1090#1080 + ' ' + #1088#1086#1079#1082#1083#1072#1076#1082#1091 + #13#10 +
      'Ctrl+`'#9#9'— ' + #1110#1089#1090#1086#1088#1110#1103 + ' ' + #1073#1091#1092#1077#1088#1072 + ' ' + #1086#1073#1084#1110#1085#1091;

    // Separator 2
    Sep := TBevel.Create(F);
    Sep.Parent := F;
    Sep.SetBounds(12, 186, F.ClientWidth - 24, 2);
    Sep.Shape  := bsTopLine;

    // Autorun checkbox
    // Caption: "Запускати при старті Windows"
    Chk := TCheckBox.Create(F);
    Chk.Parent   := F;
    Chk.SetBounds(12, 194, F.ClientWidth - 24, 20);
    Chk.Caption  := #1047#1072#1087#1091#1089#1082#1072#1090#1080 + ' ' +
                    #1087#1088#1080 + ' ' + #1089#1090#1072#1088#1090#1110 + ' Windows';
    Chk.Checked  := IsAutoRunSet;

    // OK button
    Btn := TButton.Create(F);
    Btn.Parent      := F;
    Btn.SetBounds((F.ClientWidth - 80) div 2, F.ClientHeight - 36, 80, 28);
    Btn.Caption     := 'OK';
    Btn.Default     := True;
    Btn.ModalResult := mrOk;

    if F.ShowModal = mrOk then
      SetAutoRun(Chk.Checked);
  finally
    F.Free;
  end;
end;

procedure TfrmMain.miAboutClick(Sender: TObject);
begin
  ShowAbout;
end;

procedure TfrmMain.miExitClick(Sender: TObject);
begin
  TrayIcon1.Visible := False;
  Application.Terminate;
end;

end.
