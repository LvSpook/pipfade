' Start pipfade.vbs -- launches pipfade with no console window at all.
' Double-click this instead of the .cmd if you don't want a flash of black.
Option Explicit
Dim sh, fso, here, script
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here   = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "pipfade.ps1")

If Not fso.FileExists(script) Then
    MsgBox "Could not find pipfade.ps1 next to this launcher.", 16, "pipfade"
    WScript.Quit 1
End If

sh.Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """", 0, False
