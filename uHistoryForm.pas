unit uHistoryForm;

// Clipboard history popup — created entirely in code (no DFM)

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.Clipbrd,
  uClipHistory;

type
  TfrmClipHistory = class(TForm)
  private
    edSearch:  TEdit;
    lstItems:  TListBox;
    pnlRight:  TPanel;
    memoText:  TMemo;
    imgBmp:    TImage;
    pnlBottom: TPanel;
    lblInfo:   TLabel;
    btnPaste:  TButton;
    btnDel:    TButton;
    btnClear:  TButton;
    FPrevFgWnd:       HWND;
    FIgnoreDeactivate: Boolean;
    procedure BuildUI;
    procedure Reload(const Filter: string = '');
    procedure ShowPreview;
    procedure DoPaste;
    procedure DoDelete;
    procedure OnSearch(Sender: TObject);
    procedure OnListClick(Sender: TObject);
    procedure OnListDblClick(Sender: TObject);
    procedure OnListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OnListDrawItem(Ctrl: TWinControl; Idx: Integer;
      R: TRect; St: TOwnerDrawState);
    procedure OnBtnPaste(Sender: TObject);
    procedure OnBtnDel(Sender: TObject);
    procedure OnBtnClear(Sender: TObject);
    procedure OnFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OnFormActivate(Sender: TObject);
    procedure OnFormDeactivate(Sender: TObject);
  public
    constructor Create(APrevFgWnd: HWND); reintroduce;
  end;

var
  GHistoryOpen: Boolean = False;

procedure ShowClipHistory(PrevFgWnd: HWND);

implementation

// Paste into previous window via SendInput (no dependency on uMain)
procedure DoCtrlV;
var
  Inp: array[0..3] of TInput;
begin
  FillChar(Inp, SizeOf(Inp), 0);
  Inp[0].Itype := INPUT_KEYBOARD; Inp[0].ki.wVk := VK_CONTROL;
  Inp[1].Itype := INPUT_KEYBOARD; Inp[1].ki.wVk := Ord('V');
  Inp[2].Itype := INPUT_KEYBOARD; Inp[2].ki.wVk := Ord('V');
    Inp[2].ki.dwFlags := KEYEVENTF_KEYUP;
  Inp[3].Itype := INPUT_KEYBOARD; Inp[3].ki.wVk := VK_CONTROL;
    Inp[3].ki.dwFlags := KEYEVENTF_KEYUP;
  SendInput(4, Inp[0], SizeOf(TInput));
end;

{ TfrmClipHistory }

constructor TfrmClipHistory.Create(APrevFgWnd: HWND);
var
  MP: TPoint;
begin
  inherited CreateNew(nil);
  FPrevFgWnd := APrevFgWnd;
  FIgnoreDeactivate := True; // stays True until first OnActivate
  BuildUI;
  Reload;
  if lstItems.Count > 0 then
    lstItems.ItemIndex := 0;
  ShowPreview;
  ActiveControl := lstItems;
  // Appear near mouse cursor, adjusted to stay on screen
  GetCursorPos(MP);
  Left := MP.X - 20;
  Top  := MP.Y - 20;
  if Left + Width  > Screen.Width  then Left := Screen.Width  - Width  - 8;
  if Top  + Height > Screen.Height then Top  := Screen.Height - Height - 48;
  if Left < 0 then Left := 0;
  if Top  < 0 then Top  := 0;
end;

procedure TfrmClipHistory.BuildUI;
var
  pnlLeft, pnlSearch: TPanel;
  VSplit: TSplitter;
begin
  // Form
  Caption      := 'SwATR — ' + #1073#1091#1092#1077#1088 + ' ' + #1086#1073#1084#1110#1085#1091;
  Width        := 700;
  Height       := 400;
  BorderStyle  := bsSizeable;
  FormStyle    := fsStayOnTop;
  KeyPreview   := True;
  Font.Name    := 'Segoe UI';
  Font.Size    := 8;
  OnKeyDown    := OnFormKeyDown;
  OnActivate   := OnFormActivate;
  OnDeactivate := OnFormDeactivate;

  // ---- Bottom panel ----
  pnlBottom := TPanel.Create(Self);
  pnlBottom.Parent     := Self;
  pnlBottom.Align      := alBottom;
  pnlBottom.Height     := 36;
  pnlBottom.BevelOuter := bvNone;
  pnlBottom.Padding.SetBounds(4, 3, 4, 3);

  lblInfo := TLabel.Create(Self);
  lblInfo.Parent  := pnlBottom;
  lblInfo.Align   := alRight;
  lblInfo.Layout  := tlCenter;
  lblInfo.Width   := 100;
  lblInfo.Caption := '';

  btnClear := TButton.Create(Self);
  btnClear.Parent   := pnlBottom;
  btnClear.Align    := alLeft;
  btnClear.Width    := 120;
  btnClear.Caption  := #1054#1095#1080#1089#1090#1080#1090#1080 + ' ' + #1074#1089#1077;
  btnClear.OnClick  := OnBtnClear;

  btnDel := TButton.Create(Self);
  btnDel.Parent   := pnlBottom;
  btnDel.Align    := alLeft;
  btnDel.Width    := 100;
  btnDel.Caption  := #1042#1080#1076#1072#1083#1080#1090#1080 + ' Del';
  btnDel.OnClick  := OnBtnDel;

  btnPaste := TButton.Create(Self);
  btnPaste.Parent   := pnlBottom;
  btnPaste.Align    := alLeft;
  btnPaste.Width    := 100;
  btnPaste.Caption  := #1042#1089#1090#1072#1074#1080#1090#1080 + ' Enter';
  btnPaste.Default  := True;
  btnPaste.OnClick  := OnBtnPaste;

  // ---- Left panel (list + search) ----
  pnlLeft := TPanel.Create(Self);
  pnlLeft.Parent     := Self;
  pnlLeft.Align      := alLeft;
  pnlLeft.Width      := 300;
  pnlLeft.BevelOuter := bvNone;

  pnlSearch := TPanel.Create(Self);
  pnlSearch.Parent     := pnlLeft;
  pnlSearch.Align      := alTop;
  pnlSearch.Height     := 28;
  pnlSearch.BevelOuter := bvNone;
  pnlSearch.Padding.SetBounds(2, 2, 2, 2);

  edSearch := TEdit.Create(Self);
  edSearch.Parent   := pnlSearch;
  edSearch.Align    := alClient;
  edSearch.TextHint := #1055#1086#1096#1091#1082'...';
  edSearch.OnChange := OnSearch;

  lstItems := TListBox.Create(Self);
  lstItems.Parent      := pnlLeft;
  lstItems.Align       := alClient;
  lstItems.Style       := lbOwnerDrawFixed;
  lstItems.ItemHeight  := 17;
  lstItems.OnClick     := OnListClick;
  lstItems.OnDblClick  := OnListDblClick;
  lstItems.OnKeyDown   := OnListKeyDown;
  lstItems.OnDrawItem  := OnListDrawItem;

  // ---- Splitter ----
  VSplit := TSplitter.Create(Self);
  VSplit.Parent := Self;
  VSplit.Align  := alLeft;
  VSplit.Width  := 4;

  // ---- Right panel (preview) ----
  pnlRight := TPanel.Create(Self);
  pnlRight.Parent     := Self;
  pnlRight.Align      := alClient;
  pnlRight.BevelOuter := bvNone;
  pnlRight.Caption    := '';

  imgBmp := TImage.Create(Self);
  imgBmp.Parent      := pnlRight;
  imgBmp.Align       := alClient;
  imgBmp.Stretch     := True;
  imgBmp.Proportional := True;
  imgBmp.Visible     := False;

  memoText := TMemo.Create(Self);
  memoText.Parent     := pnlRight;
  memoText.Align      := alClient;
  memoText.ReadOnly   := True;
  memoText.ScrollBars := ssBoth;
  memoText.WordWrap   := False;
  memoText.Font.Name  := 'Consolas';
  memoText.Font.Size  := 8;
end;

procedure TfrmClipHistory.Reload(const Filter: string);
var
  I:    Integer;
  Item: TClipItem;
  F:    string;
begin
  F := AnsiLowerCase(Filter);
  lstItems.Items.BeginUpdate;
  try
    lstItems.Items.Clear;
    for I := 0 to ClipHistory.Count - 1 do
    begin
      Item := ClipHistory[I];
      if (F = '') or (Pos(F, AnsiLowerCase(Item.Preview)) > 0) then
        lstItems.Items.AddObject(Item.Preview, Item);
    end;
  finally
    lstItems.Items.EndUpdate;
  end;
  lblInfo.Caption := IntToStr(ClipHistory.Count) + ' / ' +
    IntToStr(MAX_CLIP_ITEMS);
end;

procedure TfrmClipHistory.ShowPreview;
var
  Item: TClipItem;
begin
  if lstItems.ItemIndex < 0 then
  begin
    memoText.Text  := '';
    memoText.Visible := True;
    imgBmp.Visible := False;
    Exit;
  end;
  Item := TClipItem(lstItems.Items.Objects[lstItems.ItemIndex]);
  if Item = nil then Exit;
  if Item.Kind = ckText then
  begin
    memoText.Text    := Item.Text;
    memoText.Visible := True;
    imgBmp.Visible   := False;
  end
  else
  begin
    imgBmp.Picture.Assign(Item.Bmp);
    memoText.Visible := False;
    imgBmp.Visible   := True;
  end;
end;

procedure TfrmClipHistory.DoPaste;
var
  Item: TClipItem;
begin
  if lstItems.ItemIndex < 0 then Exit;
  Item := TClipItem(lstItems.Items.Objects[lstItems.ItemIndex]);
  if Item = nil then Exit;

  // Put into clipboard
  if Item.Kind = ckText then
    Clipboard.AsText := Item.Text
  else
    Clipboard.Assign(Item.Bmp);

  // Restore previous window and paste
  FIgnoreDeactivate := True;
  Hide;
  if IsWindow(FPrevFgWnd) then
  begin
    SetForegroundWindow(FPrevFgWnd);
    Sleep(80);
    DoCtrlV;
  end;
  ModalResult := mrOk;
end;

procedure TfrmClipHistory.DoDelete;
var
  DispIdx, HIdx: Integer;
  Item: TClipItem;
begin
  DispIdx := lstItems.ItemIndex;
  if DispIdx < 0 then Exit;
  Item := TClipItem(lstItems.Items.Objects[DispIdx]);
  // Find in ClipHistory by reference
  for HIdx := 0 to ClipHistory.Count - 1 do
    if ClipHistory[HIdx] = Item then
    begin
      ClipHistory.Delete(HIdx);
      Break;
    end;
  Reload(edSearch.Text);
  if DispIdx < lstItems.Count then
    lstItems.ItemIndex := DispIdx
  else if lstItems.Count > 0 then
    lstItems.ItemIndex := lstItems.Count - 1;
  ShowPreview;
end;

procedure TfrmClipHistory.OnSearch(Sender: TObject);
begin
  Reload(edSearch.Text);
  if lstItems.Count > 0 then
    lstItems.ItemIndex := 0;
  ShowPreview;
end;

procedure TfrmClipHistory.OnListClick(Sender: TObject);
begin
  ShowPreview;
end;

procedure TfrmClipHistory.OnListDblClick(Sender: TObject);
begin
  DoPaste;
end;

procedure TfrmClipHistory.OnListKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  case Key of
    VK_RETURN: begin Key := 0; DoPaste; end;
    VK_DELETE: begin Key := 0; DoDelete; end;
    else ShowPreview;
  end;
end;

procedure TfrmClipHistory.OnListDrawItem(Ctrl: TWinControl; Idx: Integer;
  R: TRect; St: TOwnerDrawState);
var
  Item:  TClipItem;
  Canv:  TCanvas;
  Thumb: TRect;
begin
  Canv := (Ctrl as TListBox).Canvas;
  if odSelected in St then
  begin
    Canv.Brush.Color := clHighlight;
    Canv.Font.Color  := clHighlightText;
  end
  else
  begin
    Canv.Brush.Color := clWindow;
    Canv.Font.Color  := clWindowText;
  end;
  Canv.FillRect(R);

  Item := TClipItem(lstItems.Items.Objects[Idx]);
  if Item = nil then Exit;

  if Item.Kind = ckBitmap then
  begin
    Thumb := Rect(R.Left + 4, R.Top + 1, R.Left + 16, R.Top + 15);
    Canv.StretchDraw(Thumb, Item.Bmp);
    Canv.TextOut(R.Left + 20, R.Top + 2, Item.Preview);
  end
  else
    Canv.TextOut(R.Left + 4, R.Top + 2, lstItems.Items[Idx]);
end;

procedure TfrmClipHistory.OnBtnPaste(Sender: TObject); begin DoPaste;  end;
procedure TfrmClipHistory.OnBtnDel(Sender: TObject);   begin DoDelete; end;

procedure TfrmClipHistory.OnBtnClear(Sender: TObject);
begin
  ClipHistory.Clear;
  Reload;
  ShowPreview;
end;

procedure TfrmClipHistory.OnFormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    ModalResult := mrCancel;
  end;
  // Arrow keys navigate list even when focus is on other controls
  if (Key in [VK_UP, VK_DOWN]) and (lstItems.Count > 0) then
  begin
    lstItems.SetFocus;
    // Let the list handle the key
  end;
end;

procedure TfrmClipHistory.OnFormActivate(Sender: TObject);
begin
  FIgnoreDeactivate := False;
end;

procedure TfrmClipHistory.OnFormDeactivate(Sender: TObject);
begin
  if not FIgnoreDeactivate then
    ModalResult := mrCancel;
end;

{ public }

procedure ShowClipHistory(PrevFgWnd: HWND);
var
  F: TfrmClipHistory;
begin
  if GHistoryOpen or (ClipHistory.Count = 0) then Exit;
  GHistoryOpen := True;
  try
    F := TfrmClipHistory.Create(PrevFgWnd);
    try
      F.ShowModal;
    finally
      F.Free;
    end;
  finally
    GHistoryOpen := False;
  end;
end;

end.
