# Baut SupportToolbox.exe aus dem Skript (benötigt das Modul ps2exe)
if (-not (Get-Module ps2exe -ListAvailable)) { Install-Module ps2exe -Scope CurrentUser -Force }
Import-Module ps2exe
Invoke-ps2exe -inputFile "$PSScriptRoot\SupportToolbox.ps1" -outputFile "$PSScriptRoot\SupportToolbox.exe" -noConsole `
    -title 'SupportToolbox' -product 'SupportToolbox' -version '1.1.1.0' -company 'fmatsch' -copyright 'MIT License'


