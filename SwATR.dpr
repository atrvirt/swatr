program SwATR;

uses
  Winapi.Windows,
  Vcl.Forms,
  uMain      in 'uMain.pas' {frmMain},
  uConverter in 'uConverter.pas',
  uClipHistory in 'uClipHistory.pas',
  uHistoryForm in 'uHistoryForm.pas',
  uToastForm in 'uToastForm.pas';

{$R *.res}

begin
  // Single instance per session: a second copy would install duplicate hooks
  // (double conversion) and race the first one for SwATR.dat.
  // The handle stays open for the process lifetime; Windows releases it.
  CreateMutex(nil, False, 'Local\SwATR_SingleInstance');
  if GetLastError = ERROR_ALREADY_EXISTS then
    Exit;

  Application.Initialize;
  Application.MainFormOnTaskbar := False;
  Application.ShowMainForm := False;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
