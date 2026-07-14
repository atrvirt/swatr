program SwATR;

uses
  Vcl.Forms,
  uMain      in 'uMain.pas' {frmMain},
  uConverter in 'uConverter.pas',
  uClipHistory in 'uClipHistory.pas',
  uHistoryForm in 'uHistoryForm.pas',
  uToastForm in 'uToastForm.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := False;
  Application.ShowMainForm := False;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
