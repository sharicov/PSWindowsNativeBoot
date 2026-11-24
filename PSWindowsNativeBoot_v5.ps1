<#
    The MIT License (MIT)

    Copyright (c) 2017 Stefan H

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

    ---------------------------------------------------------------------------
    PSWindowsNativeBoot v5 (extended). See README_v5.md for the full changelog.
    Folder layout (next to this script):
        Tools\    portable programs (.exe directly or in subfolders) -> copied to C:\Tools
        Drivers\  driver folders / .inf files (may be empty)          -> injected offline
    Additions over the original:
      - Source: ISO, install.wim / install.esd / install.swm, or a folder/drive
      - Edition picker (-Edition / -Index, Get-WindowsSetupEdition)
      - Compression choice (None, XPRESS4K, XPRESS8K, XPRESS16K, LZX)
      - VHD or VHDX, expandable or fixed, GPT or MBR
      - Boot options (UEFI / BIOS / ALL, description, target boot drive, locale)
      - Offline registry tweaks (Defender, UAC, hibernation, pagefile, ...)
      - Custom .reg import, RunOnce commands
      - Offline drivers, updates (.msu/.cab), .NET 3.5, Appx removal
      - unattend.xml (own file or generated: account, computer name, locale, ...)
      - Save / load settings profiles (JSON)
      - try/finally cleanup, exit-code checks, locale-independent logic
#>

#Requires -RunAsAdministrator
#Requires -Version 5.1

$script:Version = '5'

# Folder of this script (Tools and Drivers live here); falls back to the current directory
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }

# Names of the temporary registry hives loaded under HKLM
$script:HiveName = @{ SYSTEM = 'OFFSYS'; SOFTWARE = 'OFFSOFT'; USER = 'OFFUSER' }   # USER = Default profile (NTUSER.DAT)

$script:DefaultCompressFolders = @(
    'Program Files'
    'Program Files (x86)'
    'ProgramData'
    'MSOCache'
    'Windows\assembly'
    'Windows\InfusedApps'
    'Windows\Installer'
    'Windows\Panther'
    'Windows\SoftwareDistribution'
    'Windows\System32\catroot2'
    'Windows\System32\LogFiles'
)

#region Helpers

function Invoke-Native {
    # Runs an external program, logs its output and throws on a non-zero exit code.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )

    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'
    $ErrorActionPreference = 'Continue'

    Write-Verbose "> $FilePath $($Arguments -join ' ')"
    $output = & $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    $script:LastNativeExitCode = $code
    $output | ForEach-Object { Write-Verbose "$_" }

    if ($code -ne 0 -and -not $IgnoreExitCode) {
        $tail = ($output | Select-Object -Last 8 | ForEach-Object { "$_" }) -join [Environment]::NewLine
        throw "$FilePath failed with exit code $code.$([Environment]::NewLine)$tail"
    }
    if ($code -ne 0) {
        Write-Verbose "$FilePath returned exit code $code (ignored)"
    }
    return $output
}

function ConvertTo-XmlText {
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

#endregion

#region Disk images

function Mount-VirtualDiskImage {
    # Mounts an .iso/.vhd/.vhdx and returns the first assigned drive letter, e.g. "E:"
    # If Windows does not assign a letter to a VHD(X) volume (automount disabled, letter not
    # remembered after re-attach, ...), one is assigned explicitly.
    [CmdletBinding()]
    param(
        # Location of disk image
        [Parameter(Mandatory=$true,
                   Position=1,
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ImagePath
    )

    $ImagePath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath

    if (-not (Get-DiskImage -ImagePath $ImagePath).Attached) {
        $null = Mount-DiskImage -ImagePath $ImagePath
    }

    $assignTried = $false
    for ($i = 0; $i -lt 40; $i++) {
        # 1. Volumes of the image (works for ISO and VHD(X))
        $volume = Get-DiskImage -ImagePath $ImagePath |
            Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Select-Object -First 1
        if ($volume) {
            return "$($volume.DriveLetter):"
        }

        # 2. VHD(X): look at the partitions and assign a letter if none was given
        if ($i -ge 4) {
            $disk = Get-DiskImage -ImagePath $ImagePath | Get-Disk -ErrorAction SilentlyContinue
            if ($disk) {
                $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -notin 'Reserved', 'System', 'Recovery' } |
                    Sort-Object Size -Descending |
                    Select-Object -First 1
                if ($partition) {
                    $letter = "$($partition.DriveLetter)".Trim([char]0)
                    if ($letter) { return "${letter}:" }
                    if (-not $assignTried) {
                        $assignTried = $true
                        Write-Verbose "No drive letter on disk $($disk.Number) partition $($partition.PartitionNumber), assigning one"
                        try {
                            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
                        }
                        catch { Write-Verbose "Add-PartitionAccessPath failed: $($_.Exception.Message)" }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "No drive letter could be assigned to '$ImagePath'. Check 'diskpart' > 'automount' and whether all drive letters are in use."
}

function New-VirtualDiskImage {
    [CmdletBinding()]
    param(
        # Location of created disk image (.vhd or .vhdx)
        [Parameter(Mandatory=$true,
                   Position=0,
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ImagePath,

        # Disk image size
        [Parameter(Mandatory=$true)]
        [ValidateRange(1GB, 2040GB)]
        [long]
        $Size,

        [ValidateSet('Expandable', 'Fixed')]
        [string]
        $DiskType = 'Expandable',

        [ValidateSet('GPT', 'MBR')]
        [string]
        $PartitionStyle = 'GPT',

        [string]
        $VolumeLabel = 'Windows'
    )

    $extension = [IO.Path]::GetExtension($ImagePath).ToLower()
    if ($extension -notin '.vhd', '.vhdx') {
        throw "ImagePath must end in .vhd or .vhdx (got '$extension')."
    }
    $storageType = $extension.TrimStart('.').ToUpper()

    if (Test-Path -LiteralPath $ImagePath) {
        throw "'$ImagePath' already exists. Choose another path or delete the file."
    }
    $directory = Split-Path -Path $ImagePath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    # Create the virtual disk with diskpart (no Hyper-V cmdlets needed).
    # Success is verified by exit code and file existence, not by (localized) text output.
    $dpFile = Join-Path ([IO.Path]::GetTempPath()) "psnb-diskpart-$([guid]::NewGuid().ToString('N')).txt"
    try {
        "create vdisk file=`"$ImagePath`" type=$($DiskType.ToLower()) maximum=$([long]($Size / 1MB))" |
            Set-Content -LiteralPath $dpFile -Encoding ASCII
        $output = Invoke-Native -FilePath 'diskpart.exe' -Arguments @('/s', $dpFile) -IgnoreExitCode
        $code = $script:LastNativeExitCode
    }
    finally {
        Remove-Item -LiteralPath $dpFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $ImagePath)) {
        $log = Join-Path $script:ScriptRoot 'diskpart.log'
        $output | Out-File -LiteralPath $log
        throw "Failed to create virtual disk image, see $log for more information."
    }

    # Mount the virtual disk image without drive letter
    $null = Mount-DiskImage -ImagePath $ImagePath -StorageType $storageType -NoDriveLetter
    try {
        $disk = Get-DiskImage -ImagePath $ImagePath | Get-Disk
        if (-not $disk -or $disk.PartitionStyle -ne 'RAW') {
            throw 'Could not find the new disk image as an uninitialized (RAW) disk.'
        }

        # Suppress the "You need to format" dialog by temporarily stopping the service
        $service = Get-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
        $stopped = $false
        if ($service -and $service.Status -eq 'Running') {
            Stop-Service -Name ShellHWDetection
            $stopped = $true
        }
        try {
            Initialize-Disk -Number $disk.Number -PartitionStyle $PartitionStyle
            $partition = New-Partition -DiskNumber $disk.Number -AssignDriveLetter -UseMaximumSize
            $null = Format-Volume -Partition $partition -FileSystem NTFS `
                -NewFileSystemLabel $VolumeLabel -Confirm:$false
        }
        finally {
            if ($stopped) { Start-Service -Name ShellHWDetection }
        }
    }
    finally {
        Dismount-DiskImage -ImagePath $ImagePath | Out-Null
    }
}

#endregion

#region Source handling

function Resolve-WindowsSource {
    # Accepts an .iso, .wim/.esd/.swm file, or a folder/drive that contains \sources.
    # Returns the image file and (optionally) the ISO that was mounted by this call.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Source
    )

    if ($Source -match '^[A-Za-z]:$') { $Source += '\' }
    $item = Get-Item -LiteralPath $Source -ErrorAction Stop

    $result = [pscustomobject]@{
        ImageFile  = $null
        SwmPattern = $null
        SxsPath    = $null
        MountedIso = $null   # set only if this call mounted the ISO
    }

    try {
        $root = $null
        if ($item.PSIsContainer) {
            $root = $item.FullName
        }
        else {
            switch ($item.Extension.ToLower()) {
                '.iso' {
                    $wasAttached = (Get-DiskImage -ImagePath $item.FullName).Attached
                    $letter = Mount-VirtualDiskImage -ImagePath $item.FullName
                    if (-not $wasAttached) { $result.MountedIso = $item.FullName }
                    $root = "$letter\"
                }
                { $_ -in '.wim', '.esd' } {
                    $result.ImageFile = $item.FullName
                }
                '.swm' {
                    $result.ImageFile  = $item.FullName
                    $result.SwmPattern = Join-Path $item.DirectoryName (($item.BaseName -replace '\d+$', '') + '*.swm')
                }
                default {
                    throw "Unsupported source type '$($item.Extension)'. Use .iso, .wim, .esd, .swm or a folder."
                }
            }
        }

        if ($root) {
            $sources = Join-Path $root 'sources'
            if (-not (Test-Path -LiteralPath $sources)) {
                throw "No 'sources' folder found in '$root'."
            }
            foreach ($name in 'install.wim', 'install.esd', 'install.swm') {
                $candidate = Join-Path $sources $name
                if (Test-Path -LiteralPath $candidate) {
                    $result.ImageFile = $candidate
                    if ($name -eq 'install.swm') {
                        $result.SwmPattern = Join-Path $sources 'install*.swm'
                    }
                    break
                }
            }
            $sxs = Join-Path $sources 'sxs'
            if (Test-Path -LiteralPath $sxs) { $result.SxsPath = $sxs }
        }

        if (-not $result.ImageFile) {
            throw "No install.wim, install.esd or install.swm found in '$Source'."
        }
    }
    catch {
        if ($result.MountedIso) {
            Dismount-DiskImage -ImagePath $result.MountedIso | Out-Null
        }
        throw
    }

    return $result
}

function Get-WindowsSetupEdition {
    # Lists the editions (index + name) inside a Windows Setup source.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Source
    )

    $resolved = Resolve-WindowsSource -Source $Source
    try {
        Get-WindowsImage -ImagePath $resolved.ImageFile |
            Select-Object ImageIndex, ImageName, ImageDescription,
                @{ Name = 'SizeGB'; Expression = { [math]::Round($_.ImageSize / 1GB, 2) } }
    }
    finally {
        if ($resolved.MountedIso) {
            Dismount-DiskImage -ImagePath $resolved.MountedIso | Out-Null
        }
    }
}

#endregion

#region Compression

function Invoke-ImageCompression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,          # e.g. "X:"
        [Parameter(Mandatory=$true)]
        [ValidateSet('XPRESS4K', 'XPRESS8K', 'XPRESS16K', 'LZX')]
        [string]$Algorithm,
        [Parameter(Mandatory=$true)][string[]]$Folders,
        [switch]$SkipNtfsCompression,
        [switch]$SkipExecutables                             # XPRESS4K is already applied by DISM /Compact
    )

    foreach ($relative in $Folders) {
        $folder = Join-Path "$Root\" $relative
        if (-not (Test-Path -LiteralPath $folder)) {
            Write-Verbose "Skipping missing folder $folder"
            continue
        }
        Write-Verbose "Compressing files in $folder"
        if (-not $SkipExecutables) {
            $null = Invoke-Native -FilePath 'compact.exe' `
                -Arguments @('/C', "/S:$folder", '/I', '/F', "/EXE:$Algorithm", '/Q') -IgnoreExitCode
        }
        if (-not $SkipNtfsCompression) {
            $null = Invoke-Native -FilePath 'compact.exe' `
                -Arguments @('/C', "/S:$folder", '/I', '/Q') -IgnoreExitCode
        }
    }
}

#endregion

#region Offline registry

function Initialize-OfflineRegistryApi {
    # Protected keys (e.g. Services\WinDefend, FolderDescriptions) are only writable with
    # backup/restore semantics. This enables SeRestore/SeBackup/SeTakeOwnership and compiles a
    # tiny helper that opens keys with REG_OPTION_BACKUP_RESTORE.
    if (-not ('PsnbRegistry' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

public static class PsnbRegistry
{
    const int REG_OPTION_BACKUP_RESTORE = 4;
    const int KEY_ALL_ACCESS = 0xF003F;
    const int SE_PRIVILEGE_ENABLED = 2;

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TOKEN_PRIVILEGES { public int PrivilegeCount; public long Luid; public int Attributes; }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegCreateKeyEx(IntPtr hKey, string lpSubKey, int Reserved, string lpClass, int dwOptions,
        int samDesired, IntPtr lpSecurityAttributes, out IntPtr phkResult, out int lpdwDisposition);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegSetValueEx(IntPtr hKey, string lpValueName, int Reserved, int dwType, byte[] lpData, int cbData);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegDeleteValue(IntPtr hKey, string lpValueName);
    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(IntPtr hKey);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, int DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    public static void EnablePrivileges()
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            foreach (string name in new string[] { "SeRestorePrivilege", "SeBackupPrivilege", "SeTakeOwnershipPrivilege" })
            {
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Attributes = SE_PRIVILEGE_ENABLED;
                if (!LookupPrivilegeValue(null, name, out tp.Luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                int err = Marshal.GetLastWin32Error();
                if (err != 0)
                    throw new Win32Exception(err, "Could not enable " + name + " (run as administrator)");
            }
        }
        finally { CloseHandle(token); }
    }

    static IntPtr OpenKey(string subKey)
    {
        IntPtr h; int disposition;
        int r = RegCreateKeyEx(Registry.LocalMachine.Handle.DangerousGetHandle(), subKey, 0, null,
            REG_OPTION_BACKUP_RESTORE, KEY_ALL_ACCESS, IntPtr.Zero, out h, out disposition);
        if (r != 0) throw new Win32Exception(r, "RegCreateKeyEx failed for HKLM\\" + subKey);
        return h;
    }

    static void SetRaw(string subKey, string name, int type, byte[] data)
    {
        IntPtr h = OpenKey(subKey);
        try
        {
            int r = RegSetValueEx(h, name, 0, type, data, data.Length);
            if (r != 0) throw new Win32Exception(r, "RegSetValueEx failed for HKLM\\" + subKey + " -> " + name);
        }
        finally { RegCloseKey(h); }
    }

    public static void SetDword(string subKey, string name, int value) { SetRaw(subKey, name, 4, BitConverter.GetBytes(value)); }
    public static void SetBinary(string subKey, string name, byte[] value) { SetRaw(subKey, name, 3, value); }
    public static void SetString(string subKey, string name, string value) { SetRaw(subKey, name, 1, Encoding.Unicode.GetBytes(value + "\0")); }
    public static void SetExpandString(string subKey, string name, string value) { SetRaw(subKey, name, 2, Encoding.Unicode.GetBytes(value + "\0")); }
    public static void SetMultiString(string subKey, string name, string[] values)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string v in values) { sb.Append(v); sb.Append('\0'); }
        sb.Append('\0');
        SetRaw(subKey, name, 7, Encoding.Unicode.GetBytes(sb.ToString()));
    }

    public static void DeleteValue(string subKey, string name)
    {
        IntPtr h = OpenKey(subKey);
        try
        {
            int r = RegDeleteValue(h, name);
            if (r != 0 && r != 2) throw new Win32Exception(r, "RegDeleteValue failed for HKLM\\" + subKey + " -> " + name);
        }
        finally { RegCloseKey(h); }
    }
}
'@
    }
    [PsnbRegistry]::EnablePrivileges()
}

function Mount-OfflineHives {
    param([Parameter(Mandatory=$true)][string]$Root)

    Initialize-OfflineRegistryApi

    $files = [ordered]@{
        SYSTEM   = (Join-Path "$Root\" 'Windows\System32\config\SYSTEM')
        SOFTWARE = (Join-Path "$Root\" 'Windows\System32\config\SOFTWARE')
        USER     = (Join-Path "$Root\" 'Users\Default\NTUSER.DAT')
    }
    $loaded = @()
    try {
        foreach ($hive in $files.Keys) {
            if (-not (Test-Path -LiteralPath $files[$hive] -PathType Leaf)) { throw "Hive file not found: $($files[$hive])" }
            $null = Invoke-Native -FilePath 'reg.exe' -Arguments @('load', "HKLM\$($script:HiveName[$hive])", $files[$hive])
            $loaded += $hive
        }
    }
    catch {
        foreach ($hive in $loaded) { Dismount-OfflineHive -Hive $hive }
        throw
    }
}

function Dismount-OfflineHive {
    param([ValidateSet('SYSTEM', 'SOFTWARE', 'USER')][string]$Hive)
    $name = $script:HiveName[$Hive]
    for ($i = 0; $i -lt 6; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $null = Invoke-Native -FilePath 'reg.exe' -Arguments @('unload', "HKLM\$name") -IgnoreExitCode
        if ($script:LastNativeExitCode -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    Write-Warning "Could not unload hive HKLM\$name. Reboot may be required before the VHD can be detached."
}

function Set-OfflineRegValue {
    # Writes a value into a loaded offline hive (creates keys as required, ignores ACLs).
    # Hive USER = Default profile, i.e. what HKCU becomes for every new user.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('SYSTEM', 'SOFTWARE', 'USER')][string]$Hive,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'MultiString', 'Binary')][string]$Kind = 'DWord'
    )

    $sub = "$($script:HiveName[$Hive])\$Path"
    switch ($Kind) {
        'DWord'        { [PsnbRegistry]::SetDword($sub, $Name, [int]$Value) }
        'String'       { [PsnbRegistry]::SetString($sub, $Name, [string]$Value) }
        'ExpandString' { [PsnbRegistry]::SetExpandString($sub, $Name, [string]$Value) }
        'MultiString'  { [PsnbRegistry]::SetMultiString($sub, $Name, [string[]]@($Value)) }
        'Binary'       { [PsnbRegistry]::SetBinary($sub, $Name, [byte[]]@($Value)) }
    }
    Write-Verbose "reg: HKLM\$sub -> $Name"
}

function Remove-OfflineRegValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('SYSTEM', 'SOFTWARE', 'USER')][string]$Hive,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    [PsnbRegistry]::DeleteValue("$($script:HiveName[$Hive])\$Path", $Name)
    Write-Verbose "reg: removed HKLM\$($script:HiveName[$Hive])\$Path -> $Name"
}

function Set-OfflineServiceStart {
    # Start: 2 = automatic, 3 = manual, 4 = disabled. Only touches services that exist.
    param([string]$Name, [int]$Start = 4)
    $key = "Registry::HKEY_LOCAL_MACHINE\$($script:HiveName.SYSTEM)\ControlSet001\Services\$Name"
    if (Test-Path -LiteralPath $key) {
        Set-OfflineRegValue -Hive SYSTEM -Path "ControlSet001\Services\$Name" -Name 'Start' -Value $Start
    }
    else {
        Write-Verbose "Service '$Name' not present in image, skipped"
    }
}

function Remove-OfflinePath {
    # Takes ownership, grants Administrators full control and deletes the path.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    if ($isDir) {
        # /D Y answers the confirmation prompt (English "Y"); /A gives ownership to Administrators
        $null = Invoke-Native -FilePath 'takeown.exe' -Arguments @('/F', $Path, '/A', '/R', '/D', 'Y') -IgnoreExitCode
        $null = Invoke-Native -FilePath 'icacls.exe'  -Arguments @($Path, '/grant', '*S-1-5-32-544:(OI)(CI)F', '/T', '/C', '/Q') -IgnoreExitCode
    }
    else {
        $null = Invoke-Native -FilePath 'takeown.exe' -Arguments @('/F', $Path, '/A') -IgnoreExitCode
        $null = Invoke-Native -FilePath 'icacls.exe'  -Arguments @($Path, '/grant', '*S-1-5-32-544:F', '/C', '/Q') -IgnoreExitCode
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
        Write-Warning "Could not fully remove $Path"
    }
}

function Invoke-OfflineTweaks {
    [CmdletBinding()]
    param(
        [string]$Root,
        [string[]]$Tweaks
    )

    # RemoveDefender implies DisableDefender (services/policies are disabled, files deleted)
    if ($Tweaks -contains 'RemoveDefender' -and $Tweaks -notcontains 'DisableDefender') {
        $Tweaks = @($Tweaks) + 'DisableDefender'
    }

    foreach ($tweak in $Tweaks) {
        Write-Verbose "Applying tweak: $tweak"
        switch ($tweak) {
            'DisableDefender' {
                foreach ($svc in 'WinDefend', 'WdFilter', 'WdBoot', 'WdNisDrv', 'WdNisSvc', 'Sense') {
                    Set-OfflineServiceStart -Name $svc -Start 4
                }
                $pol = 'Policies\Microsoft\Windows Defender'
                Set-OfflineRegValue -Hive SOFTWARE -Path $pol -Name 'DisableAntiSpyware' -Value 1
                Set-OfflineRegValue -Hive SOFTWARE -Path $pol -Name 'DisableAntiVirus'   -Value 1
                $rtp = "$pol\Real-Time Protection"
                foreach ($n in 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableIOAVProtection', 'DisableScanOnRealtimeEnable') {
                    Set-OfflineRegValue -Hive SOFTWARE -Path $rtp -Name $n -Value 1
                }
                Set-OfflineRegValue -Hive SOFTWARE -Path "$pol\Spynet" -Name 'SpynetReporting'      -Value 0
                Set-OfflineRegValue -Hive SOFTWARE -Path "$pol\Spynet" -Name 'SubmitSamplesConsent' -Value 2
            }
            'RemoveDefender' {
                $paths = @(
                    'Program Files\Windows Defender'
                    'Program Files\Windows Defender Advanced Threat Protection'
                    'Program Files (x86)\Windows Defender'
                    'ProgramData\Microsoft\Windows Defender'
                    'ProgramData\Microsoft\Windows Defender Advanced Threat Protection'
                    'Windows\System32\drivers\WdFilter.sys'
                    'Windows\System32\drivers\WdBoot.sys'
                    'Windows\System32\drivers\WdNisDrv.sys'
                )
                foreach ($p in $paths) { Remove-OfflinePath -Path (Join-Path "$Root\" $p) }
            }
            'DisableUAC' {
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 0
            }
            'DisableHibernation' {
                Set-OfflineRegValue -Hive SYSTEM -Path 'ControlSet001\Control\Power' -Name 'HibernateEnabled'        -Value 0
                Set-OfflineRegValue -Hive SYSTEM -Path 'ControlSet001\Control\Power' -Name 'HibernateEnabledDefault' -Value 0
                Set-OfflineRegValue -Hive SYSTEM -Path 'ControlSet001\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0
            }
            'DisablePagefile' {
                $mm = 'ControlSet001\Control\Session Manager\Memory Management'
                Set-OfflineRegValue -Hive SYSTEM -Path $mm -Name 'PagingFiles'         -Value @() -Kind MultiString
                Set-OfflineRegValue -Hive SYSTEM -Path $mm -Name 'ExistingPageFiles'   -Value @() -Kind MultiString
            }
            'DisableReservedStorage' {
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves' -Value 0
            }
            'DisableTelemetry' {
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0
                Set-OfflineServiceStart -Name 'DiagTrack' -Start 4
                Set-OfflineServiceStart -Name 'dmwappushservice' -Start 4
            }
            'DisableSmartScreen' {
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Policies\Microsoft\Windows\System' -Name 'EnableSmartScreen' -Value 0
            }
            'DisableWindowsUpdate' {
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' -Value 1
            }
            'Win11Bypass' {
                # Only relevant for later in-place upgrades / Setup started from the installed OS.
                $lab = 'Setup\LabConfig'
                foreach ($n in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck') {
                    Set-OfflineRegValue -Hive SYSTEM -Path $lab -Name $n -Value 1
                }
            }
            'BypassNRO' {
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Microsoft\Windows\CurrentVersion\OOBE' -Name 'BypassNRO' -Value 1
            }
            'DisableSystemRestore' {
                $sr = 'Policies\Microsoft\Windows NT\SystemRestore'
                Set-OfflineRegValue -Hive SOFTWARE -Path $sr -Name 'DisableSR'     -Value 1
                Set-OfflineRegValue -Hive SOFTWARE -Path $sr -Name 'DisableConfig' -Value 1
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -Value 0
            }
            'DisableSearchService' {
                Set-OfflineServiceStart -Name 'WSearch' -Start 4
            }
            'RemoveOneDrive' {
                foreach ($p in 'Windows\System32\OneDriveSetup.exe', 'Windows\SysWOW64\OneDriveSetup.exe') {
                    Remove-OfflinePath -Path (Join-Path "$Root\" $p)
                }
                # Default-profile Run entry that installs OneDrive at first logon
                Remove-OfflineRegValue -Hive USER -Path 'Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup'
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1
            }
            'NoShortcutSuffix' {
                # Removes the "- Shortcut" suffix from newly created shortcuts
                Set-OfflineRegValue -Hive USER -Path 'Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'link' -Value ([byte[]](0, 0, 0, 0)) -Kind Binary
            }
            'ShowFileExtensions' {
                Set-OfflineRegValue -Hive USER -Path 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Value 0
            }
            'ExplorerOpenThisPC' {
                Set-OfflineRegValue -Hive USER -Path 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Value 1
            }
            'DragDropCopy' {
                # 1 = copy, 2 = move, 4 = link
                Set-OfflineRegValue -Hive SOFTWARE -Path 'Classes\AllFilesystemObjects' -Name 'DefaultDropEffect' -Value 1
            }
            'ThisPCOnlyDesktopDocsDownloads' {
                # Hide Pictures, Videos, Music and 3D Objects in This PC (Desktop, Documents, Downloads stay)
                $hide = @(
                    '{0ddd015d-b06c-45d5-8c4c-f59713854639}'   # Pictures
                    '{35286a68-3c57-41a1-bbb1-0eae73d76c95}'   # Videos
                    '{a0c69a99-21c8-4671-8703-7934162fcf1d}'   # Music
                    '{31C0DD25-9439-4F12-BF41-7FF4EDA38722}'   # 3D Objects
                )
                foreach ($guid in $hide) {
                    foreach ($base in 'Microsoft', 'WOW6432Node\Microsoft') {
                        Set-OfflineRegValue -Hive SOFTWARE -Kind String -Value 'Hide' -Name 'ThisPCPolicy' `
                            -Path "$base\Windows\CurrentVersion\Explorer\FolderDescriptions\$guid\PropertyBag"
                    }
                }
            }
            default {
                Write-Warning "Unknown tweak '$tweak' ignored."
            }
        }
    }
}

function Import-OfflineRegFile {
    # Imports a .reg file into the offline hives. HKLM\SOFTWARE and HKLM\SYSTEM keys are
    # redirected; anything else is rejected so the host registry can never be modified.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\[-?(HKEY_[A-Z_]+)\\?([^\\\]]*)') {
            $root = $Matches[1].ToUpper()
            $sub  = $Matches[2].ToUpper()
            if ($root -ne 'HKEY_LOCAL_MACHINE' -or $sub -notin 'SOFTWARE', 'SYSTEM') {
                throw "'$Path' touches '$($Matches[0].Trim())'. Only HKEY_LOCAL_MACHINE\SOFTWARE and \SYSTEM are supported for offline import."
            }
        }
    }

    $text = $text -ireplace 'HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet', "HKEY_LOCAL_MACHINE\$($script:HiveName.SYSTEM)\ControlSet001"
    $text = $text -ireplace 'HKEY_LOCAL_MACHINE\\SYSTEM',   "HKEY_LOCAL_MACHINE\$($script:HiveName.SYSTEM)"
    $text = $text -ireplace 'HKEY_LOCAL_MACHINE\\SOFTWARE', "HKEY_LOCAL_MACHINE\$($script:HiveName.SOFTWARE)"

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "psnb-$([guid]::NewGuid().ToString('N')).reg"
    try {
        Set-Content -LiteralPath $tmp -Value $text -Encoding Unicode
        $null = Invoke-Native -FilePath 'reg.exe' -Arguments @('import', $tmp)
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Add-OfflineRunOnce {
    param([string[]]$Command)
    $i = 0
    foreach ($c in $Command) {
        Set-OfflineRegValue -Hive SOFTWARE -Path 'Microsoft\Windows\CurrentVersion\RunOnce' `
            -Name ("PSNB{0:D2}" -f $i) -Value $c -Kind String
        $i++
    }
}

#endregion

#region Unattend

function New-UnattendXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Architecture,   # x86, amd64, arm64
        [string]$ComputerName,
        [pscredential]$Account,
        [string]$Locale,                                      # e.g. en-US
        [string]$TimeZone,                                    # e.g. 'W. Europe Standard Time'
        [string]$ProductKey,
        [switch]$AutoLogon,
        [switch]$SkipOOBE
    )

    $ns = 'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    $component = {
        param($Name, $Inner)
        "<component name=`"$Name`" processorArchitecture=`"$Architecture`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`" $ns>$Inner</component>"
    }

    # specialize pass
    $spec = ''
    if ($ComputerName) { $spec += "<ComputerName>$(ConvertTo-XmlText $ComputerName)</ComputerName>" }
    if ($TimeZone)     { $spec += "<TimeZone>$(ConvertTo-XmlText $TimeZone)</TimeZone>" }
    if ($ProductKey)   { $spec += "<ProductKey>$(ConvertTo-XmlText $ProductKey)</ProductKey>" }

    # oobeSystem pass
    $intl = ''
    if ($Locale) {
        $l = ConvertTo-XmlText $Locale
        $intl = "<InputLocale>$l</InputLocale><SystemLocale>$l</SystemLocale><UILanguage>$l</UILanguage><UserLocale>$l</UserLocale>"
    }

    $shell = ''
    if ($SkipOOBE -or $Account) {
        $shell += '<OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens>' +
                  '<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>'
    }
    if ($Account) {
        $user = ConvertTo-XmlText $Account.UserName
        $pass = ConvertTo-XmlText $Account.GetNetworkCredential().Password
        $shell += "<UserAccounts><LocalAccounts><LocalAccount wcm:action=`"add`"><Name>$user</Name><DisplayName>$user</DisplayName>" +
                  "<Group>Administrators</Group><Password><Value>$pass</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>"
        if ($AutoLogon) {
            $shell += "<AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>$user</Username>" +
                      "<Password><Value>$pass</Value><PlainText>true</PlainText></Password></AutoLogon>"
        }
    }

    $passes = ''
    if ($spec) {
        $passes += '<settings pass="specialize">' + (& $component 'Microsoft-Windows-Shell-Setup' $spec) + '</settings>'
    }
    if ($intl -or $shell) {
        $passes += '<settings pass="oobeSystem">'
        if ($intl)  { $passes += & $component 'Microsoft-Windows-International-Core' $intl }
        if ($shell) { $passes += & $component 'Microsoft-Windows-Shell-Setup' $shell }
        $passes += '</settings>'
    }

    $xmlText = '<?xml version="1.0" encoding="utf-8"?>' +
               '<unattend xmlns="urn:schemas-microsoft-com:unattend">' + $passes + '</unattend>'

    # Validate well-formedness and pretty-print
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xmlText)
    $writer = New-Object System.IO.StringWriter
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $xw = [System.Xml.XmlWriter]::Create($writer, $settings)
    $doc.Save($xw)
    $xw.Close()
    return $writer.ToString()
}

#endregion

#region Files and shortcuts

function Copy-InjectedItem {
    # Copies a file or folder into <Root>\<TargetFolder> of the offline image.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$TargetFolder = 'Tools'
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $targetRoot = Join-Path "$Root\" $TargetFolder
    $null = New-Item -ItemType Directory -Path $targetRoot -Force
    Write-Verbose "Injecting $($item.FullName) -> $targetRoot"
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $targetRoot $item.Name) -Recurse -Force
}

function Copy-ToolsFolder {
    # Copies the whole content of the Tools folder (exe files and subfolders, any layout)
    # into <Root>\<TargetFolder>, e.g. X:\Tools -> C:\Tools after boot.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Source,
        [string]$TargetFolder = 'Tools'
    )
    $target = Join-Path "$Root\" $TargetFolder
    $null = New-Item -ItemType Directory -Path $target -Force
    $exeCount = @(Get-ChildItem -LiteralPath $Source -Filter *.exe -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Verbose "Copying Tools folder '$Source' -> $target ($exeCount executable(s) found)"
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
    }
}

function New-OfflineShortcut {
    # Creates a .lnk on the all-users desktop (C:\Users\Public\Desktop) of the offline image.
    # Target/Icon/WorkingDirectory must use the paths as seen from the booted OS (C:\...).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][hashtable]$Shortcut    # Name, Target, [Arguments], [Icon], [WorkingDirectory]
    )
    if (-not $Shortcut.Name -or -not $Shortcut.Target) {
        throw "Each -DesktopShortcut needs at least Name and Target (got: $($Shortcut.Keys -join ', '))."
    }
    $dir = Join-Path "$Root\" 'Users\Public\Desktop'
    $null = New-Item -ItemType Directory -Path $dir -Force

    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut((Join-Path $dir "$($Shortcut.Name).lnk"))
        $link.TargetPath = $Shortcut.Target
        if ($Shortcut.Arguments)        { $link.Arguments        = $Shortcut.Arguments }
        if ($Shortcut.Icon)             { $link.IconLocation     = $Shortcut.Icon }
        if ($Shortcut.WorkingDirectory) { $link.WorkingDirectory = $Shortcut.WorkingDirectory }
        $link.Save()
        Write-Verbose "Shortcut created: $($Shortcut.Name)"
    }
    finally {
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

#endregion

#region Boot

function Get-BcdLoaderBlock {
    # Returns objects with Id and Text for every osloader entry in the system BCD store.
    $text = (Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/enum', 'osloader', '/v') -IgnoreExitCode | ForEach-Object { "$_" }) -join "`n"
    foreach ($block in [regex]::Split($text, '\r?\n\s*\r?\n')) {
        if ($block -match '(?m)^\s*identifier\s+(\{[0-9a-fA-F-]+\})') {
            [pscustomobject]@{ Id = $Matches[1]; Text = $block }
        }
    }
}

function Add-NativeBootEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,        # "X:"
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [ValidateSet('Auto', 'UEFI', 'BIOS', 'ALL')][string]$Mode = 'Auto',
        [string]$Description,
        [string]$BootDrive,                               # e.g. "S:" (target system partition)
        [string]$Locale
    )

    $before = @(Get-BcdLoaderBlock | ForEach-Object { $_.Id })

    $bcdArgs = @("$Root\Windows")
    if ($BootDrive) { $bcdArgs += '/s', $BootDrive }
    if ($Mode -ne 'Auto') { $bcdArgs += '/f', $Mode }
    if ($Locale)    { $bcdArgs += '/l', $Locale }
    $null = Invoke-Native -FilePath 'bcdboot.exe' -Arguments $bcdArgs

    $entryId = $null
    if ($Description -and -not $BootDrive) {
        # Find the loader that points at our VHD(X); prefer entries that did not exist before
        $fileName = [regex]::Escape([IO.Path]::GetFileName($ImagePath))
        $matching = @(Get-BcdLoaderBlock | Where-Object { $_.Text -match "(?im)^\s*(os)?device\s+.*vhd=.*$fileName" })
        $new = @($matching | Where-Object { $before -notcontains $_.Id })
        $pick = if ($new.Count -gt 0) { $new[-1] } elseif ($matching.Count -gt 0) { $matching[-1] } else { $null }
        if ($pick) {
            $entryId = $pick.Id
            $null = Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', $entryId, 'description', $Description)
        }
        else {
            Write-Warning 'Boot entry was created, but could not be located to set its description.'
        }
    }
    elseif ($Description -and $BootDrive) {
        Write-Warning 'Boot description is only set for the default BCD store (no -BootDrive).'
    }
    return $entryId
}

#endregion

#region Main

function New-WindowsNativeBoot {
    <#
    .SYNOPSIS
        Creates a Native Boot .vhd(x) installation from a Windows Setup image.

    .EXAMPLE
        New-WindowsNativeBoot -Source D:\win11.iso -ImagePath D:\VM\win11.vhdx -Size 40GB -Verbose

    .EXAMPLE
        New-WindowsNativeBoot D:\win11.iso D:\VM\win11.vhdx 40GB -Edition 'Pro' -Compression LZX `
            -Tweaks DisableDefender,DisableHibernation,BypassNRO -BootMode UEFI -BootDescription 'Win11 LZX'
    #>
    [CmdletBinding()]
    param(
        # Windows Setup .iso, .wim, .esd, .swm, or a folder/drive containing \sources
        [Parameter(Position=0, ValueFromPipelineByPropertyName=$true)]
        [string]$Source,

        # Destination of the .vhd(x)
        [Parameter(Position=1, ValueFromPipelineByPropertyName=$true)]
        [string]$ImagePath,

        # Disk image size, e.g. 40GB
        [Parameter(Position=2)]
        [Alias('ImageSize')]
        [ValidateRange(1GB, 2040GB)]
        [long]$Size,

        # Windows Setup image index, or select by name with -Edition
        [ValidateRange(1, 999)]
        [int]$Index = 1,

        # Edition name (exact or partial), e.g. 'Pro'. Overrides -Index.
        [string]$Edition,

        [ValidateSet('Expandable', 'Fixed')]
        [string]$DiskType = 'Expandable',

        [ValidateSet('GPT', 'MBR')]
        [string]$PartitionStyle = 'GPT',

        [string]$VolumeLabel = 'Windows',

        # Compact OS algorithm applied to Windows. 'None' = uncompressed.
        [ValidateSet('None', 'XPRESS4K', 'XPRESS8K', 'XPRESS16K', 'LZX')]
        [string]$Compression = 'XPRESS16K',

        # Folders (relative to the image root) that get extra compression
        [string[]]$CompressFolders = $script:DefaultCompressFolders,

        # Skip the NTFS (LZNT1) compression pass over data files
        [switch]$SkipNtfsCompression,

        # bcdboot firmware type. Auto = decided by bcdboot from the running system.
        [ValidateSet('Auto', 'UEFI', 'BIOS', 'ALL')]
        [string]$BootMode = 'Auto',

        # Name shown in the boot menu
        [string]$BootDescription,

        # Target system partition for bcdboot /s, e.g. 'S:'. Default: host's system partition.
        [string]$BootDrive,

        # bcdboot /l locale, e.g. 'en-US'
        [string]$BootLocale,

        # Do not touch the boot record at all
        [switch]$NoBootEntry,

        # Keep the .vhd(x) if the build fails (default: an incomplete image is deleted)
        [switch]$KeepFailedImage,

        # Offline registry tweaks
        [ValidateSet('DisableDefender', 'RemoveDefender', 'DisableUAC', 'DisableHibernation',
                     'DisablePagefile', 'DisableReservedStorage', 'DisableTelemetry',
                     'DisableSmartScreen', 'DisableWindowsUpdate', 'Win11Bypass', 'BypassNRO',
                     'DisableSystemRestore', 'DisableSearchService', 'RemoveOneDrive',
                     'NoShortcutSuffix', 'ShowFileExtensions', 'ExplorerOpenThisPC',
                     'DragDropCopy', 'ThisPCOnlyDesktopDocsDownloads')]
        [string[]]$Tweaks,

        # .reg files imported into the offline HKLM\SOFTWARE / HKLM\SYSTEM hives
        [string[]]$RegFile,

        # Commands run once at first user logon (HKLM RunOnce)
        [string[]]$RunOnce,

        # Tools folder: its whole content (exe files and/or subfolders) is copied to <InjectFolder>.
        # Default: .\Tools next to this script. Missing or empty folder = nothing injected.
        [string]$ToolsFolder = (Join-Path $script:ScriptRoot 'Tools'),
        [switch]$SkipTools,

        # Drivers folder: injected offline if it contains .inf files (empty folder is fine).
        # Default: .\Drivers next to this script.
        [string]$DriversFolder = (Join-Path $script:ScriptRoot 'Drivers'),
        [switch]$SkipDrivers,

        # Additional single files/folders copied into <InjectFolder>
        [string[]]$InjectPath,

        # Folder inside the image that receives -InjectPath items (default C:\Tools)
        [string]$InjectFolder = 'Tools',

        # All-users desktop shortcuts: @{ Name=''; Target=''; Arguments=''; Icon=''; WorkingDirectory='' }
        # Paths are as seen from the booted OS (C:\...)
        [hashtable[]]$DesktopShortcut,

        # Driver folders or .inf files added offline
        [string[]]$DriverPath,

        # .msu / .cab files or folders of updates added offline
        [string[]]$UpdatePath,

        # Enable .NET Framework 3.5 offline (uses sources\sxs of the media)
        [switch]$EnableNetFx3,
        [string]$NetFx3Source,

        # Provisioned Appx packages to remove (wildcards allowed, e.g. 'Microsoft.Xbox*')
        [string[]]$RemoveAppx,

        # Your own unattend.xml (copied to Windows\Panther\unattend.xml)
        [string]$UnattendPath,

        # Generated unattend.xml values (cannot be combined with -UnattendPath)
        [string]$ComputerName,
        [pscredential]$LocalAccount,
        [string]$Locale,
        [string]$TimeZone,
        [string]$ProductKey,
        [switch]$AutoLogon,
        [switch]$SkipOOBE,

        # Load parameters from a JSON profile (explicit parameters win)
        [string]$LoadProfile,

        # Save the parameters used to a JSON profile (credentials are never saved)
        [string]$SaveProfile
    )

    $ErrorActionPreference = 'Stop'
    Write-Verbose "PSWindowsNativeBoot v$($script:Version)"

    # --- profile handling -------------------------------------------------
    if ($LoadProfile) {
        $profile = Get-Content -LiteralPath $LoadProfile -Raw | ConvertFrom-Json
        foreach ($p in $profile.PSObject.Properties) {
            if (-not $PSBoundParameters.ContainsKey($p.Name)) {
                Set-Variable -Name $p.Name -Value $p.Value
                $PSBoundParameters[$p.Name] = $p.Value
            }
        }
    }
    if ($SaveProfile) {
        $skip = 'LocalAccount', 'LoadProfile', 'SaveProfile', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction',
                'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
        $out = [ordered]@{}
        foreach ($key in $PSBoundParameters.Keys) {
            if ($key -in $skip) { continue }
            $v = $PSBoundParameters[$key]
            if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
            $out[$key] = $v
        }
        $out | ConvertTo-Json | Set-Content -LiteralPath $SaveProfile -Encoding UTF8
    }

    # --- validation --------------------------------------------------------
    foreach ($required in 'Source', 'ImagePath') {
        if (-not (Get-Variable -Name $required -ValueOnly)) { throw "Parameter -$required is required." }
    }
    if ($Size -le 0) { throw 'Parameter -Size is required (e.g. -Size 40GB).' }
    if ($Size -lt 20GB) { Write-Warning 'Less than 20GB is usually too small for a Windows installation.' }
    if ($UnattendPath -and ($ComputerName -or $LocalAccount -or $Locale -or $TimeZone -or $ProductKey -or $AutoLogon -or $SkipOOBE)) {
        throw '-UnattendPath cannot be combined with the generated-unattend parameters.'
    }
    if ($UnattendPath -and -not (Test-Path -LiteralPath $UnattendPath)) { throw "UnattendPath '$UnattendPath' not found." }
    foreach ($f in $RegFile) { if (-not (Test-Path -LiteralPath $f)) { throw "Reg file '$f' not found." } }
    foreach ($f in $InjectPath) { if (-not (Test-Path -LiteralPath $f)) { throw "Inject path '$f' not found." } }
    foreach ($d in $DriverPath) { if (-not (Test-Path -LiteralPath $d)) { throw "Driver path '$d' not found." } }
    foreach ($u in $UpdatePath) { if (-not (Test-Path -LiteralPath $u)) { throw "Update path '$u' not found." } }
    if (Test-Path -LiteralPath $ImagePath) { throw "'$ImagePath' already exists." }

    # Drivers folder next to the script (skipped when missing or without .inf files)
    $driverList = @()
    if ($DriverPath) { $driverList += $DriverPath }
    if (-not $SkipDrivers) {
        if (-not (Test-Path -LiteralPath $DriversFolder -PathType Container)) {
            Write-Verbose "Drivers folder '$DriversFolder' not found, no drivers injected."
        }
        elseif (Get-ChildItem -LiteralPath $DriversFolder -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
            $driverList += $DriversFolder
        }
        else {
            Write-Verbose "Drivers folder '$DriversFolder' contains no .inf files, no drivers injected."
        }
    }

    # Tools folder next to the script (skipped when missing or empty)
    $toolsAvailable = $false
    if (-not $SkipTools) {
        if (-not (Test-Path -LiteralPath $ToolsFolder -PathType Container)) {
            Write-Verbose "Tools folder '$ToolsFolder' not found, no tools injected."
        }
        elseif (Get-ChildItem -LiteralPath $ToolsFolder -Force | Select-Object -First 1) {
            $toolsAvailable = $true
        }
        else {
            Write-Verbose "Tools folder '$ToolsFolder' is empty, no tools injected."
        }
    }

    $generateUnattend = [bool]($ComputerName -or $LocalAccount -or $Locale -or $TimeZone -or $ProductKey -or $AutoLogon -or $SkipOOBE)
    $needServicing    = [bool]($driverList -or $UpdatePath -or $EnableNetFx3 -or $RemoveAppx)
    $needOffline      = [bool]($Tweaks -or $RegFile -or $RunOnce -or $InjectPath -or $toolsAvailable -or $DesktopShortcut -or $UnattendPath -or $generateUnattend)
    $needCompression  = $Compression -ne 'None'
    $needBoot         = -not $NoBootEntry

    $total = 4 + [int]$needServicing + [int]$needOffline + [int]$needCompression + [int]$needBoot
    $progress = @{ N = 0 }
    $stepLog = { param($Text) $progress.N++; Write-Verbose "($($progress.N)/$total) $Text" }

    $src = $null
    $vhdMounted = $false
    $hives = @{ SYSTEM = $false; SOFTWARE = $false; USER = $false }
    $bootEntryId = $null
    $createdImage = $false
    $bootRan = $false
    $buildOk = $false

    try {
        # --- source -----------------------------------------------------------
        $src = Resolve-WindowsSource -Source $Source

        $editions = $null
        try { $editions = @(Get-WindowsImage -ImagePath $src.ImageFile) }
        catch { Write-Warning "Could not read image information: $($_.Exception.Message)" }

        if ($Edition) {
            if (-not $editions) { throw 'Cannot resolve -Edition because image information is unavailable. Use -Index.' }
            $found = @($editions | Where-Object { $_.ImageName -eq $Edition })
            if ($found.Count -eq 0) { $found = @($editions | Where-Object { $_.ImageName -like "*$Edition*" }) }
            if ($found.Count -ne 1) {
                $names = ($editions | ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" }) -join '; '
                throw "-Edition '$Edition' matched $($found.Count) editions. Available: $names"
            }
            $Index = $found[0].ImageIndex
        }
        elseif ($editions -and ($editions.ImageIndex -notcontains $Index)) {
            $names = ($editions | ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" }) -join '; '
            throw "Index $Index does not exist in the image. Available: $names"
        }
        Write-Verbose "Using image index $Index"

        # --- 1. create disk image ---------------------------------------------
        & $stepLog 'Creating disk image'
        $createdImage = $true
        New-VirtualDiskImage -ImagePath $ImagePath -Size $Size -DiskType $DiskType `
            -PartitionStyle $PartitionStyle -VolumeLabel $VolumeLabel

        # --- 2. mount ----------------------------------------------------------
        & $stepLog 'Mounting disk image'
        $vhdMounted = $true
        $drive = Mount-VirtualDiskImage -ImagePath $ImagePath

        # --- 3. apply ----------------------------------------------------------
        & $stepLog 'Applying Windows to disk image'
        $dismArgs = @('/Apply-Image', "/ImageFile:$($src.ImageFile)", "/Index:$Index", "/ApplyDir:$drive")
        if ($src.SwmPattern) { $dismArgs += "/SWMFile:$($src.SwmPattern)" }
        if ($needCompression) { $dismArgs += '/Compact' }
        $null = Invoke-Native -FilePath 'dism.exe' -Arguments $dismArgs

        # --- 4. offline servicing ----------------------------------------------
        if ($needServicing) {
            & $stepLog 'Servicing offline image (drivers, updates, features, Appx)'
            $imageArg = "/Image:$drive\"

            foreach ($d in $driverList) {
                $item = Get-Item -LiteralPath $d
                $driverArgs = @($imageArg, '/Add-Driver', "/Driver:$($item.FullName)")
                if ($item.PSIsContainer) { $driverArgs += '/Recurse' }
                $null = Invoke-Native -FilePath 'dism.exe' -Arguments $driverArgs
            }
            foreach ($u in $UpdatePath) {
                $null = Invoke-Native -FilePath 'dism.exe' -Arguments @($imageArg, '/Add-Package', "/PackagePath:$((Get-Item -LiteralPath $u).FullName)")
            }
            if ($EnableNetFx3) {
                $sxs = if ($NetFx3Source) { $NetFx3Source } else { $src.SxsPath }
                if (-not $sxs -or -not (Test-Path -LiteralPath $sxs)) {
                    throw 'No sources\sxs folder available for .NET 3.5. Specify -NetFx3Source.'
                }
                $null = Invoke-Native -FilePath 'dism.exe' -Arguments @($imageArg, '/Enable-Feature', '/FeatureName:NetFx3', '/All', '/LimitAccess', "/Source:$sxs")
            }
            if ($RemoveAppx) {
                $provisioned = @(Get-AppxProvisionedPackage -Path "$drive\")
                foreach ($pattern in $RemoveAppx) {
                    $hits = @($provisioned | Where-Object { $_.DisplayName -like $pattern })
                    if ($hits.Count -eq 0) { Write-Warning "No provisioned Appx package matches '$pattern'." }
                    foreach ($pkg in $hits) {
                        Write-Verbose "Removing Appx $($pkg.DisplayName)"
                        try { $null = Remove-AppxProvisionedPackage -Path "$drive\" -PackageName $pkg.PackageName }
                        catch { Write-Warning "Could not remove $($pkg.DisplayName): $($_.Exception.Message)" }
                    }
                }
            }
        }

        # --- 5. offline configuration ------------------------------------------
        if ($needOffline) {
            & $stepLog 'Configuring offline image (registry, files, shortcuts, unattend)'

            if ($Tweaks -or $RegFile -or $RunOnce) {
                Mount-OfflineHives -Root $drive
                $hives.SYSTEM = $true; $hives.SOFTWARE = $true; $hives.USER = $true

                if ($Tweaks)  { Invoke-OfflineTweaks -Root $drive -Tweaks $Tweaks }
                foreach ($f in $RegFile) { Import-OfflineRegFile -Path $f }
                if ($RunOnce) { Add-OfflineRunOnce -Command $RunOnce }

                Dismount-OfflineHive -Hive USER;     $hives.USER     = $false
                Dismount-OfflineHive -Hive SOFTWARE; $hives.SOFTWARE = $false
                Dismount-OfflineHive -Hive SYSTEM;   $hives.SYSTEM   = $false
            }

            if ($toolsAvailable) { Copy-ToolsFolder -Root $drive -Source $ToolsFolder -TargetFolder $InjectFolder }
            foreach ($file in $InjectPath)      { Copy-InjectedItem -Root $drive -Path $file -TargetFolder $InjectFolder }
            foreach ($lnk in $DesktopShortcut)  { New-OfflineShortcut -Root $drive -Shortcut $lnk }

            $panther = Join-Path "$drive\" 'Windows\Panther'
            if ($UnattendPath) {
                $null = New-Item -ItemType Directory -Path $panther -Force
                Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $panther 'unattend.xml') -Force
            }
            elseif ($generateUnattend) {
                $archMap = @{ 0 = 'x86'; 5 = 'arm'; 9 = 'amd64'; 12 = 'arm64' }
                $arch = 'amd64'
                try {
                    $detail = Get-WindowsImage -ImagePath $src.ImageFile -Index $Index
                    if ($archMap.ContainsKey([int]$detail.Architecture)) { $arch = $archMap[[int]$detail.Architecture] }
                }
                catch { Write-Warning "Could not detect image architecture, assuming amd64." }

                $xml = New-UnattendXml -Architecture $arch -ComputerName $ComputerName -Account $LocalAccount `
                    -Locale $Locale -TimeZone $TimeZone -ProductKey $ProductKey -AutoLogon:$AutoLogon -SkipOOBE:$SkipOOBE
                $null = New-Item -ItemType Directory -Path $panther -Force
                [IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'), $xml, (New-Object System.Text.UTF8Encoding $false))
            }
        }

        # --- 6. compression ----------------------------------------------------
        if ($needCompression) {
            & $stepLog "Compressing disk image ($Compression)"
            # DISM /Compact already applied XPRESS4K; only run the exe pass for stronger algorithms
            Invoke-ImageCompression -Root $drive -Algorithm $Compression -Folders $CompressFolders `
                -SkipNtfsCompression:$SkipNtfsCompression -SkipExecutables:($Compression -eq 'XPRESS4K')
        }

        # --- 7. boot record ----------------------------------------------------
        if ($needBoot) {
            & $stepLog 'Adding disk image to boot record'
            $bootRan = $true
            $desc = if ($BootDescription) { $BootDescription } else { "Windows ($([IO.Path]::GetFileNameWithoutExtension($ImagePath)))" }
            $bootEntryId = Add-NativeBootEntry -Root $drive -ImagePath $ImagePath -Mode $BootMode `
                -Description $desc -BootDrive $BootDrive -Locale $BootLocale
        }

        $buildOk = $true
    }
    finally {
        if ($hives.USER)     { Dismount-OfflineHive -Hive USER }
        if ($hives.SOFTWARE) { Dismount-OfflineHive -Hive SOFTWARE }
        if ($hives.SYSTEM)   { Dismount-OfflineHive -Hive SYSTEM }
        if ($vhdMounted) {
            & $stepLog 'Dismounting install media and disk image'
            Dismount-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Out-Null
        }
        if ($src -and $src.MountedIso) {
            Dismount-DiskImage -ImagePath $src.MountedIso -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not $buildOk -and $createdImage -and -not $KeepFailedImage -and (Test-Path -LiteralPath $ImagePath)) {
            if ($bootRan) {
                Write-Warning "Build failed after the boot entry was created, keeping '$ImagePath'."
            }
            else {
                Dismount-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -LiteralPath $ImagePath -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $ImagePath) { Write-Warning "Could not delete incomplete image '$ImagePath'." }
                else { Write-Warning "Build failed, incomplete image '$ImagePath' was deleted (use -KeepFailedImage to keep it)." }
            }
        }
    }

    [pscustomobject]@{
        Version      = $script:Version
        ImagePath    = $ImagePath
        Index        = $Index
        Compression  = $Compression
        Tweaks       = $Tweaks
        BootEntryId  = $bootEntryId
    }
}

#endregion
