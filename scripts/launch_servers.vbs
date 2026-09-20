' launch_servers.vbs — Lanceur sécurisé sans doublon pour Memory Server et SD Server
' Conforme CORR-LOT-002 (Ownership strict, aucun kill aveugle, détection HTTP + port)
Option Explicit

Dim oShell, oFSO, sDir
Set oShell = CreateObject("WScript.Shell")
Set oFSO   = CreateObject("Scripting.FileSystemObject")
sDir       = oFSO.GetParentFolderName(WScript.ScriptFullName)

Function IsHttpHealthy(url)
    On Error Resume Next
    Dim http
    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.setTimeouts 500, 500, 500, 500
    http.Open "GET", url, False
    http.Send
    If Err.Number = 0 Then
        If http.Status = 200 Then
            IsHttpHealthy = True
            Exit Function
        End If
    End If
    IsHttpHealthy = False
    Err.Clear
End Function

Function IsPortListening(port)
    On Error Resume Next
    Dim oExec, sLine, bFound, regEx
    bFound = False

    Set regEx = CreateObject("VBScript.RegExp")
    regEx.Pattern = "^\s*TCP\s+\S+:" & CStr(port) & "\s+\S+\s+LISTENING\b"
    regEx.IgnoreCase = True

    Set oExec = oShell.Exec("netstat -ano")
    Do While Not oExec.StdOut.AtEndOfStream
        sLine = oExec.StdOut.ReadLine()
        If regEx.Test(sLine) Then
            bFound = True
            Exit Do
        End If
    Loop
    IsPortListening = bFound
    Err.Clear
End Function

Sub SafeLaunch(sExeName, iPort, sHealthUrl)
    Dim sExePath
    sExePath = sDir & "\" & sExeName

    ' 1. Si le serveur tourne déjà sainement, ne rien relancer
    If IsHttpHealthy(sHealthUrl) Then
        Exit Sub
    End If

    ' 2. Si le port est occupé par un service non sain ou étranger, interdiction de lancer un doublon et interdiction de tuer
    If IsPortListening(iPort) Then
        Exit Sub
    End If

    ' 3. Port libre : lancer le serveur en arrière-plan sans console parasite
    If oFSO.FileExists(sExePath) Then
        oShell.Run Chr(34) & sExePath & Chr(34), 0, False
    End If
End Sub

' Lancement ordonné et sécurisé
SafeLaunch "memory_server.exe", 7862, "http://127.0.0.1:7862/health"
SafeLaunch "sd_server.exe",     7860, "http://127.0.0.1:7860/"
