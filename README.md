# PSWindowsNativeBoot v5 (extended)

Automated creation of Native Boot `.vhd(x)` installations from a Windows Setup image.
Does not rely on Hyper-V cmdlets. Requires an elevated PowerShell 5.1+.

Based on [stefanhzr/PSWindowsNativeBoot](https://github.com/stefanhzr/PSWindowsNativeBoot) (MIT, 2017).

## Folder layout

```
PSWindowsNativeBoot\
    PSWindowsNativeBoot_v5.ps1
    README_v5.md
    Tools\      portable programs, copied to C:\Tools in the new installation
    Drivers\    drivers injected offline (may be empty)
```

- **Tools**: put `.exe` files directly in the folder, in subfolders, or both. The whole content
  is copied to `C:\Tools` with the same structure. Missing or empty folder = nothing is copied.
- **Drivers**: any layout of driver folders / `.inf` files. Injected only if at least one `.inf`
  exists, so an empty folder is fine.
- Use `-SkipTools` / `-SkipDrivers` to ignore the folders, or `-ToolsFolder` / `-DriversFolder` to
  point somewhere else.

## Usage

```powershell
Set-Location 'D:\Temp\PSWindowsNativeBoot'
. .\PSWindowsNativeBoot_v5.ps1

# List editions
Get-WindowsSetupEdition 'D:\Windows_10_22H2_US_last_official.iso'

New-WindowsNativeBoot `
    -Source          'D:\Windows_10_22H2_US_last_official.iso' `
    -ImagePath       'D:\Win10_large.vhdx' `
    -Size            135GB `
    -Edition         'Windows 10 Pro' `
    -Compression     XPRESS16K `
    -Tweaks          DisableDefender, DisableReservedStorage, RemoveOneDrive, DisableHibernation,
                     DisableSystemRestore, DisableSearchService, NoShortcutSuffix, ShowFileExtensions,
                     DragDropCopy, ThisPCOnlyDesktopDocsDownloads, ExplorerOpenThisPC `
    -DesktopShortcut @{ Name = 'Network Connections'; Target = 'C:\Windows\System32\ncpa.cpl' } `
    -BootDescription 'Windows 10 22H2 Large' `
    -Verbose
```

Wait until finished, then reboot and select the new boot entry.

## Parameters

| Parameter | Description |
|---|---|
| `Source` | Setup `.iso` / `.wim` / `.esd` / `.swm` / folder |
| `ImagePath` | Destination `.vhd(x)` (use a full path) |
| `Size` (alias `ImageSize`) | Maximum image size, e.g. `40GB` |
| `Index` / `Edition` | Image index, or edition name. Exact name first, then partial; a partial name matching several editions (e.g. `Pro` = Pro and Pro N) is an error, use the full name or `-Index` |
| `DiskType` | `Expandable` (default) or `Fixed` |
| `PartitionStyle` | `GPT` (default) or `MBR` |
| `VolumeLabel` | NTFS label (default `Windows`) |
| `Compression` | `None`, `XPRESS4K`, `XPRESS8K`, `XPRESS16K` (default), `LZX` |
| `CompressFolders` | Folders (relative to image root) given extra compression |
| `SkipNtfsCompression` | Skip the LZNT1 pass over data files |
| `BootMode` | `Auto`, `UEFI`, `BIOS`, `ALL` (bcdboot `/f`) |
| `BootDescription` | Name in the boot menu |
| `BootDrive` | Target system partition (bcdboot `/s`), e.g. `S:` |
| `BootLocale` | bcdboot `/l` |
| `NoBootEntry` | Do not modify the boot record |
| `KeepFailedImage` | Keep the `.vhd(x)` if the build fails (default: an incomplete image is deleted) |
| `Tweaks` | See tweak list below |
| `RegFile` | `.reg` files imported offline |
| `RunOnce` | Commands run once at first logon |
| `ToolsFolder`, `SkipTools` | Tools folder (default `.\Tools`), copied to `<InjectFolder>` |
| `DriversFolder`, `SkipDrivers` | Drivers folder (default `.\Drivers`), injected if it has `.inf` files |
| `InjectPath`, `InjectFolder` | Extra files/folders copied into the image (default folder `C:\Tools`) |
| `DesktopShortcut` | All-users desktop shortcuts: `@{Name='';Target='';Arguments='';Icon=''}` (paths as seen from the booted OS, `C:\...`) |
| `DriverPath` | Additional driver folders / `.inf` files |
| `UpdatePath` | `.msu` / `.cab` files or folders |
| `EnableNetFx3`, `NetFx3Source` | Enable .NET 3.5 offline |
| `RemoveAppx` | Provisioned Appx names (wildcards) to remove |
| `UnattendPath` | Own `unattend.xml` |
| `ComputerName`, `LocalAccount`, `Locale`, `TimeZone`, `ProductKey`, `AutoLogon`, `SkipOOBE` | Generated `unattend.xml` |
| `LoadProfile` / `SaveProfile` | JSON settings profile (credentials are never saved) |
| `Verbose` | Print additional information about the current process |

## Tweaks (`-Tweaks`)

| Tweak | Effect |
|---|---|
| `DisableDefender` | Defender services, drivers and policies disabled |
| `RemoveDefender` | Also deletes Defender files (implies `DisableDefender`) |
| `DisableUAC` | `EnableLUA=0` |
| `DisableHibernation` | No hibernation / fast startup |
| `DisablePagefile` | No pagefile |
| `DisableReservedStorage` | No reserved storage |
| `DisableTelemetry` | `AllowTelemetry=0`, DiagTrack off |
| `DisableSmartScreen` | SmartScreen policy off |
| `DisableWindowsUpdate` | Automatic updates off |
| `DisableSystemRestore` | System Restore policy off, no automatic restore points |
| `DisableSearchService` | Windows Search (`WSearch`) disabled |
| `RemoveOneDrive` | Deletes `OneDriveSetup.exe`, removes its Run entry, disables file sync policy |
| `Win11Bypass` | `LabConfig` bypass flags (only matters for later in-place upgrades) |
| `BypassNRO` | Allows OOBE without network |
| `NoShortcutSuffix` | No "- Shortcut" suffix on new shortcuts (new users) |
| `ShowFileExtensions` | Show all file extensions (new users) |
| `ExplorerOpenThisPC` | Explorer opens to This PC (new users) |
| `DragDropCopy` | Default drag-and-drop action is copy |
| `ThisPCOnlyDesktopDocsDownloads` | Hides Pictures, Videos, Music, 3D Objects in This PC |

## Notes

- Registry edits use backup/restore privileges, so protected keys can be written. `-RegFile`
  imports use plain `reg import` and may be denied on protected keys.
- Per-user tweaks (`NoShortcutSuffix`, `ShowFileExtensions`, `ExplorerOpenThisPC`) are written to
  the Default profile: they apply to users created after the first boot, not to existing ones.
- `RemoveDefender` deletes the Defender files but not the WinSxS copies; servicing may restore them.
- `Win11Bypass` only matters for later in-place upgrades; the applied image never runs Setup's checks.
- `LocalAccount` is written to `unattend.xml` in plain text; Windows sanitises its cached copy after setup.
- Hibernation is not supported when booting from a VHD(X) regardless of the tweak.
- Disabling `WSearch` makes Start menu and Explorer search slow or incomplete.
- DISM refuses unsigned drivers, so an unsigned driver in `Drivers` fails the build.
- Not implemented: GUI, Windows To Go, WIMBoot, boot repair, moving the Users folder.
- Versions v1 to v4 were written without access to a Windows machine; v5 fixes the first bug found by a real run. They are untested by the
  author. Try a throwaway VHDX with `-Verbose` first.

## Changelog

### v5
- Fix: "No drive letter was assigned" after creating the VHDX. If Windows does not assign a
  letter on re-attach (automount disabled, letter not remembered), the script now looks at the
  partitions and assigns one explicitly (`Add-PartitionAccessPath`)
- A failed build now deletes the incomplete `.vhd(x)` it created, so the command can be re-run
  without deleting the file by hand (`-KeepFailedImage` keeps it; it is also kept if the boot
  entry was already created)
- README: `-Edition` matching rules documented, usage example uses the full edition name and
  the image on `D:\`

### v4
- Version number added to the script (`$script:Version`, verbose banner, result object) and to
  the file names (`PSWindowsNativeBoot_v5.ps1`, `README_v5.md`)
- `Tools` folder next to the script: whole content (exe files directly and/or in subfolders) is
  copied to `C:\Tools` automatically (`-ToolsFolder`, `-SkipTools`)
- `Drivers` folder next to the script: injected automatically when it contains `.inf` files; an
  empty or missing folder is skipped without error (`-DriversFolder`, `-SkipDrivers`)
- `diskpart.log` is written next to the script
- Changelog now lists every version

### v3
- New tweaks: `DisableSystemRestore`, `DisableSearchService`, `RemoveOneDrive`, `NoShortcutSuffix`,
  `ShowFileExtensions`, `ExplorerOpenThisPC`, `DragDropCopy`, `ThisPCOnlyDesktopDocsDownloads`
- Default user profile (`NTUSER.DAT`) is loaded offline as a third hive for per-user settings
- Registry writes now use backup/restore privileges (P/Invoke helper), so protected keys such as
  `Services\WinDefend` and `FolderDescriptions` can be written
- Added `Remove-OfflineRegValue` and Binary registry values

### v2
- `-InjectPath` / `-InjectFolder`: copy files and folders into the image (default `C:\Tools`)
- `-DesktopShortcut`: create all-users desktop shortcuts (e.g. Network Connections via `ncpa.cpl`)

### v1 (first extended rewrite)
- Sources: `.iso`, `install.wim`, `install.esd`, `install.swm`, folder or drive; edition picker
  (`-Edition`, `-Index`, `Get-WindowsSetupEdition`)
- Compression choice: `None`, `XPRESS4K`, `XPRESS8K`, `XPRESS16K`, `LZX`; configurable folder list
- `.vhd` or `.vhdx`, expandable or fixed, GPT or MBR, volume label
- Boot options: `-BootMode` (UEFI / BIOS / ALL), `-BootDescription`, `-BootDrive`, `-BootLocale`,
  `-NoBootEntry`
- Offline registry tweaks: `DisableDefender`, `RemoveDefender`, `DisableUAC`, `DisableHibernation`,
  `DisablePagefile`, `DisableReservedStorage`, `DisableTelemetry`, `DisableSmartScreen`,
  `DisableWindowsUpdate`, `Win11Bypass`, `BypassNRO`
- `-RegFile` offline `.reg` import (limited to HKLM\SOFTWARE and \SYSTEM), `-RunOnce` commands
- Offline drivers, updates (`.msu` / `.cab`), .NET 3.5, provisioned Appx removal
- `unattend.xml`: own file or generated (account, computer name, locale, time zone, product key,
  auto logon, skip OOBE)
- Settings profiles: `-SaveProfile` / `-LoadProfile` (JSON)
- Fixes over the original: README/parameter mismatch (`-Size`, alias `-ImageSize`), ambiguous
  parameter sets, `try/finally` cleanup of mounts and hives, exit-code checks for DISM, bcdboot,
  reg and diskpart, locale-independent diskpart check, race-free drive letter detection

### v0 (upstream, Stefan H, 2017)
- Creates a `.vhdx`, mounts, partitions and formats it
- `DISM /Apply-Image` of `install.wim` with `/Compact`
- `compact.exe` with `/EXE:XPRESS16K` on a fixed folder list
- `bcdboot` to add the boot entry
- Parameters: `Source`, `ImagePath`, `Size`, `Index`
