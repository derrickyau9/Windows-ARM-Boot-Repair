# 整合到 ARM64 Windows PE

## 已經能啟動的 PE

最簡單的方式是不修改映像：將 Release ZIP 解壓到 U 盤資料分區，在 PE 桌面或命令提示字元執行 `Run-Repair.cmd -BackupRoot E:\`。`E:` 是例子，需使用 PE 中實際的 U 盤代號。

此方式不會將 U 盤格式化，也不修改 PE 的 OEM 驅動載入順序。診斷與修復程式都必須在目標電腦的原生 ARM64 PE 中執行。

## PE 的必要元件

使用與 PE **相同架構及 ADK 組建**的元件，依相依順序加入：

1. WinPE-WMI
2. WinPE-NetFX
3. WinPE-Scripting
4. WinPE-PowerShell
5. WinPE-StorageWMI

同時需要對應儲存控制器與輸入裝置的 ARM64 驅動，以及 PE 自帶的 ARM64 `bcdboot.exe`、`bcdedit.exe`、`wpeutil.exe`。啟動檔的版本必須適合所修復的 Windows。工具會在寫入前檢查所需命令與執行架構，但無法替每一個 OEM 組合保證版本相容。

精簡 PE 可能移除了標準 .NET 功能。本工具以 CSV 和純文字儲存報告，不依賴 PowerShell JSON 轉換；執行前仍會檢查雜湊、報告寫入、程式庫載入和 UEFI 路徑編碼。

參考 [Microsoft WinPE 元件文件](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11)。

## 加到已掛載的離線 PE 映像

先備份你的 WIM，再以 DISM 掛載正確索引。下列路徑僅為範例；安裝腳本**不會替你選擇 WIM、掛載、提交映像或重建啟動 U 盤**。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-ToPe.ps1 `
  -MountedPePath C:\PeWork\Mount -BackupMediaRoot E:\
```

工具會複製到離線映像的 `ArmBootRepair` 目錄，並在外接備份媒體根目錄準備辨識標記。預設不更動啟動流程。提交 WIM、將它放回原 PE 媒體，以及保留可開機的舊版選單，仍由你原有的 PE 建置流程負責。

## 選擇開機自動執行

對使用標準 `startnet.cmd` 且沒有 `winpeshl.ini` 的映像，可明確要求互動或自動模式：

```powershell
.\tools\Install-ToPe.ps1 -MountedPePath C:\PeWork\Mount `
  -BackupMediaRoot E:\ -AutoStartMode Interactive
```

`Automatic` 為無人值守修復。只應在你準備好於每次 PE 開機都嘗試修復時啟用；預設仍不重啟電腦。

已有 `winpeshl.ini` 的 OEM／第三方 PE 可能有特定的驅動初始化和桌面啟動順序。安裝工具不會自動覆寫它；請使用整合報告提供的命令，由 PE 維護者放在 **OEM 驅動載入及 `wpeinit` 完成之後**。不要刪除原有 Shell 或驅動載入項。

在目前 PE 手動啟動映像內工具的典型命令為：

```bat
X:\ArmBootRepair\Run-Repair.cmd
```

## 日誌與結果

外接備份媒體的 `ARM-BootRepair-Logs` 內每次執行建立獨立目錄。執行時間可能受 PE／韌體時鐘影響，因此目錄亦含隨機識別碼。保留整個失敗執行目錄直到問題排除；公開回報只貼經過刪除識別資訊的錯誤摘要。
