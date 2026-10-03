// SwATR — layout-aware text conversion between a Latin and a Cyrillic layout
// Author : Andrii (ATR) Tarasenko
//
// No hard-coded character table: everything is derived from the installed
// layouts via ToUnicodeEx, so any variant (Ukrainian, Ukrainian Enhanced,
// Russian, ...) converts exactly as its keys are printed.
unit uConverter;

interface

uses
  Winapi.Windows;

type
  // One typed key, recorded by the keyboard hook. Converting = re-typing the
  // same physical keys in another layout.
  TKeyStroke = record
    Vk:    Word;
    Scan:  Word;
    Shift: Boolean;
    Caps:  Boolean;
    AltGr: Boolean;
    Hkl:   HKL;      // layout active when the key was typed
    Ch:    WideChar; // character the key produced in Hkl
  end;
  TKeyStrokes = array of TKeyStroke;

// Character the key produces in Layout (#0 if none / dead key / control char)
function KeyToChar(const K: TKeyStroke; Layout: HKL): WideChar;
// English layouts form the Latin side of the pair
function IsLatinLayout(Layout: HKL): Boolean;
// wFlags used for ToUnicodeEx on this OS (diagnostics)
function ToUnicodeFlags: UINT;
// Latin -> Cyrillic (CyrHint if it is one, else Ukrainian, else any
// non-English); Cyrillic -> first English. 0 if not installed.
function OtherLayout(Layout, CyrHint: HKL): HKL;
// Selected-text conversion: each whitespace-separated word is flipped to the
// other layout; its direction is voted by characters that exist in only one
// layout. Target = layout the last word ended up in (0 = nothing to do).
function ConvertSelection(const AText: string; CurLayout: HKL;
  out Target: HKL): string;

implementation

uses
  System.Generics.Collections;

const
  LANG_EN = $09;
  LANG_UK = $22;
  // ToUnicodeEx wFlags bit 2: do not touch the kernel keyboard state
  // (Windows 10 1607+). Without it, calling ToUnicodeEx from the hook can
  // swallow dead keys (accents) in the app the user is typing into.
  TU_NO_STATE_CHANGE = $4;

type
  TCharMap = TDictionary<WideChar, WideChar>;

var
  // wFlags for every ToUnicodeEx call: TU_NO_STATE_CHANGE where the OS
  // supports it, 0 on older systems (Win 7/8.1, Server 2008 R2–2012 R2 —
  // there the flag makes ToUnicodeEx return no character at all)
  TUFlags: UINT = 0;

// Windows 10 1607 / Server 2016 = build 14393. RtlGetVersion reports the
// real version; GetVersionEx/TOSVersion depend on the exe manifest.
function OsSupportsNoStateChange: Boolean;
type
  TRtlGetVersion = function(var Info: TOSVersionInfoW): Integer; stdcall;
var
  RtlGetVersion: TRtlGetVersion;
  Info: TOSVersionInfoW;
begin
  Result := False;
  @RtlGetVersion := GetProcAddress(GetModuleHandle('ntdll.dll'), 'RtlGetVersion');
  if not Assigned(RtlGetVersion) then Exit;
  FillChar(Info, SizeOf(Info), 0);
  Info.dwOSVersionInfoSize := SizeOf(Info);
  if RtlGetVersion(Info) <> 0 then Exit;
  Result := (Info.dwMajorVersion > 10) or
    ((Info.dwMajorVersion = 10) and (Info.dwBuildNumber >= 14393));
end;

function PrimaryLang(Layout: HKL): Word;
begin
  Result := Word(NativeUInt(Layout) and $3FF);
end;

function ToUnicodeFlags: UINT;
begin
  Result := TUFlags;
end;

function IsLatinLayout(Layout: HKL): Boolean;
begin
  Result := PrimaryLang(Layout) = LANG_EN;
end;

function FindLatin: HKL;
var
  Buf: array[0..31] of HKL;
  N, I: Integer;
begin
  Result := 0;
  N := GetKeyboardLayoutList(Length(Buf), Buf[0]);
  for I := 0 to N - 1 do
    if IsLatinLayout(Buf[I]) then
      Exit(Buf[I]);
end;

function FindCyr(Hint: HKL): HKL;
var
  Buf: array[0..31] of HKL;
  N, I: Integer;
begin
  if (Hint <> 0) and not IsLatinLayout(Hint) then
    Exit(Hint);
  Result := 0;
  N := GetKeyboardLayoutList(Length(Buf), Buf[0]);
  for I := 0 to N - 1 do
    if PrimaryLang(Buf[I]) = LANG_UK then
      Exit(Buf[I]);
  for I := 0 to N - 1 do
    if not IsLatinLayout(Buf[I]) then
      Exit(Buf[I]);
end;

function OtherLayout(Layout, CyrHint: HKL): HKL;
begin
  if IsLatinLayout(Layout) then
    Result := FindCyr(CyrHint)
  else
    Result := FindLatin;
end;

function KeyToChar(const K: TKeyStroke; Layout: HKL): WideChar;
var
  KS: TKeyboardState;
  Buf: array[0..7] of WideChar;
  Vk: UINT;
  N: Integer;
begin
  Result := #0;
  Vk := K.Vk;
  // Same physical key in another layout: re-derive the VK from the scan code.
  // Numpad keys keep their VK — their scan codes alias other keys.
  if (Layout <> K.Hkl) and (K.Scan <> 0) and
     ((Vk < VK_NUMPAD0) or (Vk > VK_DIVIDE)) then
  begin
    Vk := MapVirtualKeyEx(K.Scan, MAPVK_VSC_TO_VK, Layout);
    if Vk = 0 then
      Vk := K.Vk;
  end;

  ZeroMemory(@KS, SizeOf(KS));
  if K.Shift then KS[VK_SHIFT]   := $80;
  if K.Caps  then KS[VK_CAPITAL] := $01; // toggle bit
  if K.AltGr then
  begin
    KS[VK_CONTROL] := $80; KS[VK_LCONTROL] := $80;
    KS[VK_MENU]    := $80; KS[VK_RMENU]    := $80;
  end;
  N := ToUnicodeEx(Vk, K.Scan, KS, Buf, Length(Buf), TUFlags, Layout);
  if (N = 1) and (Buf[0] >= ' ') then
    Result := Buf[0];
end;

// Lat->Cyr and Cyr->Lat character maps from the real layouts: every key
// plain, then with Shift, then AltGr — the first key producing a char wins.
procedure BuildMaps(Lat, Cyr: HKL; LatMap, CyrMap: TCharMap);
var
  K: TKeyStroke;
  Pass, Vk: Integer;
  CL, CC: WideChar;
begin
  for Pass := 0 to 2 do
    for Vk := $30 to $E2 do  // digits, letters, OEM punctuation
    begin
      if (Vk >= VK_NUMPAD0) and (Vk <= VK_DIVIDE) then
        Continue;
      FillChar(K, SizeOf(K), 0);
      K.Vk    := Vk;
      K.Scan  := MapVirtualKeyEx(Vk, MAPVK_VK_TO_VSC, Lat);
      K.Hkl   := Lat;
      K.Shift := Pass = 1;
      K.AltGr := Pass = 2;
      if K.Scan = 0 then
        Continue;
      CL := KeyToChar(K, Lat);
      CC := KeyToChar(K, Cyr);
      if (CL = #0) or (CC = #0) then
        Continue;
      if not LatMap.ContainsKey(CL) then LatMap.Add(CL, CC);
      if not CyrMap.ContainsKey(CC) then CyrMap.Add(CC, CL);
    end;
end;

// +1 = only typeable in the Latin layout, -1 = only in the Cyrillic one,
// 0 = neutral (digits, . , ? ; : " exist in both)
function CharVote(C: WideChar; LatMap, CyrMap: TCharMap): Integer;
var
  InLat, InCyr: Boolean;
begin
  InLat := LatMap.ContainsKey(C);
  InCyr := CyrMap.ContainsKey(C);
  if InLat and not InCyr then Exit(1);
  if InCyr and not InLat then Exit(-1);
  // Not on any mapped key (e.g. AltGr-only letters): fall back on script
  case Ord(C) of
    Ord('A')..Ord('Z'), Ord('a')..Ord('z'): Result := 1;
    $0400..$04FF:                           Result := -1;
    else                                    Result := 0;
  end;
end;

function ConvertSelection(const AText: string; CurLayout: HKL;
  out Target: HKL): string;
var
  Lat, Cyr: HKL;
  LatMap, CyrMap: TCharMap;
  TokStart, TokEnd, TokDir: array of Integer;
  N, I, J, P, T, Votes, Fallback: Integer;
  C: WideChar;
begin
  Result := AText;
  Target := 0;
  Lat := FindLatin;
  Cyr := FindCyr(CurLayout);
  if (Lat = 0) or (Cyr = 0) then
    Exit;

  LatMap := TCharMap.Create;
  CyrMap := TCharMap.Create;
  try
    BuildMaps(Lat, Cyr, LatMap, CyrMap);

    // Split into words and vote each word's source layout
    N := 0;
    I := 1;
    while I <= Length(AText) do
    begin
      if AText[I] <= ' ' then
      begin
        Inc(I);
        Continue;
      end;
      J := I;
      Votes := 0;
      while (J <= Length(AText)) and (AText[J] > ' ') do
      begin
        Inc(Votes, CharVote(AText[J], LatMap, CyrMap));
        Inc(J);
      end;
      SetLength(TokStart, N + 1);
      SetLength(TokEnd,   N + 1);
      SetLength(TokDir,   N + 1);
      TokStart[N] := I;
      TokEnd[N]   := J - 1;
      if Votes > 0 then TokDir[N] := 1
      else if Votes < 0 then TokDir[N] := -1
      else TokDir[N] := 0;
      Inc(N);
      I := J;
    end;
    if N = 0 then
      Exit;

    // Neutral words ("?", "123") follow the previous word, leading ones the
    // next; if no word voted at all, the current layout is the source.
    for T := 1 to N - 1 do
      if TokDir[T] = 0 then TokDir[T] := TokDir[T - 1];
    for T := N - 2 downto 0 do
      if TokDir[T] = 0 then TokDir[T] := TokDir[T + 1];
    if TokDir[0] = 0 then
    begin
      if IsLatinLayout(CurLayout) then Fallback := 1 else Fallback := -1;
      for T := 0 to N - 1 do
        TokDir[T] := Fallback;
    end;

    // Flip each word; chars not typeable in its source layout (e.g. a
    // Cyrillic letter inside a Latin word) are already right — keep them
    for T := 0 to N - 1 do
      for P := TokStart[T] to TokEnd[T] do
        if TokDir[T] > 0 then
        begin
          if LatMap.TryGetValue(Result[P], C) then Result[P] := C;
        end
        else if CyrMap.TryGetValue(Result[P], C) then
          Result[P] := C;

    if TokDir[N - 1] > 0 then
      Target := Cyr
    else
      Target := Lat;
  finally
    LatMap.Free;
    CyrMap.Free;
  end;
end;

initialization
  if OsSupportsNoStateChange then
    TUFlags := TU_NO_STATE_CHANGE;

end.
