# PSWindowsNativeBoot (extended)

Automated creation of Native Boot `.vhd(x)` installations from a Windows Setup image.
Does not rely on Hyper-V cmdlets. Requires an elevated PowerShell 5.1+.

## Features

- Sources: `.iso`, `install.wim`, `install.esd`, `install.swm`, or a folder/drive containing `\sources`
- Edition picker by name (`-Edition`) or index (`-Index`); `Get-WindowsSetupEdition` lists them
- `.vhd` or `.vhdx`, expandable or fixed, GPT or MBR
- Compression: `None`, `XPRESS4K`, `XPRESS8K`, `XPRESS16K` (default), `LZX`
- Boot record: UEFI / BIOS / ALL, boot menu description, target boot drive, locale, or none
- Offline tweaks (`-Tweaks`): `DisableDefender`, `RemoveDefender`, `DisableUAC`, `DisableHibernation`,
  `DisablePagefile`, `DisableReservedStorage`, `DisableTelemetry`, `DisableSmartScreen`,
  `DisableWindowsUpdate`, `DisableSystemRestore`, `DisableSearchService`, `RemoveOneDrive`,
  `Win11Bypass`, `BypassNRO`, and Explorer defaults for new users: `NoShortcutSuffix`,
  `ShowFileExtensions`, `ExplorerOpenThisPC`, `DragDropCopy`, `ThisPCOnlyDesktopDocsDownloads`
- Custom `.reg` import (HKLM\SOFTWARE and HKLM\SYSTEM only), RunOnce commands
- Inject portable tools into the image, create all-users desktop shortcuts
- Offline drivers, updates (`.msu` / `.cab`), .NET 3.5, provisioned Appx removal
- `unattend.xml`: supply your own or generate (account, computer name, locale, time zone, product key)
- Save / load settings profiles (JSON)

## Examples

```powershell
. .\PSWindowsNativeBoot.ps1

# List editions
Get-WindowsSetupEdition 'D:\Downloads\Win11.iso'

# Basic
New-WindowsNativeBoot -Source 'D:\Downloads\Win11.iso' -ImagePath 'D:\VM\Win11.vhdx' -Size 40GB -Verbose

# Customised
New-WindowsNativeBoot 'D:\Downloads\Win11.iso' 'D:\VM\Win11.vhdx' 40GB `
    -Edition 'Pro' -Compression LZX `
    -Tweaks DisableDefender,DisableHibernation,DisableReservedStorage,BypassNRO `
    -RemoveAppx 'Microsoft.Xbox*','Microsoft.BingNews' `
    -DriverPath 'D:\Drivers' `
    -BootMode UEFI -BootDescription 'Windows 11 (LZX)' -Verbose

# Save the settings for next time
New-WindowsNativeBoot ... -SaveProfile .\win11.json
New-WindowsNativeBoot -LoadProfile .\win11.json -ImagePath 'D:\VM\Win11-2.vhdx'
```

Wait until finished, then reboot and select the new boot entry.

## Parameters

| Parameter | Description |
|---|---|
| `Source` | Setup `.iso` / `.wim` / `.esd` / `.swm` / folder |
| `ImagePath` | Destination `.vhd(x)` |
| `Size` (alias `ImageSize`) | Maximum image size, e.g. `40GB` |
| `Index` / `Edition` | Image index, or edition name (exact or partial) |
| `DiskType` | `Expandable` (default) or `Fixed` |
| `PartitionStyle` | `GPT` (default) or `MBR` |
| `VolumeLabel` | NTFS label (default `Windows`) |
| `Compression` | `None`, `XPRESS4K`, `XPRESS8K`, `XPRESS16K`, `LZX` |
| `CompressFolders` | Folders (relative to image root) given extra compression |
| `SkipNtfsCompression` | Skip the LZNT1 pass over data files |
| `BootMode` | `Auto`, `UEFI`, `BIOS`, `ALL` (bcdboot `/f`) |
| `BootDescription` | Name in the boot menu |
| `BootDrive` | Target system partition (bcdboot `/s`), e.g. `S:` |
| `BootLocale` | bcdboot `/l` |
| `NoBootEntry` | Do not modify the boot record |
| `Tweaks` | See list above |
| `RegFile` | `.reg` files imported offline |
| `RunOnce` | Commands run once at first logon |
| `InjectPath`, `InjectFolder` | Files/folders copied into the image (default folder `C:\Tools`) |
| `DesktopShortcut` | All-users desktop shortcuts: `@{Name='';Target='';Arguments='';Icon=''}` (paths as seen from the booted OS, `C:\...`) |
| `DriverPath` | Driver folders / `.inf` files |
| `UpdatePath` | `.msu` / `.cab` files or folders |
| `EnableNetFx3`, `NetFx3Source` | Enable .NET 3.5 offline |
| `RemoveAppx` | Provisioned Appx names (wildcards) to remove |
| `UnattendPath` | Own `unattend.xml` |
| `ComputerName`, `LocalAccount`, `Locale`, `TimeZone`, `ProductKey`, `AutoLogon`, `SkipOOBE` | Generated `unattend.xml` |
| `LoadProfile` / `SaveProfile` | JSON settings profile (credentials are never saved) |
| `Verbose` | Print additional information about the current process |

## Notes

- Registry edits use backup/restore privileges, so protected keys can be written. `-RegFile` imports use plain `reg import` and may be denied on protected keys.
- Per-user tweaks (`NoShortcutSuffix`, `ShowFileExtensions`, `ExplorerOpenThisPC`) are written to the Default profile, so they apply to users created after the first boot, not to existing ones.
- `RemoveDefender` deletes the Defender files but not the WinSxS copies; servicing may restore them.
- `Win11Bypass` only matters for later in-place upgrades; the applied image never runs Setup's checks.
- `LocalAccount` is written to `unattend.xml` in plain text; Windows sanitises its cached copy after setup.
- Hibernation is not supported when booting from a VHD(X) regardless of the tweak.
