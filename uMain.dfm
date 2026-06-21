object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'SwATR'
  ClientHeight = 1
  ClientWidth = 1
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object TrayIcon1: TTrayIcon
    Hint = 'SwATR v1.3.0'
    PopupMenu = PopupMenu1
    Left = 16
    Top = 8
  end
  object PopupMenu1: TPopupMenu
    Left = 16
    Top = 56
    object miAbout: TMenuItem
      Caption = #1055#1088#1086' SwATR'
      OnClick = miAboutClick
    end
    object N1: TMenuItem
      Caption = '-'
    end
    object miExit: TMenuItem
      Caption = #1042#1080#1093#1110#1076
      OnClick = miExitClick
    end
  end
end
