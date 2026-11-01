# Windows ARM Boot Repair

適用於 **RTX Spark／Windows on ARM 啟動修復情境**的開源工具。從 ARM64 Windows PE 自動辨識離線 Windows 和同碟 EFI 系統分區，備份後修復 Windows Boot Manager、BCD、ARM64 備用啟動檔與 UEFI 啟動項。提供診斷、互動與無人值守模式。

**v0.1.0 為實驗性版本。通用版尚未完成實機開機驗證。** 自動化測試驗證程式選擇邏輯和模擬韌體交易，不代表每臺電腦都能啟動。本專案由 HP ARM 筆電遷移後的修復工具整理而來，已移除個別機器和 U 盤的限制。

這是社群工具，與 Microsoft、NVIDIA、HP 或 Qualcomm 沒有官方關係。「RTX Spark」用於描述原始使用情境，不是相容性認證。

[下載工具包](https://github.com/derrickyau9/Windows-ARM-Boot-Repair/releases) · [English](docs/README.en.md) · [PE 整合](docs/PE-INTEGRATION.md) · [修復流程](docs/DESIGN.md) · [相容性與測試](docs/COMPATIBILITY.md)

## 三種模式

| 入口 | 行為 |
| --- | --- |
| `Diagnose.cmd` | 列出硬體、磁碟、Windows 候選與檢查結果；不修改 EFI／BCD／韌體啟動項。 |
| `Run-Repair.cmd` | 互動選擇 Windows 和 EFI，顯示修復目標，再確認執行。 |
| `Run-Automatic.cmd` | 只有在目標唯一且所有檢查通過時才修復；不確定就停止。 |

直接執行 `Repair-ArmBoot.ps1` 的預設模式是 `Diagnose`。工具預設不重新啟動。

## 開始使用

1. 準備能在目標電腦正常啟動、看見內建硬碟的 **ARM64 Windows PE**。PE 必須包含 PowerShell、.NET、StorageWMI 及裝置所需驅動。
2. 從 Releases 下載 ZIP，將其中的工具資料夾放到 U 盤；可改名為 `E:\WindowsArmBootRepair`，以配合以下範例。
3. 在**目標電腦的 PE** 中開啟命令提示字元，先診斷，再修復。以下 `E:` 請換成 PE 當下的 U 盤代號：

```bat
E:\WindowsArmBootRepair\Diagnose.cmd -BackupRoot E:\
E:\WindowsArmBootRepair\Run-Repair.cmd -BackupRoot E:\
```

無人值守執行：

```bat
E:\WindowsArmBootRepair\Run-Automatic.cmd -BackupRoot E:\
```

也可在備份 U 盤根目錄建立空白檔案 `ARM-BOOT-REPAIR.TAG`，之後三個入口都能自動尋找它。若找到多個標記，請指定 `-BackupRoot`。備份媒體必須是與目標 Windows 不同的實體 USB／SD 磁碟。

`-BackupRoot E:\` 會使用 `E:\ARM-BootRepair-Logs`；若指定資料夾，例如 `E:\MyRepairLogs`，則直接在該資料夾保存每次執行結果。請先拔除無關外接硬碟，尤其是可能被回報為 NVMe／SATA 的 Thunderbolt／eSATA 外接盒。

修復後查看 `ARM-BootRepair-Logs\<此次執行>\result.txt`。只有 `REPAIRED` 表示 EFI／BCD 與韌體啟動項均通過程式核對；仍需重新啟動驗證 Windows。`FILES_ONLY` 表示僅完成磁碟上的啟動檔，不能當成完整修復。

## 自動適應的範圍

- 辨識 ARM64 Windows 檔案，不假設 Windows 永遠在 `C:`。
- 搜尋受支援的內建 GPT 磁碟，不以品牌、容量或序號綁定目標。
- 多套 Windows、多個 EFI 分區可在互動模式選擇；自動模式拒絕猜測。
- 修復前備份 EFI 並逐檔核對雜湊；UEFI 變數有獨立備份和失敗回復。
- 韌體無法存取時，預設 `Auto` 可退為僅修復啟動檔，並傳回不同結果。
- 保留其他廠商 EFI 目錄和既有韌體啟動項；所選 Windows 會成為預設及下一次啟動目標，取代舊的單次恢復選擇。

它不安裝 Windows、不替換 OEM 驅動、不解密 BitLocker，也不建立或格式化缺少的 EFI 分區。PE 本身缺少儲存／USB 驅動時，先依裝置廠商提供的驅動建立可用的 PE。完整條件見[相容性文件](docs/COMPATIBILITY.md)。

## 進階參數

```powershell
.\Repair-ArmBoot.ps1 -Mode Interactive -BackupRoot E:\ -FirmwareMode Required
.\Repair-ArmBoot.ps1 -Mode Diagnose -BackupRoot E:\
.\Repair-ArmBoot.ps1 -Mode Automatic -BackupRoot E:\ -FirmwareMode Skip
```

| 參數 | 用途 |
| --- | --- |
| `-Mode Diagnose\|Interactive\|Automatic` | 診斷、互動修復、自動修復。 |
| `-BackupRoot E:\` | 指定外接備份媒體，避免多個標記造成歧義。 |
| `-FirmwareMode Auto` | 能存取韌體則修復；預先偵測不可用時回報 `FILES_ONLY`。 |
| `-FirmwareMode Required` | 韌體預檢失敗就停止，還不會寫入目標 EFI。 |
| `-FirmwareMode Skip` | 明確只修復 EFI／BCD，結果為 `FILES_ONLY`。 |
| `-DiskNumber`、`-WindowsPartitionNumber`、`-EspPartitionNumber` | 明確指定候選；仍須通過架構、磁碟和分區檢查。 |
| `-RebootAfterRepair` | 只在完整修復後要求重新啟動；預設關閉。 |

| 結束代碼 | 意義 |
| --- | --- |
| `0` | 診斷完成，或完整修復通過核對；以 `result.txt` 的狀態區分。 |
| `2` | `FILES_ONLY`，未更新韌體啟動項。 |
| `3` | 寫入啟動檔前停止；查看原因。 |
| `4` | 寫入開始後發生錯誤；查看回復結果。 |
| `5` | 使用者取消。 |

## 從原始碼建置

在 Windows 上使用 **Windows PowerShell 5.1** 及 .NET Framework 4.x 編譯器；建置電腦可以是 x64。測試只使用檔案 fixture 和模擬韌體，不寫入建置電腦的 EFI 或韌體。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\New-Package.ps1 -SkipBuild
```

輸出位於 `dist\Windows-ARM-Boot-Repair-0.1.0`。ZIP 僅含本專案工具，不含 Windows／PE 映像、Microsoft 啟動檔、廠商驅動、實機日誌或磁碟備份。DLL 為 AnyCPU .NET 程式庫；真正的韌體操作只允許在 ARM64 UEFI WinPE 執行。

## 回報問題

提供版本、硬體型號、PE 版本、目前步驟和 `result.txt` 的錯誤摘要。日誌和備份可能含磁碟序號、分區識別碼及原始啟動設定；公開貼出前先刪除這些識別資料。不要上傳整份 EFI／韌體備份或 BitLocker 金鑰。

MIT License。技術依據見[設計文件](docs/DESIGN.md#references)。
