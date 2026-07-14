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
