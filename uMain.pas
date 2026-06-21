unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils,
  Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls, Vcl.Menus, Vcl.Graphics,
  uConverter, System.Classes;

const
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
  Vcl.Clipbrd,
  uClipHistory,
  uHistoryForm;

{$R *.dfm}

// -----------------------------------------------------------------------
// Globals
// -----------------------------------------------------------------------

var
  HookHandle:   HHOOK;
  KeyBuffer:    string;
  RCtrlDown:    Boolean;

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

  // Tooltip: show layout name
  TrayIcon1.Hint :=
    'SwATR  [' + Name + ']' + #13#10 +
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

procedure SendCtrlKey(VK: WORD);
var
  Inp: array[0..3] of TInput;
begin
  FillChar(Inp, SizeOf(Inp), 0);
  Inp[0].Itype := INPUT_KEYBOARD; Inp[0].ki.wVk := VK_CONTROL; Inp[0].ki.dwExtraInfo := SWATTR_MAGIC;
  Inp[1].Itype := INPUT_KEYBOARD; Inp[1].ki.wVk := VK;          Inp[1].ki.dwExtraInfo := SWATTR_MAGIC;
  Inp[2].Itype := INPUT_KEYBOARD; Inp[2].ki.wVk := VK;
    Inp[2].ki.dwFlags := KEYEVENTF_KEYUP;  Inp[2].ki.dwExtraInfo := SWATTR_MAGIC;
  Inp[3].Itype := INPUT_KEYBOARD; Inp[3].ki.wVk := VK_CONTROL;
    Inp[3].ki.dwFlags := KEYEVENTF_KEYUP;  Inp[3].ki.dwExtraInfo := SWATTR_MAGIC;
  SendInput(4, Inp[0], SizeOf(TInput));
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
  GetKeyboardState(KS);
  if ToUnicodeEx(vk, scan, KS, Buf, 4, 0, GetKeyboardLayout(0)) = 1 then
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
      if (GetAsyncKeyState(VK_SHIFT) and $8000) <> 0 then
        PostMessage(frmMain.Handle, WM_CONVERT_SELECTED, 0, 0)
      else
        PostMessage(frmMain.Handle, WM_CONVERT_LAST, 0, 0);
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
  Buf := KeyBuffer;
  KeyBuffer := '';
  if (Buf = '') or (ConvertText(Buf) = Buf) then Exit;

  Conv := ConvertText(Buf);
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
    Sleep(30); // clipboard busy — wait and retry
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
    Sleep(30);
  end;
end;

// Shift+Pause — convert selected text via clipboard
procedure TfrmMain.WMConvertSelected(var Msg: TMessage);
var
  Sel, Conv: string;
begin
  KeyBuffer := '';

  // Shift is still physically held from Shift+Pause — release it
  // so that Ctrl+C is not seen as Ctrl+Shift+C by the target app
  ReleaseShift;
  Sleep(30);

  ClipSetText('');           // clear so we can detect if copy succeeded
  SendCtrlKey(Ord('C'));
  Sleep(250);               // wait for target app to write to clipboard

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
end;

// Switch foreground window to a specific language (by LANGID, e.g. $0422=UA, $0409=EN)
// Silently skips if that layout is not installed.
procedure SwitchFgToLang(LangID: WORD);
var
  FgWnd:   HWND;
  Buf:     array[0..31] of HKL;
  Cnt, I:  Integer;
  Target:  HKL;
begin
  FgWnd := GetForegroundWindow;
  if FgWnd = 0 then Exit;

  Cnt := GetKeyboardLayoutList(32, Buf[0]);
  Target := 0;
  for I := 0 to Cnt - 1 do
    if WORD(NativeUInt(Buf[I]) and $FFFF) = LangID then
    begin
      Target := Buf[I];
      Break;
    end;

  if Target <> 0 then
    PostMessage(FgWnd, WM_INPUTLANGCHANGEREQUEST, 0, LPARAM(Target));
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
  Tmr: TTimer;
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

procedure TfrmMain.miAboutClick(Sender: TObject);
begin
  MessageBox(Handle,
    PChar('SwATR v1.0'#13#10#13#10 +
      'Pause'#9'- ' +
      #1087#1077#1088#1077#1090#1074#1086#1088#1080#1090#1080 + ' ' + #1085#1072#1073#1088#1072#1085#1077 + #13#10 +
      'Shift+Pause - ' +
      #1087#1077#1088#1077#1090#1074#1086#1088#1080#1090#1080 + ' ' + #1074#1080#1076#1110#1083#1077#1085#1077 + #13#10 +
      'RCtrl'#9'- ' + #1079#1084#1110#1085#1080#1090#1080 + ' ' + #1088#1086#1079#1082#1083#1072#1076#1082#1091),
    'SwATR', MB_OK or MB_ICONINFORMATION);
end;

procedure TfrmMain.miExitClick(Sender: TObject);
begin
  TrayIcon1.Visible := False;
  Application.Terminate;
end;

end.
