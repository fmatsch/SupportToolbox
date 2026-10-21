<#
.SYNOPSIS
    SupportToolbox - kleines Support-Tool für Windows-Anwender.
.DESCRIPTION
    Grafische Oberfläche (WinForms) für typische Support-Aufgaben:
    Systemdaten, Fehlerprotokoll, Netzwerk-Reparatur, Verbindungstest,
    Netzlaufwerke, Screenshots usw. Läuft ohne Installation mit Windows PowerShell 5.1.
.PARAMETER NoGui
    Nur Funktionen laden (für Tests), keine Oberfläche anzeigen.
.PARAMETER PreviewPath
    Rendert die Oberfläche in eine PNG-Datei und beendet sich (für die Doku).
#>
param(
    [switch]$NoGui,
    [string]$PreviewPath
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Version = '1.0.0'
$script:SelfPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:IsExe = $script:SelfPath -notmatch '(?i)\\(powershell|pwsh)\.exe$'
$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $script:SelfPath }
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------- Konfiguration
$script:Config = @{
    CompanyName  = 'IT-Support'
    SupportMail  = 'support@example.com'
    TestHost     = 'www.microsoft.com'
    TestPort     = 443
    NetworkDrives = @()   # optional: @{ Letter = 'Z'; Path = '\\server\share' }
}
$cfgFile = Join-Path $script:Root 'config.json'
if (Test-Path $cfgFile) {
    try {
        $user = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $user.PSObject.Properties) { $script:Config[$p.Name] = $p.Value }
    } catch { }
}

# ---------------------------------------------------------------- Hilfsfunktionen
function Format-Row([string]$Key, $Value) {
    $k = $Key + ':'
    if ($k.Length -ge 24) { $k += ' ' } else { $k = $k.PadRight(24) }
    $k + $Value
}

function Test-Admin([string]$Was) {
    if ($script:IsAdmin) { return $true }
    "Für diese Aktion werden Administratorrechte benötigt ($Was).`r`n`r`nBitte unten links auf 'Als Administrator neu starten' klicken."
}

function Test-TcpPort([string]$Target, [int]$Port, [int]$TimeoutMs = 3000) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($Target, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $c.Connected) { $c.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

function Test-PingHost([string]$Target, [int]$Count = 4) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, 2000)
            if ($r.Status -eq 'Success') { $times += $r.RoundtripTime }
        } catch { }
    }
    $avg = $null
    if ($times.Count -gt 0) { $avg = [int](($times | Measure-Object -Average).Average) }
    [pscustomobject]@{ Sent = $Count; Received = $times.Count; AvgMs = $avg }
}

function Get-DefaultGateway {
    try {
        $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        if ($cfg) { return $cfg.IPv4DefaultGateway.NextHop }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- 1. Systemdaten
function Get-SpecsText {
    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $l = New-Object System.Collections.Generic.List[string]

    $l.Add('=== COMPUTER ===')
    $l.Add((Format-Row 'Computername' $env:COMPUTERNAME))
    $l.Add((Format-Row 'Benutzer' "$env:USERDOMAIN\$env:USERNAME"))
    $l.Add((Format-Row 'Hersteller / Modell' "$($cs.Manufacturer) $($cs.Model)"))
    $l.Add((Format-Row 'Seriennummer' $bios.SerialNumber))
    $l.Add((Format-Row 'BIOS' "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('dd.MM.yyyy')))"))
    $l.Add('')
    $l.Add('=== WINDOWS ===')
    $l.Add((Format-Row 'Betriebssystem' $os.Caption))
    $l.Add((Format-Row 'Version / Build' "$($os.Version) (Build $($os.BuildNumber))"))
    $l.Add((Format-Row 'Installiert am' $os.InstallDate.ToString('dd.MM.yyyy')))
    $up = (Get-Date) - $os.LastBootUpTime
    $l.Add((Format-Row 'Letzter Start' "$($os.LastBootUpTime.ToString('dd.MM.yyyy HH:mm')) (vor $([int]$up.TotalDays) Tagen, $($up.Hours) Std.)"))
    $l.Add('')
    $l.Add('=== PROZESSOR / ARBEITSSPEICHER ===')
    $l.Add((Format-Row 'Prozessor' ($cpu.Name -replace '\s+', ' ')))
    $l.Add((Format-Row 'Kerne / Threads' "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"))
    $total = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $free  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $l.Add((Format-Row 'Arbeitsspeicher' "$total GB (frei: $free GB)"))
    foreach ($g in @(Get-CimInstance Win32_VideoController)) {
        $l.Add((Format-Row 'Grafik' "$($g.Name) (Treiber $($g.DriverVersion))"))
    }
    $l.Add('')
    $l.Add('=== LAUFWERKE ===')
    try {
        foreach ($d in @(Get-PhysicalDisk)) {
            $l.Add((Format-Row 'Datenträger' "$($d.FriendlyName) - $($d.MediaType), $([math]::Round($d.Size / 1GB)) GB, Zustand: $($d.HealthStatus)"))
        }
    } catch { }
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
        $pct = if ($d.Size) { [math]::Round($d.FreeSpace / $d.Size * 100) } else { 0 }
        $l.Add((Format-Row "Laufwerk $($d.DeviceID.TrimEnd(':'))" "$([math]::Round($d.Size / 1GB)) GB gesamt, $([math]::Round($d.FreeSpace / 1GB)) GB frei ($pct %)"))
    }
    $l.Add('')
    $l.Add('=== NETZWERK ===')
    try {
        foreach ($n in @(Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' })) {
            $ip = ($n.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '
            $gw = if ($n.IPv4DefaultGateway) { $n.IPv4DefaultGateway.NextHop } else { '-' }
            $dns = ($n.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
            $l.Add((Format-Row $n.InterfaceAlias "IP $ip | Gateway $gw | DNS $dns"))
            $l.Add((Format-Row '  MAC' $n.NetAdapter.MacAddress))
        }
    } catch { $l.Add('Netzwerkinformationen nicht verfügbar.') }
    $l.Add('')
    $l.Add('=== SICHERHEIT ===')
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $l.Add((Format-Row 'Defender aktiv' $mp.AntivirusEnabled))
        $l.Add((Format-Row 'Signaturen vom' $mp.AntivirusSignatureLastUpdated.ToString('dd.MM.yyyy HH:mm')))
    } catch {
        $av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        $l.Add((Format-Row 'Virenschutz' (($av | ForEach-Object { $_.displayName }) -join ', ')))
    }
    $l.Add('')
    $l.Add("Erstellt: $(Get-Date -Format 'dd.MM.yyyy HH:mm') mit SupportToolbox $script:Version")
    $l -join "`r`n"
}

# ---------------------------------------------------------------- 2. Fehlermeldungen
function Get-RecentErrors([int]$Days = 7, [int]$Max = 500) {
    $f = @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddDays(-$Days) }
    @(Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending)
}

function Format-Event($e, [int]$MaxLen = 600) {
    $msg = if ($e.Message) { ($e.Message -replace '\s+', ' ').Trim() } else { '(keine Beschreibung)' }
    if ($msg.Length -gt $MaxLen) { $msg = $msg.Substring(0, $MaxLen) + ' ...' }
    "[{0:dd.MM.yyyy HH:mm:ss}] {1} | ID {2} | Log: {3}`r`n    {4}" -f $e.TimeCreated, $e.ProviderName, $e.Id, $e.LogName, $msg
}

function Get-LastErrorText {
    $ev = Get-RecentErrors -Days 30 -Max 50
    if ($ev.Count -eq 0) { return 'In den letzten 30 Tagen wurden keine Fehler im Windows-Ereignisprotokoll gefunden.' }
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('=== LETZTE FEHLERMELDUNG ===')
    $l.Add((Format-Event $ev[0] 1500))
    $l.Add('')
    if ($ev.Count -gt 1) {
        $l.Add('=== DIE 9 DAVOR ===')
        $ev | Select-Object -Skip 1 -First 9 | ForEach-Object { $l.Add((Format-Event $_ 250)); $l.Add('') }
    }
    $dump = Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($dump) { $l.Add("Letzter Blue-Screen-Absturz (Minidump): $($dump.LastWriteTime.ToString('dd.MM.yyyy HH:mm'))") }
    $l -join "`r`n"
}

# ---------------------------------------------------------------- 3. Fehleranalyse mit Tipps
$script:Rules = @(
    @{ T = 'Unerwartetes Herunterfahren / Absturz'; P = 'Kernel-Power'; I = @(41)
       Tip = "Der PC wurde ohne ordentliches Herunterfahren ausgeschaltet oder ist abgestürzt.`r`n    - Nicht den Netzschalter gedrückt halten, sondern über Start > Herunterfahren abschalten.`r`n    - Bei Notebooks: Akku und Netzteil prüfen, Staub aus den Luftschlitzen entfernen (Überhitzung).`r`n    - Windows-Updates und Treiber aktualisieren. Tritt es häufiger auf, bitte melden." }
    @{ T = 'Blue Screen (Bluescreen)'; P = 'BugCheck|WER-SystemErrorReporting'; I = @(1001)
       Tip = "Windows ist mit einem Blue Screen abgestürzt.`r`n    - Neu gestartet und läuft stabil? Dann zuerst alle Windows-Updates installieren.`r`n    - Neu angeschlossene Geräte (USB, Docking, Drucker) probeweise abstecken.`r`n    - Wiederholt es sich: Foto des Fehlercodes machen und uns schicken." }
    @{ T = 'Festplatten- / Dateisystemfehler'; P = '^disk$|^Ntfs$|stornvme|storahci|volmgr'; I = @(7, 11, 15, 51, 55, 98, 129, 153, 157)
       Tip = "Windows meldet Probleme beim Zugriff auf die Festplatte/SSD. Das kann ein Hardware-Defekt sein!`r`n    - JETZT wichtige Dateien sichern (externe Platte, Cloud).`r`n    - Danach uns kontaktieren - die Platte sollte geprüft/getauscht werden.`r`n    - Keine weiteren großen Installationen durchführen." }
    @{ T = 'Dienst abgestürzt oder nicht startbar'; P = 'Service Control Manager'; I = @(7000, 7001, 7009, 7011, 7023, 7024, 7031, 7034)
       Tip = "Ein Windows-Dienst konnte nicht starten oder wurde beendet.`r`n    - PC einmal komplett neu starten (nicht 'Energie sparen').`r`n    - Name des Dienstes steht in der Meldung - bitte notieren.`r`n    - Betrifft er ein bestimmtes Programm, dieses neu installieren oder aktualisieren." }
    @{ T = 'Programmabsturz'; P = '^Application Error$|\.NET Runtime|Windows Error Reporting'; I = @(1000, 1026, 1001)
       Tip = "Ein Programm ist abgestürzt (Name steht in der Beispiel-Meldung).`r`n    - Programm schließen und neu starten, ggf. PC neu starten.`r`n    - Programm auf die neueste Version aktualisieren.`r`n    - Zusatzprogramme/Add-Ins deaktivieren (z.B. in Outlook, Excel, Browser).`r`n    - Hilft das nicht: Programm über Einstellungen > Apps reparieren oder neu installieren." }
    @{ T = 'Programm hat nicht mehr reagiert'; P = 'Application Hang'; I = @(1002)
       Tip = "Ein Programm ist eingefroren.`r`n    - Beim nächsten Mal 2-3 Minuten warten, oft fängt es sich wieder.`r`n    - Im Task-Manager (Strg+Umschalt+Esc) schauen, ob etwas viel Speicher/CPU braucht.`r`n    - Wenige Programme gleichzeitig offen halten, PC regelmäßig neu starten." }
    @{ T = 'DNS-Probleme (Namensauflösung)'; P = 'DNS Client Events|DNS-Client|Dnscache'; I = @(1014, 1012, 1013, 1023)
       Tip = "Webseiten/Server-Namen konnten nicht aufgelöst werden.`r`n    - In der Toolbox: 'IP erneuern' ausführen.`r`n    - Router für 30 Sekunden vom Strom trennen.`r`n    - Ist ein VPN aktiv? Probeweise trennen und neu verbinden." }
    @{ T = 'WLAN- / DHCP-Verbindungsprobleme'; P = 'WLAN-AutoConfig|Dhcp-Client|NetworkProfile|DHCP'; I = @()
       Tip = "Die Netzwerkverbindung war instabil.`r`n    - Näher zum Router gehen oder per Netzwerkkabel verbinden (Toolbox: 'WLAN auf Ethernet umstellen').`r`n    - In der Toolbox: 'IP erneuern' ausführen.`r`n    - WLAN-Router neu starten." }
    @{ T = 'IP-Adresskonflikt'; P = 'Tcpip'; I = @(4199)
       Tip = "Eine IP-Adresse wird doppelt vergeben.`r`n    - In der Toolbox: 'IP erneuern' ausführen.`r`n    - Besteht das Problem weiter, bitte melden (Router/Server-Einstellung)." }
    @{ T = 'Netzlaufwerk / Dateifreigabe'; P = 'SMBClient|LanmanWorkstation|Mup|Srv'; I = @()
       Tip = "Der Zugriff auf einen Server oder ein Netzlaufwerk ist fehlgeschlagen.`r`n    - Ist das Netzwerk/VPN verbunden? Toolbox: 'Verbindungstest' ausführen.`r`n    - Toolbox: 'Netzlaufwerke neu verbinden'.`r`n    - Passwort kürzlich geändert? Dann Windows neu anmelden." }
    @{ T = 'Windows-Update fehlgeschlagen'; P = 'WindowsUpdateClient|Servicing'; I = @(16, 20, 25, 31, 34)
       Tip = "Ein Windows-Update konnte nicht installiert werden.`r`n    - PC neu starten und Einstellungen > Windows Update > 'Nach Updates suchen' erneut ausführen.`r`n    - Mindestens 10 GB freien Speicherplatz sicherstellen.`r`n    - Einstellungen > System > Problembehandlung > Weitere > Windows Update." }
    @{ T = 'Grafiktreiber reagiert nicht'; P = '^Display$|nvlddmkm|amdkmdag|igfx'; I = @()
       Tip = "Der Grafiktreiber ist kurz ausgefallen (Bild flackert/schwarz).`r`n    - Grafiktreiber beim Hersteller (NVIDIA/AMD/Intel) aktualisieren.`r`n    - Tritt es bei Spielen/Video auf: Überhitzung prüfen." }
    @{ T = 'Gruppenrichtlinien / Domäne'; P = 'GroupPolicy|NETLOGON|Security-Kerberos'; I = @()
       Tip = "Der PC konnte die Firmen-Einstellungen nicht abrufen.`r`n    - Ist VPN/Firmennetz verbunden? Toolbox: 'Verbindungstest'.`r`n    - Nach Verbindungsaufbau PC neu anmelden." }
    @{ T = 'Zeitsynchronisierung'; P = 'Time-Service'; I = @()
       Tip = "Die Uhrzeit konnte nicht synchronisiert werden.`r`n    - Einstellungen > Zeit und Sprache > 'Jetzt synchronisieren'. Falsche Uhrzeit verursacht Anmelde- und Zertifikatsfehler." }
    @{ T = 'Druckerprobleme'; P = 'PrintService|Spooler'; I = @()
       Tip = "Beim Drucken sind Fehler aufgetreten.`r`n    - Toolbox: 'Druckwarteschlange leeren' ausführen.`r`n    - Drucker aus-/einschalten, Kabel/WLAN prüfen." }
    @{ T = 'Virenschutz hat Bedrohung erkannt'; P = 'Windows Defender'; I = @(1006, 1007, 1116, 1117, 1118, 1119)
       Tip = "Der Virenschutz hat etwas gefunden oder blockiert.`r`n    - Windows-Sicherheit öffnen > Viren- & Bedrohungsschutz > Schutzverlauf prüfen.`r`n    - Keine verdächtigen Anhänge öffnen. Bitte uns informieren." }
    @{ T = 'Bekannt harmlos (kann ignoriert werden)'; P = 'DistributedCOM|Schannel|Winlogon|CertificateServicesClient'; I = @(10016, 10005, 36874, 36887, 36888, 36871, 1014)
       Tip = "Diese Meldungen sind bei Windows häufig und in der Regel ohne Auswirkung - nichts unternehmen." }
)

function Get-AnalysisText {
    $days = 14
    $ev = Get-RecentErrors -Days $days -Max 1500
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("=== FEHLERANALYSE (letzte $days Tage, $($ev.Count) Fehlermeldungen) ===")
    $l.Add('')

    $matched = @(); $unknown = @()
    foreach ($e in $ev) {
        $rule = $null
        foreach ($r in $script:Rules) {
            if ($e.ProviderName -match $r.P -and ($r.I.Count -eq 0 -or $r.I -contains $e.Id)) { $rule = $r; break }
        }
        if ($rule) { $matched += [pscustomobject]@{ Rule = $rule; Event = $e } } else { $unknown += $e }
    }

    $groups = $matched | Group-Object { $_.Rule.T } | Sort-Object { ($_.Group[0].Rule.T -like 'Bekannt harmlos*') }, @{ Expression = 'Count'; Descending = $true }
    if ($groups) {
        foreach ($g in $groups) {
            $first = $g.Group[0]
            $l.Add(('>> {0}  ({1}x, zuletzt {2:dd.MM.yyyy HH:mm})' -f $g.Name, $g.Count, $first.Event.TimeCreated))
            $l.Add('   Beispiel: ' + ((Format-Event $first.Event 220) -replace "`r`n    ", ' - '))
            $l.Add('   TIPP: ' + $first.Rule.Tip)
            $l.Add('')
        }
    } else {
        $l.Add('Keine bekannten Fehlermuster gefunden.')
        $l.Add('')
    }
    if ($unknown.Count -gt 0) {
        $l.Add("--- Weitere $($unknown.Count) Fehler ohne bekannte Lösung - häufigste Quellen: ---")
        $unknown | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
            $l.Add(('   {0}x  {1}' -f $_.Count, $_.Name))
        }
        $l.Add('')
    }

    $l.Add('=== ALLGEMEINER ZUSTANDS-CHECK ===')
    $issues = 0
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
        if ($d.Size) {
            $pct = [math]::Round($d.FreeSpace / $d.Size * 100); $gb = [math]::Round($d.FreeSpace / 1GB, 1)
            if ($pct -lt 10 -or $gb -lt 10) {
                $l.Add("[!] Laufwerk $($d.DeviceID) ist fast voll ($gb GB frei, $pct %). TIPP: Papierkorb leeren, Toolbox 'Temp-Dateien löschen', nicht benötigte Programme deinstallieren, Downloads aufräumen."); $issues++
            }
        }
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $days = ((Get-Date) - $os.LastBootUpTime).TotalDays
    if ($days -gt 14) { $l.Add("[!] Der PC läuft seit $([int]$days) Tagen ohne Neustart. TIPP: Einmal neu starten (Start > Neu starten) - das behebt erstaunlich viele Probleme."); $issues++ }
    $ramUsed = 100 - [math]::Round($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
    if ($ramUsed -gt 90) { $l.Add("[!] Arbeitsspeicher zu $ramUsed % belegt. TIPP: Nicht benötigte Programme und Browser-Tabs schließen."); $issues++ }
    $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($reboot) { $l.Add('[!] Windows wartet auf einen Neustart (Updates). TIPP: PC jetzt neu starten.'); $issues++ }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.AntivirusSignatureAge -gt 7) { $l.Add("[!] Virensignaturen sind $($mp.AntivirusSignatureAge) Tage alt. TIPP: Windows Update ausführen."); $issues++ }
        if (-not $mp.RealTimeProtectionEnabled) { $l.Add('[!] Echtzeitschutz von Defender ist aus. TIPP: Windows-Sicherheit öffnen und Schutz einschalten (sofern kein anderer Virenschutz installiert ist).'); $issues++ }
    } catch { }
    if ($issues -eq 0) { $l.Add('[OK] Keine Auffälligkeiten bei Speicherplatz, Neustart, Arbeitsspeicher und Updates.') }
    $l -join "`r`n"
}

function Get-SupportReportText {
    "SUPPORT-BERICHT $env:COMPUTERNAME - $(Get-Date -Format 'dd.MM.yyyy HH:mm')`r`n" +
    ('=' * 60) + "`r`n`r`n" + (Get-SpecsText) + "`r`n`r`n" + ('=' * 60) + "`r`n`r`n" +
    (Get-LastErrorText) + "`r`n`r`n" + ('=' * 60) + "`r`n`r`n" + (Get-AnalysisText)
}

# ---------------------------------------------------------------- 4. Netzwerk
function Invoke-IpRenew {
    $a = Test-Admin 'ipconfig /release und /renew'
    if ($a -ne $true) { return $a }
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('> ipconfig /release'); $l.Add(((& ipconfig /release 2>&1) | Out-String).Trim())
    Start-Sleep -Seconds 2
    $l.Add('> ipconfig /renew'); $l.Add(((& ipconfig /renew 2>&1) | Out-String).Trim())
    $l.Add('> ipconfig /flushdns'); $l.Add(((& ipconfig /flushdns 2>&1) | Out-String).Trim())
    Start-Sleep -Seconds 2
    $l.Add('')
    $l.Add('=== NEUE ADRESSE ===')
    try {
        foreach ($n in @(Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address })) {
            $l.Add((Format-Row $n.InterfaceAlias ($n.IPv4Address[0].IPAddress)))
        }
    } catch { }
    if (Test-PingHost '1.1.1.1' 2 | Where-Object { $_.Received -gt 0 }) { $l.Add("`r`n[OK] Internetverbindung funktioniert wieder.") }
    else { $l.Add("`r`n[!] Noch keine Internetverbindung. Bitte ein paar Sekunden warten und 'Verbindungstest' ausführen; ggf. Router neu starten.") }
    $l -join "`r`n"
}

function Invoke-ConnectionTest([string]$Target, [int]$Port) {
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("=== VERBINDUNGSTEST zu $Target (Port $Port) ===")
    $l.Add('')
    $fail = $null
    $gw = Get-DefaultGateway
    if ($gw) {
        $p = Test-PingHost $gw 3
        if ($p.Received -gt 0) { $l.Add("[OK]   1. Router/Gateway $gw erreichbar ($($p.AvgMs) ms)") }
        else { $l.Add("[FEHL] 1. Router/Gateway $gw antwortet nicht"); $fail = 'lokal' }
    } else { $l.Add('[FEHL] 1. Kein Standardgateway - keine aktive Netzwerkverbindung'); $fail = 'lokal' }

    $p = Test-PingHost '1.1.1.1' 3
    if ($p.Received -gt 0) { $l.Add("[OK]   2. Internet (1.1.1.1) erreichbar ($($p.AvgMs) ms)") }
    else { $l.Add('[FEHL] 2. Internet (1.1.1.1) nicht erreichbar'); if (-not $fail) { $fail = 'internet' } }

    $ips = $null
    try { $ips = [System.Net.Dns]::GetHostAddresses($Target) } catch { }
    if ($ips) { $l.Add("[OK]   3. Namensauflösung: $Target = $(($ips | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join ', ')") }
    else { $l.Add("[FEHL] 3. Name '$Target' konnte nicht aufgelöst werden"); if (-not $fail) { $fail = 'dns' } }

    if ($ips) {
        $p = Test-PingHost $Target 4
        if ($p.Received -gt 0) { $l.Add("[OK]   4. Ping zu $Target ($($p.Received)/$($p.Sent) Antworten, $($p.AvgMs) ms)") }
        else { $l.Add("[INFO] 4. Ping zu $Target ohne Antwort (manche Server blockieren Ping)") }
        if (Test-TcpPort $Target $Port) { $l.Add("[OK]   5. Port $Port auf $Target ist offen") }
        else { $l.Add("[FEHL] 5. Port $Port auf $Target nicht erreichbar"); if (-not $fail) { $fail = 'dienst' } }
    }
    $l.Add('')
    $l.Add('=== ERGEBNIS ===')
    switch ($fail) {
        'lokal'    { $l.Add('Der PC hat keine funktionierende Verbindung zum eigenen Netzwerk. Kabel/WLAN prüfen, WLAN aus-/einschalten oder Toolbox: "IP erneuern".') }
        'internet' { $l.Add('Das lokale Netzwerk geht, aber das Internet nicht. Router neu starten (30 Sek. vom Strom), sonst Störung beim Provider.') }
        'dns'      { $l.Add('Internet geht, aber Namen werden nicht aufgelöst (DNS). Toolbox: "IP erneuern"; bei VPN: neu verbinden.') }
        'dienst'   { $l.Add("Der Server ist im Netz, aber der Dienst auf Port $Port antwortet nicht. Server/Dienst gestört oder durch Firewall blockiert - bitte Support informieren.") }
        default    { $l.Add('Alles in Ordnung - die Verbindung funktioniert.') }
    }
    $l -join "`r`n"
}

function Get-WifiAdapters   { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' }) }
function Get-EthernetAdapters { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless|WLAN|Bluetooth' }) }

function Switch-WifiToEthernet {
    $eth = @(Get-EthernetAdapters | Where-Object { $_.Status -eq 'Up' })
    $wifi = @(Get-WifiAdapters | Where-Object { $_.Status -eq 'Up' })
    if ($eth.Count -eq 0) { return "Es ist kein Netzwerkkabel verbunden.`r`n`r`nBitte das Kabel einstecken (am PC und am Router/Wandanschluss) und es dann nochmal versuchen." }
    $ipOk = $false
    foreach ($e in $eth) {
        $ip = Get-NetIPAddress -InterfaceIndex $e.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' }
        if ($ip) { $ipOk = $true }
    }
    if (-not $ipOk) { return "Das Netzwerkkabel ist eingesteckt, aber der PC hat darüber noch keine gültige Adresse.`r`nBitte 30 Sekunden warten und erneut versuchen oder 'IP erneuern' ausführen." }
    if ($wifi.Count -eq 0) { return "[OK] Kabelverbindung ($($eth[0].Name)) ist aktiv. WLAN ist bereits aus oder nicht vorhanden." }
    $a = Test-Admin 'WLAN-Adapter deaktivieren'
    if ($a -ne $true) {
        & netsh wlan disconnect | Out-Null
        return "WLAN wurde getrennt, kann sich aber automatisch wieder verbinden.`r`nMit Administratorrechten wird der WLAN-Adapter dauerhaft ausgeschaltet.`r`n`r`n$a"
    }
    foreach ($w in $wifi) { Disable-NetAdapter -Name $w.Name -Confirm:$false }
    "[OK] WLAN ($(($wifi | ForEach-Object { $_.Name }) -join ', ')) wurde ausgeschaltet.`r`nDer PC nutzt jetzt das Netzwerkkabel ($($eth[0].Name)).`r`n`r`nZum Zurückschalten: 'WLAN wieder einschalten'."
}

function Enable-Wifi {
    $a = Test-Admin 'WLAN-Adapter aktivieren'
    if ($a -ne $true) { return $a }
    $off = @(Get-WifiAdapters | Where-Object { $_.Status -eq 'Disabled' })
    if ($off.Count -eq 0) { return 'Es ist kein ausgeschalteter WLAN-Adapter vorhanden.' }
    foreach ($w in $off) { Enable-NetAdapter -Name $w.Name -Confirm:$false }
    "[OK] WLAN wurde wieder eingeschaltet ($(($off | ForEach-Object { $_.Name }) -join ', ')). Die Verbindung steht in wenigen Sekunden."
}

function Connect-NetworkDrives {
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('=== NETZLAUFWERKE ===')
    $drives = @{}
    foreach ($k in @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $drives[$k.PSChildName.ToUpper()] = (Get-ItemProperty $k.PSPath).RemotePath
    }
    foreach ($d in @($script:Config.NetworkDrives)) { if ($d.Letter) { $drives[([string]$d.Letter).TrimEnd(':').ToUpper()] = $d.Path } }
    if ($drives.Count -eq 0) { $l.Add('Es sind keine Netzlaufwerke eingerichtet.'); return ($l -join "`r`n") }

    $status = @{}
    try { Get-SmbMapping -ErrorAction Stop | ForEach-Object { $status[$_.LocalPath.TrimEnd(':').ToUpper()] = [string]$_.Status } } catch { }

    foreach ($letter in ($drives.Keys | Sort-Object)) {
        $path = $drives[$letter]
        if ($status[$letter] -eq 'OK') { $l.Add("[OK]   ${letter}: $path - bereits verbunden"); continue }
        $srv = ($path -replace '^\\\\', '') -split '\\' | Select-Object -First 1
        if (-not (Test-TcpPort $srv 445 2500)) {
            $l.Add("[FEHL] ${letter}: $path - Server '$srv' nicht erreichbar (Netzwerk/VPN verbunden?)"); continue
        }
        & net use "${letter}:" /delete /y 2>&1 | Out-Null
        $out = (& net use "${letter}:" $path /persistent:yes 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) { $l.Add("[OK]   ${letter}: $path - neu verbunden") }
        else { $l.Add("[FEHL] ${letter}: $path - $($out -replace '\s+', ' ')") }
    }
    $l.Add('')
    $l.Add('Hinweis: Bei Fehlern wie "Zugriff verweigert" oder "falsches Kennwort" bitte Windows neu anmelden oder Support informieren.')
    $l -join "`r`n"
}

# ---------------------------------------------------------------- 5. Screenshots
function Save-Screenshot([int]$DelaySeconds) {
    $dir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Support-Screenshots'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir ("Screenshot_{0:yyyyMMdd_HHmmss}.png" -f (Get-Date))
    if ($script:Form) { $script:Form.Hide() }
    Start-Sleep -Milliseconds ([math]::Max(600, $DelaySeconds * 1000))
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    [System.Windows.Forms.Clipboard]::SetImage($bmp)
    $bmp.Dispose()
    if ($script:Form) { $script:Form.Show(); $script:Form.Activate() }
    "[OK] Screenshot gespeichert:`r`n$file`r`n`r`nDas Bild liegt außerdem in der Zwischenablage und kann mit Strg+V in eine E-Mail eingefügt werden."
}

# ---------------------------------------------------------------- 6. Extras
function Clear-PrintQueue {
    $a = Test-Admin 'Druckdienst neu starten'
    if ($a -ne $true) { return $a }
    Stop-Service Spooler -Force
    Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Service Spooler
    '[OK] Die Druckwarteschlange wurde geleert und der Druckdienst neu gestartet. Bitte den Druckauftrag erneut senden.'
}

function Clear-TempFiles {
    $before = (Get-PSDrive C).Free
    $limit = (Get-Date).AddDays(-1)
    Get-ChildItem $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $limit } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $freed = [math]::Round(((Get-PSDrive C).Free - $before) / 1MB)
    "[OK] Temporäre Dateien (älter als 1 Tag) wurden gelöscht. Freigegeben: ca. $([math]::Max(0, $freed)) MB.`r`nTipp: Zusätzlich den Papierkorb leeren."
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    '[OK] Der Windows-Explorer (Taskleiste, Desktop) wurde neu gestartet.'
}

function Start-QuickAssist {
    Start-Process quickassist.exe -ErrorAction SilentlyContinue
    "Die Windows-Remotehilfe (Schnellhilfe) wurde gestartet.`r`nBitte den Sicherheitscode, den Sie vom Support erhalten, dort eingeben."
}

function Send-OutputByMail([string]$Body) {
    if ([string]::IsNullOrWhiteSpace($Body)) { return 'Es gibt noch nichts zu senden. Bitte zuerst z.B. "Computer-Daten anzeigen" ausführen.' }
    $subject = "Support-Anfrage von $env:COMPUTERNAME ($env:USERNAME)"
    $to = $script:Config.SupportMail
    try { [System.Windows.Forms.Clipboard]::SetText($Body) } catch { }
    try {
        $ol = New-Object -ComObject Outlook.Application
        $m = $ol.CreateItem(0); $m.To = $to; $m.Subject = $subject; $m.Body = $Body; $m.Display()
        return 'Eine neue E-Mail in Outlook wurde vorbereitet. Bitte prüfen und auf "Senden" klicken.'
    } catch { }
    $note = "`r`n`r`n[Text gekürzt - der vollständige Text liegt in der Zwischenablage: mit Strg+V einfügen]"
    $text = $Body
    $uri = ''
    while ($true) {
        $uri = "mailto:$to?subject=$([uri]::EscapeDataString($subject))&body=$([uri]::EscapeDataString($text))"
        if ($uri.Length -le 1900 -or $text.Length -lt 100) { break }
        $text = $Body.Substring(0, [math]::Max(50, [int]($text.Length * 0.8))) + $note
    }
    Start-Process $uri
    'Ihr E-Mail-Programm wurde geöffnet. Der vollständige Text liegt zusätzlich in der Zwischenablage (Strg+V zum Einfügen).'
}

if ($NoGui) { return }

# ================================================================ GUI
$script:Form = New-Object System.Windows.Forms.Form
$f = $script:Form
$f.Text = "$($script:Config.CompanyName) - SupportToolbox $script:Version"
$f.StartPosition = 'CenterScreen'
$f.Size = New-Object System.Drawing.Size(1080, 740)
$f.MinimumSize = New-Object System.Drawing.Size(900, 560)
$f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$script:Txt = New-Object System.Windows.Forms.TextBox
$script:Txt.Multiline = $true; $script:Txt.ReadOnly = $true; $script:Txt.ScrollBars = 'Both'; $script:Txt.WordWrap = $false
$script:Txt.Font = New-Object System.Drawing.Font('Consolas', 10)
$script:Txt.BackColor = [System.Drawing.Color]::White
$script:Txt.Dock = 'Fill'

$top = New-Object System.Windows.Forms.Panel; $top.Dock = 'Top'; $top.Height = 42
$lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Server / Adresse:'; $lbl.Location = '10,12'; $lbl.AutoSize = $true
$script:HostBox = New-Object System.Windows.Forms.TextBox; $script:HostBox.Location = '120,9'; $script:HostBox.Width = 260; $script:HostBox.Text = $script:Config.TestHost
$lbl2 = New-Object System.Windows.Forms.Label; $lbl2.Text = 'Port:'; $lbl2.Location = '395,12'; $lbl2.AutoSize = $true
$script:PortBox = New-Object System.Windows.Forms.TextBox; $script:PortBox.Location = '430,9'; $script:PortBox.Width = 60; $script:PortBox.Text = [string]$script:Config.TestPort
$top.Controls.AddRange(@($lbl, $script:HostBox, $lbl2, $script:PortBox))

$bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 46
function New-BottomButton([string]$Text, [int]$X, [int]$W, [scriptblock]$Click) {
    $b = New-Object System.Windows.Forms.Button; $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, 8); $b.Size = New-Object System.Drawing.Size($W, 30)
    $b.Add_Click($Click); $bottom.Controls.Add($b)
}
New-BottomButton 'In Zwischenablage kopieren' 10 190 { if ($script:Txt.Text) { [System.Windows.Forms.Clipboard]::SetText($script:Txt.Text); $script:Status.Text = 'In die Zwischenablage kopiert.' } }
New-BottomButton 'Per E-Mail an Support senden' 210 210 { $script:Txt.AppendText("`r`n`r`n" + (Send-OutputByMail $script:Txt.Text)) }
New-BottomButton 'Als Datei speichern' 430 150 {
    if (-not $script:Txt.Text) { return }
    $p = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Support_{0}_{1:yyyyMMdd_HHmm}.txt" -f $env:COMPUTERNAME, (Get-Date))
    [IO.File]::WriteAllText($p, $script:Txt.Text, (New-Object System.Text.UTF8Encoding($true)))
    $script:Status.Text = "Gespeichert: $p"
}
$script:Status = New-Object System.Windows.Forms.Label; $script:Status.AutoSize = $true; $script:Status.Anchor = 'Left,Bottom'; $script:Status.Location = '650,15'
$adminText = if ($script:IsAdmin) { 'Administrator-Modus' } else { 'Standard-Modus (Admin-Funktionen gesperrt)' }
$script:Status.Text = $adminText
$bottom.Controls.Add($script:Status)

$script:Left = New-Object System.Windows.Forms.FlowLayoutPanel
$script:Left.Dock = 'Left'; $script:Left.Width = 245; $script:Left.FlowDirection = 'TopDown'; $script:Left.WrapContents = $false; $script:Left.AutoScroll = $true
$script:Left.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 8)
$script:Left.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 250)

function Set-Output([string]$Text) { $script:Txt.Text = ($Text -replace "`r?`n", "`r`n"); $script:Txt.SelectionStart = 0; $script:Txt.ScrollToCaret() }

function Invoke-Task([string]$Title, [scriptblock]$Action) {
    Set-Output "$Title`r`n`r`nBitte warten ..."
    $script:Status.Text = "$Title ..."
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    try { $result = (& $Action | Out-String).TrimEnd() }
    catch { $result = "Fehler: $($_.Exception.Message)" }
    finally { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
    Set-Output $result
    $script:Status.Text = "$Title - fertig"
}

function New-Section([string]$Text) {
    $x = New-Object System.Windows.Forms.Label
    $x.Text = $Text; $x.AutoSize = $false; $x.Width = 222; $x.Height = 28; $x.TextAlign = 'BottomLeft'
    $x.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $x.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $script:Left.Controls.Add($x)
}
function New-ActionButton([string]$Text, [scriptblock]$Action, [switch]$Confirm, [string]$ConfirmText) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = 222; $b.Height = 30; $b.TextAlign = 'MiddleLeft'
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $b.FlatStyle = 'Flat'; $b.BackColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 208, 220)
    $b.Tag = @{ Action = $Action; Confirm = [bool]$Confirm; ConfirmText = $ConfirmText }
    $b.Add_Click({
        param($s, $e)
        $t = $s.Tag
        if ($t.Confirm) {
            $r = [System.Windows.Forms.MessageBox]::Show($t.ConfirmText, $s.Text, 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
        }
        Invoke-Task $s.Text $t.Action
    })
    $script:Left.Controls.Add($b)
}

New-Section 'Informationen'
New-ActionButton 'Computer-Daten anzeigen' { Get-SpecsText }
New-ActionButton 'Letzte Fehlermeldung' { Get-LastErrorText }
New-ActionButton 'Fehler analysieren + Tipps' { Get-AnalysisText }
New-ActionButton 'Kompletter Support-Bericht' { Get-SupportReportText }

New-Section 'Netzwerk'
New-ActionButton 'IP erneuern (Release/Renew)' { Invoke-IpRenew } -Confirm -ConfirmText 'Die Netzwerkverbindung wird kurz unterbrochen. Fortfahren?'
New-ActionButton 'Verbindungstest zum Server' { Invoke-ConnectionTest $script:HostBox.Text.Trim() ([int]$script:PortBox.Text) }
New-ActionButton 'WLAN auf Ethernet umstellen' { Switch-WifiToEthernet } -Confirm -ConfirmText 'Wenn ein Netzwerkkabel verbunden ist, wird das WLAN ausgeschaltet. Fortfahren?'
New-ActionButton 'WLAN wieder einschalten' { Enable-Wifi }
New-ActionButton 'Netzlaufwerke neu verbinden' { Connect-NetworkDrives }

New-Section 'Screenshots'
New-ActionButton 'Screenshot (sofort)' { Save-Screenshot 1 }
New-ActionButton 'Screenshot in 5 Sekunden' { Save-Screenshot 5 }
New-ActionButton 'Screenshot-Ordner öffnen' {
    $d = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Support-Screenshots'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    Start-Process explorer.exe $d; "Ordner: $d"
}

New-Section 'Schnelle Reparaturen'
New-ActionButton 'Druckwarteschlange leeren' { Clear-PrintQueue }
New-ActionButton 'Temp-Dateien löschen' { Clear-TempFiles } -Confirm -ConfirmText 'Temporäre Dateien (älter als 1 Tag) werden gelöscht. Fortfahren?'
New-ActionButton 'Explorer neu starten' { Restart-Explorer } -Confirm -ConfirmText 'Taskleiste und Desktop verschwinden kurz. Fortfahren?'
New-ActionButton 'Fernhilfe starten (Schnellhilfe)' { Start-QuickAssist }

if (-not $script:IsAdmin) {
    New-Section ''
    $adm = New-Object System.Windows.Forms.Button
    $adm.Text = 'Als Administrator neu starten'; $adm.Width = 222; $adm.Height = 32
    $adm.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 214); $adm.FlatStyle = 'Flat'
    $adm.Add_Click({
        try {
            if ($script:IsExe) { Start-Process $script:SelfPath -Verb RunAs }
            else { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" }
            $script:Form.Close()
        } catch { }
    })
    $script:Left.Controls.Add($adm)
}

# Reihenfolge: Fill zuerst, dann die Randbereiche
$f.Controls.Add($script:Txt)
$f.Controls.Add($top)
$f.Controls.Add($bottom)
$f.Controls.Add($script:Left)

Set-Output ("Willkommen bei der SupportToolbox $script:Version`r`n`r`n" +
    "Wählen Sie links eine Aktion. Das Ergebnis erscheint hier und kann per E-Mail an den Support gesendet werden.`r`n`r`n" +
    "Support: $($script:Config.SupportMail)`r`n" + $adminText)

if ($PreviewPath) {
    $f.Show(); [System.Windows.Forms.Application]::DoEvents()
    $demo = (Get-SpecsText) -replace [regex]::Escape($env:COMPUTERNAME), 'PC-BUCHHALTUNG' -replace [regex]::Escape($env:USERNAME), 'maria.huber' -replace '(?m)^(Seriennummer:\s+).*', '${1}5CD0000XXX' -replace '(\w\w-){5}\w\w', 'AA-BB-CC-DD-EE-FF' -replace 'HP HP .*', 'HP EliteBook 840 G10' -replace '(?m)^VMware.*\r?\n.*\r?\n', ''
    Set-Output $demo; [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap $f.Width, $f.Height
    $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $f.Width, $f.Height))
    $bmp.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $f.Close(); return
}

[void]$f.ShowDialog()
