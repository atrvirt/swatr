unit uClipHistory;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, Vcl.Graphics;

const
  MAX_CLIP_ITEMS = 64;
  MAX_SAVE_ITEMS = 64;

type
  TClipKind = (ckText, ckBitmap);

  TClipItem = class
  public
    Kind:    TClipKind;
    Text:    string;
    Bmp:     TBitmap;
    AddedAt: TDateTime;
    constructor CreateText(const AText: string);
    constructor CreateBitmap(ABmp: TBitmap);
    destructor Destroy; override;
    function Preview: string;
  end;

  TClipHistory = class
  private
    FList: TList;
    function GetCount: Integer;
    function GetItem(Idx: Integer): TClipItem;
  public
    constructor Create;
    destructor Destroy; override;
    procedure PushText(const S: string);
    procedure PushBitmap(Bmp: TBitmap);
    procedure Delete(Idx: Integer);
    procedure Clear;
    procedure SaveToFile(const FileName: string);
    procedure LoadFromFile(const FileName: string);
    property Count: Integer read GetCount;
    property Items[Idx: Integer]: TClipItem read GetItem; default;
  end;

var
  ClipHistory: TClipHistory;

implementation

{ TClipItem }

constructor TClipItem.CreateText(const AText: string);
begin
  inherited Create;
  Kind    := ckText;
  Text    := AText;
  AddedAt := Now;
end;

constructor TClipItem.CreateBitmap(ABmp: TBitmap);
begin
  inherited Create;
  Kind    := ckBitmap;
  Bmp     := TBitmap.Create;
  Bmp.Assign(ABmp);
  AddedAt := Now;
end;

destructor TClipItem.Destroy;
begin
  FreeAndNil(Bmp);
  inherited;
end;

function TClipItem.Preview: string;
var
  S: string;
begin
  if Kind = ckBitmap then
    Result := Format('[%dx%d px]', [Bmp.Width, Bmp.Height])
  else
  begin
    S := StringReplace(Text, #13#10, ' ', [rfReplaceAll]);
    S := StringReplace(S,   #10,    ' ', [rfReplaceAll]);
    S := StringReplace(S,   #9,     ' ', [rfReplaceAll]);
    S := Trim(S);
    if Length(S) > 100 then
      Result := Copy(S, 1, 100) + '...'
    else
      Result := S;
  end;
end;

{ TClipHistory }

constructor TClipHistory.Create;
begin
  FList := TList.Create;
end;

destructor TClipHistory.Destroy;
begin
  Clear;
  FreeAndNil(FList);
  inherited;
end;

function TClipHistory.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TClipHistory.GetItem(Idx: Integer): TClipItem;
begin
  Result := TClipItem(FList[FList.Count - 1 - Idx]); // 0 = newest
end;

procedure TClipHistory.PushText(const S: string);
var
  I: Integer;
  Old: TClipItem;
begin
  if Trim(S) = '' then Exit;
  for I := FList.Count - 1 downto 0 do
  begin
    Old := TClipItem(FList[I]);
    if (Old.Kind = ckText) and (Old.Text = S) then
    begin
      Old.Free;
      FList.Delete(I);
    end;
  end;
  while FList.Count >= MAX_CLIP_ITEMS do
  begin
    TClipItem(FList[0]).Free;
    FList.Delete(0);
  end;
  FList.Add(TClipItem.CreateText(S));
end;

procedure TClipHistory.PushBitmap(Bmp: TBitmap);
var
  I: Integer;
  Old: TClipItem;
begin
  // Dedup by dimensions — move existing match to top instead of adding duplicate
  for I := FList.Count - 1 downto 0 do
  begin
    Old := TClipItem(FList[I]);
    if (Old.Kind = ckBitmap) and
       (Old.Bmp.Width = Bmp.Width) and (Old.Bmp.Height = Bmp.Height) then
    begin
      Old.Free;
      FList.Delete(I);
      Break;
    end;
  end;
  while FList.Count >= MAX_CLIP_ITEMS do
  begin
    TClipItem(FList[0]).Free;
    FList.Delete(0);
  end;
  FList.Add(TClipItem.CreateBitmap(Bmp));
end;

procedure TClipHistory.Delete(Idx: Integer);
var
  RealIdx: Integer;
begin
  RealIdx := FList.Count - 1 - Idx;
  if (RealIdx >= 0) and (RealIdx < FList.Count) then
  begin
    TClipItem(FList[RealIdx]).Free;
    FList.Delete(RealIdx);
  end;
end;

procedure TClipHistory.Clear;
var
  I: Integer;
begin
  for I := 0 to FList.Count - 1 do
    TClipItem(FList[I]).Free;
  FList.Clear;
end;

const
  HIST_MAGIC   : Cardinal = $54415753; // 'SWAT'
  HIST_VERSION : Cardinal = 1;
  HKIND_TEXT   : Byte = 0;
  HKIND_BITMAP : Byte = 1;

procedure TClipHistory.SaveToFile(const FileName: string);
var
  FS: TFileStream;
  MS: TMemoryStream;
  I, SaveCount: Integer;
  Item: TClipItem;
  Kind: Byte;
  Cnt, Len: Cardinal;
  UTF8: TBytes;
begin
  try
    FS := TFileStream.Create(FileName, fmCreate);
    try
      FS.WriteBuffer(HIST_MAGIC,   SizeOf(Cardinal));
      FS.WriteBuffer(HIST_VERSION, SizeOf(Cardinal));
      SaveCount := Min(Count, MAX_SAVE_ITEMS);
      Cnt := SaveCount;
      FS.WriteBuffer(Cnt, SizeOf(Cardinal));
      // Oldest first so Load rebuilds history in correct order
      for I := SaveCount - 1 downto 0 do
      begin
        Item := GetItem(I);
        if Item.Kind = ckText then
        begin
          Kind := HKIND_TEXT;
          FS.WriteBuffer(Kind, 1);
          UTF8 := TEncoding.UTF8.GetBytes(Item.Text);
          Len := Length(UTF8);
          FS.WriteBuffer(Len, SizeOf(Cardinal));
          if Len > 0 then
            FS.WriteBuffer(UTF8[0], Len);
        end
        else
        begin
          Kind := HKIND_BITMAP;
          FS.WriteBuffer(Kind, 1);
          MS := TMemoryStream.Create;
          try
            Item.Bmp.SaveToStream(MS);
            Len := MS.Size;
            FS.WriteBuffer(Len, SizeOf(Cardinal));
            MS.Position := 0;
            FS.CopyFrom(MS, Len);
          finally
            MS.Free;
          end;
        end;
      end;
    finally
      FS.Free;
    end;
  except
    // Silently ignore write errors (read-only folder, disk full, etc.)
  end;
end;

procedure TClipHistory.LoadFromFile(const FileName: string);
var
  FS: TFileStream;
  MS: TMemoryStream;
  I, ItemCount: Integer;
  Magic, Ver, Cnt, Len: Cardinal;
  Kind: Byte;
  UTF8: TBytes;
  Bmp: TBitmap;
begin
  if not FileExists(FileName) then Exit;
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      FS.ReadBuffer(Magic, SizeOf(Cardinal));
      if Magic <> HIST_MAGIC then Exit;
      FS.ReadBuffer(Ver, SizeOf(Cardinal));
      if Ver <> HIST_VERSION then Exit;
      FS.ReadBuffer(Cnt, SizeOf(Cardinal));
      ItemCount := Cnt;
      for I := 0 to ItemCount - 1 do
      begin
        FS.ReadBuffer(Kind, 1);
        FS.ReadBuffer(Len, SizeOf(Cardinal));
        if Kind = HKIND_TEXT then
        begin
          SetLength(UTF8, Len);
          if Len > 0 then
            FS.ReadBuffer(UTF8[0], Len);
          PushText(TEncoding.UTF8.GetString(UTF8));
        end
        else if Kind = HKIND_BITMAP then
        begin
          MS := TMemoryStream.Create;
          try
            MS.CopyFrom(FS, Len);
            MS.Position := 0;
            Bmp := TBitmap.Create;
            try
              Bmp.LoadFromStream(MS);
              PushBitmap(Bmp);
            finally
              Bmp.Free;
            end;
          finally
            MS.Free;
          end;
        end
        else
          FS.Seek(Len, soCurrent); // skip unknown record types
      end;
    finally
      FS.Free;
    end;
  except
    // Silently ignore corrupted or incompatible file
  end;
end;

initialization
  ClipHistory := TClipHistory.Create;

finalization
  FreeAndNil(ClipHistory);

end.
