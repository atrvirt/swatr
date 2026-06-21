// SwATR — UA<->EN keyboard layout character mapping
// Author : Andrii (ATR) Tarasenko
unit uConverter;

interface

function ConvertText(const AText: string): string;
function IsUkrText(const AText: string): Boolean;

implementation

type
  TCharPair = record
    U: WideChar;
    E: WideChar;
  end;

const
  CMAP: array[0..65] of TCharPair = (
    // lowercase Ukrainian -> English (same physical key)
    (U: #$0439; E: 'q'), (U: #$0446; E: 'w'), (U: #$0443; E: 'e'),
    (U: #$043A; E: 'r'), (U: #$0435; E: 't'), (U: #$043D; E: 'y'),
    (U: #$0433; E: 'u'), (U: #$0448; E: 'i'), (U: #$0449; E: 'o'),
    (U: #$0437; E: 'p'), (U: #$0445; E: '['), (U: #$0457; E: ']'),
    (U: #$0444; E: 'a'), (U: #$0456; E: 's'), (U: #$0432; E: 'd'),
    (U: #$0430; E: 'f'), (U: #$043F; E: 'g'), (U: #$0440; E: 'h'),
    (U: #$043E; E: 'j'), (U: #$043B; E: 'k'), (U: #$0434; E: 'l'),
    (U: #$0436; E: ';'), (U: #$0454; E: #39), (U: #$044F; E: 'z'),
    (U: #$0447; E: 'x'), (U: #$0441; E: 'c'), (U: #$043C; E: 'v'),
    (U: #$0438; E: 'b'), (U: #$0442; E: 'n'), (U: #$044C; E: 'm'),
    (U: #$0431; E: ','), (U: #$044E; E: '.'), (U: #$0491; E: '`'),
    // uppercase Ukrainian -> English (same physical key + Shift)
    (U: #$0419; E: 'Q'), (U: #$0426; E: 'W'), (U: #$0423; E: 'E'),
    (U: #$041A; E: 'R'), (U: #$0415; E: 'T'), (U: #$041D; E: 'Y'),
    (U: #$0413; E: 'U'), (U: #$0428; E: 'I'), (U: #$0429; E: 'O'),
    (U: #$0417; E: 'P'), (U: #$0425; E: '{'), (U: #$0407; E: '}'),
    (U: #$0424; E: 'A'), (U: #$0406; E: 'S'), (U: #$0412; E: 'D'),
    (U: #$0410; E: 'F'), (U: #$041F; E: 'G'), (U: #$0420; E: 'H'),
    (U: #$041E; E: 'J'), (U: #$041B; E: 'K'), (U: #$0414; E: 'L'),
    (U: #$0416; E: ':'), (U: #$0404; E: '"'), (U: #$042F; E: 'Z'),
    (U: #$0427; E: 'X'), (U: #$0421; E: 'C'), (U: #$041C; E: 'V'),
    (U: #$0418; E: 'B'), (U: #$0422; E: 'N'), (U: #$042C; E: 'M'),
    (U: #$0411; E: '<'), (U: #$042E; E: '>'), (U: #$0490; E: '~')
  );

function HasUkrChars(const AText: string): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  for I := 1 to Length(AText) do
    for J := Low(CMAP) to High(CMAP) do
      if AText[I] = CMAP[J].U then
      begin
        Result := True;
        Exit;
      end;
end;

function ConvertText(const AText: string): string;
var
  I, J: Integer;
  Ch: Char;
  Found: Boolean;
  IsUkr: Boolean;
begin
  IsUkr := HasUkrChars(AText);
  Result := '';
  for I := 1 to Length(AText) do
  begin
    Ch := AText[I];
    Found := False;
    for J := Low(CMAP) to High(CMAP) do
    begin
      if IsUkr then
      begin
        if CMAP[J].U = Ch then
        begin
          Result := Result + CMAP[J].E;
          Found := True;
          Break;
        end;
      end
      else
      begin
        if CMAP[J].E = Ch then
        begin
          Result := Result + CMAP[J].U;
          Found := True;
          Break;
        end;
      end;
    end;
    if not Found then
      Result := Result + Ch;
  end;
end;

// Returns True if text contains Ukrainian (Cyrillic) characters
function IsUkrText(const AText: string): Boolean;
begin
  Result := HasUkrChars(AText);
end;

end.
