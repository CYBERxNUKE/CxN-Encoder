Option Explicit

Dim shell, fso, basePath, powershellPath, guiPath, codec, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

basePath = fso.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
guiPath = basePath & "\CxN-Encoder-GUI.ps1"
codec = "x265"
If WScript.Arguments.Count > 0 Then codec = WScript.Arguments(0)

command = Chr(34) & powershellPath & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & guiPath & Chr(34) & " -DefaultCodec " & codec & " -HideConsole"
shell.Run command, 1, False
