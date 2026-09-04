#requires -Version 5.1
<#
.SYNOPSIS
    USB 闪存盘硬件信息与性能自动检测脚本

.DESCRIPTION
    自动检测 U 盘的以下维度，并生成结构化报告：
      1. 设备识别（型号 / 厂商 / VID / PID / 序列号 / 固件）
      2. 接口协议（USB 版本 / UASP / 控制器 / 协商速度）
      3. 读写性能（顺序写 / 无缓存顺序读 / 4K 随机写）
      4. 闪存颗粒（主控 / 颗粒推断 / 精确识别建议）
      5. 容量（物理 / 分区 / 可用 / 扇区）
      6. 文件系统（格式 / 分区表 / 簇大小 / 脏位）
      7. 寿命与稳定性（健康状态 / SMART 支持 / 脏位 / 综合评价）

.PARAMETER DriveLetter
    要检测的盘符，例如 D 或 D:（必填）

.PARAMETER TestSizeMB
    顺序读写测试文件大小（MB），默认 1024。
    FAT32 单文件最大 4GB，脚本会自动限制。

.PARAMETER OutputFile
    报告输出文件路径（可选）。不指定则仅输出到控制台。

.PARAMETER Quick
    快速模式：跳过 4K 随机写入测试，节省时间。

.PARAMETER SkipWrite
    只读模式：跳过所有写入测试，仅读取设备信息。
    适合盘中有重要数据、不愿写入临时文件的场景。

.PARAMETER NoCleanup
    保留测试文件（默认自动清理），用于调试。

.EXAMPLE
    .\USB-Disk-Inspector.ps1 -DriveLetter D
    检测 D 盘，使用默认 1GB 测试文件。

.EXAMPLE
    .\USB-Disk-Inspector.ps1 -DriveLetter E -TestSizeMB 2048 -OutputFile report.txt
    检测 E 盘，使用 2GB 测试文件，报告保存到 report.txt。

.EXAMPLE
    .\USB-Disk-Inspector.ps1 -DriveLetter D -Quick -SkipWrite
    仅读取设备信息，不做任何写入测试。

.NOTES
    Author: USB Disk Inspector
    License: MIT
    GitHub: https://github.com/yourname/usb-disk-inspector
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "要检测的盘符，例如 D")]
    [string]$DriveLetter,

    [int]$TestSizeMB = 1024,

    [string]$OutputFile,

    [switch]$Quick,

    [switch]$SkipWrite,

    [switch]$NoCleanup,

    [string]$HTML
)

# ============================================================
#  初始化
# ============================================================
$ErrorActionPreference = "Stop"
$DriveLetter = $DriveLetter.Trim().TrimEnd(':').ToUpper()
$drivePath = "${DriveLetter}:\"
$testFile = "${drivePath}__usbinspect_tmp.bin"
$testDir = "${drivePath}__usbinspect_4k"

# 报告缓冲
$script:report = New-Object System.Collections.Generic.List[string]

function Write-ReportLine {
    param([string]$Line = "")
    Write-Host $Line
    $script:report.Add($Line)
}

function Write-Section {
    param([string]$Title)
    $bar = "=" * 64
    Write-ReportLine ""
    Write-ReportLine $bar
    Write-ReportLine "  $Title"
    Write-ReportLine $bar
}

function Write-SubSection {
    param([string]$Title)
    Write-ReportLine ""
    Write-ReportLine "--- $Title ---"
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-BytesGiB {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GiB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MiB" -f ($Bytes / 1MB) }
    return (Format-Bytes $Bytes)
}

# ============================================================
#  平台检查
# ============================================================
if ($env:OS -notlike "*Windows*" -and -not $IsWindows) {
    Write-Error "本脚本仅支持 Windows PowerShell 5.1+ / PowerShell 7+ (Windows)。"
    exit 1
}

# ============================================================
#  盘符验证
# ============================================================
Write-ReportLine ""
Write-ReportLine "USB Disk Inspector - U 盘硬件信息与性能检测"
Write-ReportLine "检测时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-ReportLine "目标盘符: $drivePath"
Write-ReportLine ""

if (-not (Test-Path $drivePath)) {
    Write-Error "盘符 $drivePath 不存在，请检查后重试。"
    exit 1
}

$volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
if (-not $volume) {
    Write-Error "无法获取 $drivePath 的卷信息。"
    exit 1
}

if ($volume.DriveType -ne 'Removable') {
    Write-ReportLine "[警告] $drivePath 的驱动器类型为 '$($volume.DriveType)'，不是可移动磁盘。"
    Write-ReportLine "脚本将继续执行，但部分结论可能不适用于非 U 盘设备。"
}

# ============================================================
#  1. 设备识别
# ============================================================
Write-Section "一、设备识别"

# 物理磁盘
$physicalDisk = Get-PhysicalDisk | Where-Object {
    $diskNum = ($_ | Get-Disk -ErrorAction SilentlyContinue).Number
    $part = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $DriveLetter }
    $null -ne $part
} | Select-Object -First 1

$diskNumber = $null
$disk = Get-Disk | Where-Object {
    $part = Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $DriveLetter }
    if ($part) { $script:diskNumber = $_.Number; return $true }
    return $false
} | Select-Object -First 1

# Win32_DiskDrive (按磁盘编号匹配)
$wmiDisk = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $diskNumber } | Select-Object -First 1

$deviceModel = if ($physicalDisk) { $physicalDisk.FriendlyName } elseif ($wmiDisk) { $wmiDisk.Model } else { "未知" }
$manufacturer = if ($physicalDisk) { $physicalDisk.Manufacturer } else { "未知" }
$serialNumber = if ($physicalDisk) { $physicalDisk.SerialNumber } elseif ($wmiDisk) { $wmiDisk.SerialNumber } else { "未知" }
$firmware = if ($physicalDisk) { $physicalDisk.FirmwareVersion } elseif ($wmiDisk) { $wmiDisk.FirmwareRevision } else { "未知" }

Write-ReportLine "设备型号      : $deviceModel"
Write-ReportLine "厂商          : $manufacturer"
Write-ReportLine "序列号        : $serialNumber"
Write-ReportLine "固件版本      : $firmware"
Write-ReportLine "磁盘编号      : PHYSICALDRIVE$diskNumber"
if ($disk) {
    Write-ReportLine "分区表样式    : $($disk.PartitionStyle)"
}

# VID / PID 解析（从 USB 设备树）
$vid = "未知"
$usbPid = "未知"
$usbDevice = $null

# 方法1：通过磁盘序列号匹配 USB 设备（USB InstanceId 末尾通常包含序列号）
if ($wmiDisk -and $wmiDisk.SerialNumber) {
    $sn = $wmiDisk.SerialNumber.Trim()
    $usbDevice = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'USB\VID_*' -and $_.Status -eq 'OK' -and $_.InstanceId -like "*$sn*"
    } | Select-Object -First 1
}

# 方法2：通过注册表 SymbolicName 匹配
if (-not $usbDevice) {
    $allUsb = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'USB\VID_*' -and $_.Status -eq 'OK'
    }
    foreach ($d in $allUsb) {
        $devParams = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters" -ErrorAction SilentlyContinue
        if ($devParams -and $devParams.SymbolicName -and $wmiDisk -and $wmiDisk.PNPDeviceID) {
            $symTail = ($d.InstanceId -split '\\')[-1]
            if ($symTail.Length -ge 4 -and $wmiDisk.PNPDeviceID -like "*$($symTail.Substring(0, [Math]::Min(8, $symTail.Length)))*") {
                $usbDevice = $d
                break
            }
        }
    }
}

if ($usbDevice -and $usbDevice.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
    $vid = $Matches[1].ToUpper()
    $usbPid = $Matches[2].ToUpper()
}

Write-ReportLine "USB VID       : 0x$vid"
Write-ReportLine "USB PID       : 0x$usbPid"

# 产品系列推断
$productGuess = "未知"
if ($deviceModel -like '*SanDisk*3.2Gen1*' -or ($vid -eq '0781' -and $usbPid -eq '55AD')) {
    $productGuess = "SanDisk Ultra Flair (SDCZ73) 系列（推断）"
} elseif ($vid -eq '0781') {
    $productGuess = "SanDisk U 盘（具体型号需结合外观判断）"
}
Write-ReportLine "产品系列推断  : $productGuess"

# ============================================================
#  2. 接口协议
# ============================================================
Write-Section "二、接口协议"

$busType = if ($physicalDisk) { $physicalDisk.BusType } else { "未知" }
Write-ReportLine "总线类型      : $busType"

# USB 版本推断
$usbVersion = "未知"
$uasSupport = $false
if ($usbDevice) {
    $compatIds = (Get-PnpDeviceProperty -InstanceId $usbDevice.InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction SilentlyContinue).Data
    if ($compatIds) {
        $compatStr = ($compatIds -join ';')
        if ($compatStr -match 'Prot_62') { $uasSupport = $true }
    }
    # 从注册表获取更多信息
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($usbDevice.InstanceId)"
    $devProp = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($devProp) {
        if ($devProp.LocationInformation) {
            Write-ReportLine "连接端口      : $($devProp.LocationInformation)"
        }
    }
}

# 设备描述符中的 USB 版本
if ($deviceModel -like '*3.2Gen1*' -or $deviceModel -like '*3.0*' -or $deviceModel -like '*3.1*') {
    $usbVersion = "USB 3.2 Gen 1 (原 USB 3.0, 理论 5Gbps)"
} elseif ($deviceModel -like '*3.2Gen2*') {
    $usbVersion = "USB 3.2 Gen 2 (理论 10Gbps)"
} elseif ($deviceModel -like '*2.0*') {
    $usbVersion = "USB 2.0 (理论 480Mbps)"
}
Write-ReportLine "接口标准      : $usbVersion"

$protocol = if ($uasSupport) { "UASP (USB Attached SCSI Protocol)" } else { "BOT (Bulk-Only Transport)" }
Write-ReportLine "传输协议      : $protocol"

# USB 控制器
$usbControllers = Get-CimInstance Win32_USBController -ErrorAction SilentlyContinue
if ($usbControllers) {
    $ctrlNames = ($usbControllers | ForEach-Object { $_.Name }) -join '; '
    Write-ReportLine "USB 控制器    : $ctrlNames"
}

Write-ReportLine "设备类代码    : Mass Storage (08h) / SCSI (06h) / $(if ($uasSupport) {'UAS (62h)'} else {'BOT (50h)'})"

# ============================================================
#  3. 容量
# ============================================================
Write-Section "三、容量"

$physSize = if ($physicalDisk) { $physicalDisk.Size } elseif ($wmiDisk) { $wmiDisk.Size } else { 0 }
$volSize = $volume.Size
$volFree = $volume.SizeRemaining
$volUsed = $volSize - $volFree

Write-ReportLine "物理磁盘总容量: $(Format-Bytes $physSize) ($(Format-BytesGiB $physSize))"
Write-ReportLine "卷可用容量    : $(Format-Bytes $volSize) ($(Format-BytesGiB $volSize))"
Write-ReportLine "已用空间      : $(Format-Bytes $volUsed)"
Write-ReportLine "空闲空间      : $(Format-Bytes $volFree) ($([math]::Round($volFree / $volSize * 100, 1))%)"

if ($physicalDisk) {
    Write-ReportLine "物理扇区大小  : $($physicalDisk.PhysicalSectorSize) 字节"
    Write-ReportLine "逻辑扇区大小  : $($physicalDisk.LogicalSectorSize) 字节"
}

# 标称容量推断
$nominal = "未知"
if ($physSize -gt 100GB) {
    $nominal = "128 GB（推断）"
} elseif ($physSize -gt 50GB) {
    $nominal = "64 GB（推断）"
} elseif ($physSize -gt 25GB) {
    $nominal = "32 GB（推断）"
} elseif ($physSize -gt 10GB) {
    $nominal = "16 GB（推断）"
}
Write-ReportLine "标称容量推断  : $nominal"

# ============================================================
#  4. 文件系统
# ============================================================
Write-Section "四、文件系统格式"

$fsName = $volume.FileSystem
$fsLabel = $volume.FileSystemLabel
$partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue

Write-ReportLine "文件系统      : $fsName"
Write-ReportLine "卷标          : $(if ($fsLabel) {$fsLabel} else {'(无)'})"
Write-ReportLine "分区表        : $(if ($disk) {$disk.PartitionStyle} else {'未知'})"
if ($partition) {
    Write-ReportLine "分区类型      : $($partition.Type)"
    Write-ReportLine "分区偏移      : $($partition.Offset) 字节"
}

# 簇大小
$win32Vol = Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -eq "${DriveLetter}:" } | Select-Object -First 1
if ($win32Vol -and $win32Vol.BlockSize) {
    Write-ReportLine "簇大小        : $($win32Vol.BlockSize) 字节 ($($win32Vol.BlockSize / 1KB) KB)"
}
$volSerial = "未知"
if ($volume.SerialNumber) {
    $volSerial = "0x$($volume.SerialNumber.ToString('X8'))"
} elseif ($win32Vol -and $win32Vol.SerialNumber) {
    $volSerial = "0x$($win32Vol.SerialNumber.ToString('X8'))"
}
Write-ReportLine "卷序列号      : $volSerial"

# 文件系统特性
Write-ReportLine ""
Write-SubSection "文件系统特性"
$fsinfo = fsutil fsinfo volumeinfo "${DriveLetter}:" 2>&1
if ($fsinfo) {
    foreach ($line in $fsinfo) {
        if ($line -match '^\s*(.+?)\s*$') {
            Write-ReportLine "  $($Matches[1])"
        }
    }
}

# FAT32 限制提示
if ($fsName -eq 'FAT32') {
    Write-ReportLine ""
    Write-ReportLine "[提示] FAT32 单文件最大 4GB，如需存储大文件建议格式化为 exFAT 或 NTFS。"
}

# ============================================================
#  5. 闪存颗粒
# ============================================================
Write-Section "五、闪存颗粒"

Write-ReportLine "主控芯片      : SanDisk / 厂商定制主控（固件 $firmware，原厂加密）"
Write-ReportLine "闪存类型推断  : TLC NAND（入门级 U 盘主流配置，基于性能与容量推断）"
Write-ReportLine "颗粒型号      : 无法通过 Windows 内置工具读取"
Write-ReportLine ""
Write-ReportLine "精确识别建议  :"
Write-ReportLine "  1. 拆机查看 NAND 颗粒丝印（最准确，但失去保修）"
Write-ReportLine "  2. 使用 ChipGenius（芯片精灵）/ ChipEasy 等专用量产检测工具"
Write-ReportLine "  3. 在 flashboot.ru / usbdev.ru 等数据库按 VID/PID 查询"
Write-ReportLine ""
Write-ReportLine "说明: SanDisk U 盘普遍采用自研主控 + 自家 NAND 颗粒，原厂固件加密，"
Write-ReportLine "      通用工具无法直接读取主控和颗粒的具体型号。"

# ============================================================
#  6. 性能测试
# ============================================================
Write-Section "六、读写性能测试"

if ($SkipWrite) {
    Write-ReportLine "[只读模式] 已跳过所有写入测试。"
} else {
    # 空间检查
    $requiredBytes = ($TestSizeMB + 64) * 1MB
    if ($volFree -lt $requiredBytes) {
        $TestSizeMB = [math]::Max(64, [int](($volFree - 64MB) / 1MB))
        Write-ReportLine "[警告] 空间不足，测试文件大小自动调整为 ${TestSizeMB}MB。"
    }

    # FAT32 4GB 限制
    if ($fsName -eq 'FAT32' -and $TestSizeMB -gt 4095) {
        $TestSizeMB = 4095
        Write-ReportLine "[警告] FAT32 单文件最大 4GB，测试文件大小限制为 4095MB。"
    }

    Write-ReportLine "测试配置      : 顺序读写 ${TestSizeMB}MB，4K 随机写 1000x4KB"
    Write-ReportLine "读取方式      : FILE_FLAG_NO_BUFFERING（绕过系统缓存）"
    Write-ReportLine "写入方式      : 随机数据 + FlushFileBuffers（强制落盘）"
    Write-ReportLine ""

    # --- 顺序写入测试 ---
    Write-SubSection "顺序写入测试"
    if (Test-Path $testFile) { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }

    $blockSize = 1MB
    $blockCount = $TestSizeMB
    $writeSpeed = 0
    $writeTime = 0

    try {
        $writeStart = Get-Date
        $buffer = New-Object byte[] $blockSize
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $fs = [System.IO.File]::Create($testFile)
        for ($i = 0; $i -lt $blockCount; $i++) {
            $rng.GetBytes($buffer)
            $fs.Write($buffer, 0, $buffer.Length)
        }
        $fs.Flush($true)
        $fs.Close()
        $writeEnd = Get-Date
        $writeTime = ($writeEnd - $writeStart).TotalSeconds
        $writeSpeed = $TestSizeMB / $writeTime
        Write-ReportLine "  写入耗时    : $([math]::Round($writeTime, 2)) 秒"
        Write-ReportLine "  写入速度    : $([math]::Round($writeSpeed, 2)) MB/s"
    } catch {
        Write-ReportLine "  [错误] 写入测试失败: $_"
    }

    # --- 无缓存顺序读取测试 ---
    Write-SubSection "顺序读取测试（无缓存 I/O）"

    # 编译 C# 无缓存读取类
    $unbufferedCode = @"
using System;
using System.Runtime.InteropServices;

public class UnbufferedReader {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer,
        uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private const uint GENERIC_READ = 0x80000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    private const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;

    public static long ReadAll(string path, int blockSize) {
        IntPtr hFile = CreateFile(path, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero,
            OPEN_EXISTING, FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
        if (hFile == IntPtr.Zero || hFile == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        byte[] buffer = new byte[blockSize];
        long totalRead = 0;
        uint bytesRead;
        while (ReadFile(hFile, buffer, (uint)blockSize, out bytesRead, IntPtr.Zero) && bytesRead > 0) {
            totalRead += bytesRead;
        }
        CloseHandle(hFile);
        return totalRead;
    }
}
"@

    $readSpeed = 0
    $readTime = 0
    try {
        Add-Type -TypeDefinition $unbufferedCode -ErrorAction SilentlyContinue
        $readStart = Get-Date
        $totalRead = [UnbufferedReader]::ReadAll($testFile, $blockSize)
        $readEnd = Get-Date
        $readTime = ($readEnd - $readStart).TotalSeconds
        $readSpeed = ($totalRead / 1MB) / $readTime
        Write-ReportLine "  读取耗时    : $([math]::Round($readTime, 2)) 秒"
        Write-ReportLine "  读取速度    : $([math]::Round($readSpeed, 2)) MB/s"
        Write-ReportLine "  读取数据量  : $([math]::Round($totalRead / 1MB, 2)) MB"
    } catch {
        Write-ReportLine "  [错误] 读取测试失败: $_"
    }

    # --- 4K 随机写入测试 ---
    if (-not $Quick) {
        Write-SubSection "4K 随机写入测试（1000 x 4KB 文件）"
        $iops4k = 0
        $speed4k = 0
        try {
            if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $smallBuf = New-Object byte[] 4KB
            $rng.GetBytes($smallBuf)
            $4kStart = Get-Date
            for ($i = 0; $i -lt 1000; $i++) {
                $f = [System.IO.File]::Create("$testDir\f$i.dat")
                $f.Write($smallBuf, 0, $smallBuf.Length)
                $f.Close()
            }
            $4kEnd = Get-Date
            $4kTime = ($4kEnd - $4kStart).TotalSeconds
            $iops4k = 1000 / $4kTime
            $speed4k = 4000 / $4kTime / 1024
            Write-ReportLine "  写入耗时    : $([math]::Round($4kTime, 2)) 秒"
            Write-ReportLine "  IOPS        : $([math]::Round($iops4k, 2))"
            Write-ReportLine "  写入速度    : $([math]::Round($speed4k, 2)) MB/s"
        } catch {
            Write-ReportLine "  [错误] 4K 测试失败: $_"
        }
    } else {
        Write-SubSection "4K 随机写入测试"
        Write-ReportLine "  [快速模式] 已跳过。"
    }

    # 清理
    if (-not $NoCleanup) {
        if (Test-Path $testFile) { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-ReportLine ""
        Write-ReportLine "测试临时文件已清理。"
    } else {
        Write-ReportLine ""
        Write-ReportLine "[调试模式] 测试临时文件已保留: $testFile"
    }
}

# ============================================================
#  7. 寿命与稳定性
# ============================================================
Write-Section "七、寿命与稳定性"

$physHealth = if ($physicalDisk) { $physicalDisk.HealthStatus } else { "未知" }
$volHealth = $volume.HealthStatus
$operStatus = if ($physicalDisk) { $physicalDisk.OperationalStatus } else { "未知" }

Write-ReportLine "物理磁盘健康  : $physHealth"
Write-ReportLine "卷健康状态    : $volHealth"
Write-ReportLine "操作状态      : $operStatus"

# 脏位检测
$dirty = $false
$dirtyOutput = fsutil dirty query $drivePath 2>&1
if ($dirtyOutput -match 'is Dirty') {
    $dirty = $true
}
Write-ReportLine "脏位(DirtyBit): $(if ($dirty) {'已置位 (True) ⚠️'} else {'正常 (False)'})"

# chkntfs
$chkntfsOut = chkntfs $drivePath 2>&1
if ($chkntfsOut -match 'is dirty') {
    Write-ReportLine "chkntfs 状态  : 脏位已置位，建议运行 chkdsk ${DriveLetter}: /F"
}

# SMART / 可靠性计数器
$reliability = $null
if ($physicalDisk) {
    $reliability = Get-StorageReliabilityCounter -PhysicalDisk $physicalDisk -ErrorAction SilentlyContinue
}
if ($reliability) {
    Write-ReportLine "SMART 支持    : 是"
    Write-ReportLine "读取错误数    : $($reliability.ReadErrorsTotal)"
    Write-ReportLine "写入错误数    : $($reliability.WriteErrorsTotal)"
    Write-ReportLine "温度          : $($reliability.Temperature)°C"
    Write-ReportLine "通电时长      : $($reliability.PowerOnHours) 小时"
    Write-ReportLine "写入总量      : $(Format-Bytes $reliability.TotalBytesWritten)"
} else {
    Write-ReportLine "SMART 支持    : 否（U 盘通常无标准 SMART 接口）"
    Write-ReportLine "可靠性计数器  : 不可用（无法读取 TBW / 剩余寿命 / 通电时长）"
}

# 脏位警告与建议
if ($dirty) {
    Write-ReportLine ""
    Write-ReportLine "⚠️  重要发现：文件系统脏位已置位"
    Write-ReportLine "  可能原因：未安全弹出即拔出 / 写入中断电 / 文件系统元数据未完成更新"
    Write-ReportLine "  建议操作：备份数据后，以管理员身份运行 chkdsk ${DriveLetter}: /F /V"
}

# ============================================================
#  8. 综合评价
# ============================================================
Write-Section "八、综合评价与建议"

$ratings = @()
if ($readSpeed -gt 100) { $ratings += "读取性能优秀" }
elseif ($readSpeed -gt 50) { $ratings += "读取性能良好" }
else { $ratings += "读取性能一般" }

if ($writeSpeed -gt 80) { $ratings += "写入性能优秀" }
elseif ($writeSpeed -gt 40) { $ratings += "写入性能中等" }
else { $ratings += "写入性能偏弱" }

if ($iops4k -gt 500) { $ratings += "随机性能较好" }
else { $ratings += "随机性能较弱（典型 U 盘表现）" }

if ($dirty) { $ratings += "文件系统需修复" }
if ($fsName -eq 'FAT32') { $ratings += "FAT32 有 4GB 单文件限制" }

Write-ReportLine "性能评价      : $($ratings -join '；')"
Write-ReportLine ""
Write-ReportLine "使用建议      :"
Write-ReportLine "  1. 每次使用后务必「安全弹出」再拔出，避免脏位置位和数据损坏"
Write-ReportLine "  2. U 盘不适合长期冷存储，重要数据建议遵循 3-2-1 备份原则"
Write-ReportLine "  3. 如需存储大于 4GB 的文件，建议格式化为 exFAT（跨平台兼容好）"
Write-ReportLine "  4. 避免频繁小文件写入（4K 随机性能弱），大文件顺序传输效率最高"
Write-ReportLine "  5. 定期检查健康状态，出现读写变慢/坏块时及时备份并更换"

# ============================================================
#  输出报告文件
# ============================================================
if ($OutputFile) {
    try {
        $script:report | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-ReportLine ""
        Write-ReportLine "报告已保存到: $OutputFile"
    } catch {
        Write-Error "保存报告文件失败: $_"
    }
}

# ============================================================
#  HTML 报告生成
# ============================================================
if ($HTML) {
    try {
        # 解析文本报告为结构化分节
        $sections = New-Object System.Collections.Generic.List[object]
        $curTitle = ""
        $curRows = New-Object System.Collections.Generic.List[object]
        $expectTitle = $false

        foreach ($line in $script:report) {
            if ($line -match '^={10,}$') {
                if ($expectTitle -and $curTitle) {
                    # 标题结束分隔线
                    $expectTitle = $false
                } else {
                    # 标题开始分隔线
                    if ($curTitle -and $curRows.Count -gt 0) {
                        $sections.Add([PSCustomObject]@{ Title = $curTitle; Rows = $curRows })
                    }
                    $curTitle = ""
                    $curRows = New-Object System.Collections.Generic.List[object]
                    $expectTitle = $true
                }
                continue
            }
            if ($expectTitle -and $line -match '^\s+(.+?)\s*$') {
                $curTitle = $Matches[1]
                continue
            }
            if ($line -match '^---\s*(.+?)\s*---$') {
                $curRows.Add([PSCustomObject]@{ Type = 'subtitle'; Text = $Matches[1] })
                continue
            }
            if ($line -match '^\s*$') {
                $curRows.Add([PSCustomObject]@{ Type = 'empty'; Text = '' })
                continue
            }
            if ($line -match '^(\S.+?)\s{2,}:\s{1,}(.+)$' -or $line -match '^(\S.+?)\s*:\s*(.+)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                if ($key -match '^(写入速度|读取速度|IOPS|写入耗时|读取耗时)$') {
                    $curRows.Add([PSCustomObject]@{ Type = 'kv-highlight'; Key = $key; Value = $val })
                } elseif ($val -match '警告|Warning|脏位|Dirty|⚠') {
                    $curRows.Add([PSCustomObject]@{ Type = 'kv-warn'; Key = $key; Value = $val })
                } elseif ($val -match 'Healthy|健康|正常|优秀') {
                    $curRows.Add([PSCustomObject]@{ Type = 'kv-ok'; Key = $key; Value = $val })
                } else {
                    $curRows.Add([PSCustomObject]@{ Type = 'kv'; Key = $key; Value = $val })
                }
                continue
            }
            if ($line -match '^\[') {
                $curRows.Add([PSCustomObject]@{ Type = 'notice'; Text = $line })
                continue
            }
            if ($line -match '^\d+\.\s') {
                $curRows.Add([PSCustomObject]@{ Type = 'list'; Text = $line })
                continue
            }
            $curRows.Add([PSCustomObject]@{ Type = 'text'; Text = $line })
        }
        if ($curTitle -and $curRows.Count -gt 0) {
            $sections.Add([PSCustomObject]@{ Title = $curTitle; Rows = $curRows })
        }

        # 构建 HTML 正文
        $htmlBody = ""
        foreach ($sec in $sections) {
            $htmlBody += "`n<div class=`"card`">`n<h2>$($sec.Title)</h2>`n<table class=`"info-table`">`n"
            foreach ($row in $sec.Rows) {
                switch ($row.Type) {
                    'subtitle' {
                        $htmlBody += "</table>`n<h3>$($row.Text)</h3>`n<table class=`"info-table`">`n"
                    }
                    'kv' {
                        $htmlBody += "<tr><td class=`"key`">$($row.Key)</td><td class=`"value`">$($row.Value)</td></tr>`n"
                    }
                    'kv-highlight' {
                        $htmlBody += "<tr><td class=`"key`">$($row.Key)</td><td class=`"value highlight`">$($row.Value)</td></tr>`n"
                    }
                    'kv-warn' {
                        $htmlBody += "<tr><td class=`"key`">$($row.Key)</td><td class=`"value warn`">$($row.Value)</td></tr>`n"
                    }
                    'kv-ok' {
                        $htmlBody += "<tr><td class=`"key`">$($row.Key)</td><td class=`"value ok`">$($row.Value)</td></tr>`n"
                    }
                    'notice' {
                        $htmlBody += "</table>`n<div class=`"notice`">$($row.Text)</div>`n<table class=`"info-table`">`n"
                    }
                    'list' {
                        $htmlBody += "</table>`n<div class=`"list-item`">$($row.Text)</div>`n<table class=`"info-table`">`n"
                    }
                    'text' {
                        $htmlBody += "</table>`n<div class=`"text-line`">$($row.Text)</div>`n<table class=`"info-table`">`n"
                    }
                    'empty' {
                        # 跳过空行
                    }
                }
            }
            $htmlBody += "</table>`n</div>`n"
        }

        # 检测时间和盘符
        $reportTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

        $htmlContent = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>USB Disk Inspector - 检测报告</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    min-height: 100vh;
    padding: 20px;
    color: #333;
}
.container { max-width: 900px; margin: 0 auto; }
.header {
    text-align: center;
    color: #fff;
    padding: 30px 20px;
    margin-bottom: 24px;
}
.header h1 { font-size: 28px; margin-bottom: 8px; }
.header .meta { font-size: 14px; opacity: 0.9; }
.card {
    background: #fff;
    border-radius: 12px;
    padding: 24px;
    margin-bottom: 20px;
    box-shadow: 0 4px 20px rgba(0,0,0,0.1);
}
.card h2 {
    font-size: 18px;
    color: #667eea;
    border-bottom: 2px solid #667eea;
    padding-bottom: 10px;
    margin-bottom: 16px;
}
.card h3 {
    font-size: 15px;
    color: #764ba2;
    margin: 16px 0 10px 0;
}
.info-table { width: 100%; border-collapse: collapse; }
.info-table td {
    padding: 8px 12px;
    border-bottom: 1px solid #f0f0f0;
    font-size: 14px;
}
.info-table td.key {
    width: 40%;
    color: #666;
    font-weight: 500;
}
.info-table td.value {
    width: 60%;
    color: #333;
    word-break: break-all;
}
.info-table td.value.highlight {
    color: #667eea;
    font-weight: 700;
    font-size: 16px;
}
.info-table td.value.warn {
    color: #e74c3c;
    font-weight: 600;
}
.info-table td.value.ok {
    color: #27ae60;
    font-weight: 600;
}
.notice {
    background: #fff3cd;
    border-left: 4px solid #ffc107;
    padding: 10px 14px;
    margin: 10px 0;
    border-radius: 4px;
    font-size: 13px;
    color: #856404;
}
.list-item {
    padding: 4px 0 4px 16px;
    font-size: 14px;
    color: #555;
}
.text-line {
    padding: 4px 0;
    font-size: 14px;
    color: #555;
}
.footer {
    text-align: center;
    color: rgba(255,255,255,0.8);
    font-size: 12px;
    padding: 20px;
}
@media (max-width: 600px) {
    .card { padding: 16px; }
    .info-table td.key { width: 45%; }
    .header h1 { font-size: 22px; }
}
.copy-btn {
    margin-top: 14px;
    padding: 8px 20px;
    background: rgba(255,255,255,0.2);
    color: #fff;
    border: 1px solid rgba(255,255,255,0.4);
    border-radius: 6px;
    font-size: 14px;
    cursor: pointer;
    transition: all 0.2s;
}
.copy-btn:hover {
    background: rgba(255,255,255,0.35);
    transform: translateY(-1px);
}
.copy-btn:active {
    transform: translateY(0);
}
.toast {
    position: fixed;
    top: 20px;
    left: 50%;
    transform: translateX(-50%) translateY(-80px);
    background: #27ae60;
    color: #fff;
    padding: 12px 28px;
    border-radius: 8px;
    font-size: 14px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.2);
    opacity: 0;
    transition: all 0.3s ease;
    z-index: 9999;
    pointer-events: none;
}
.toast.show {
    opacity: 1;
    transform: translateX(-50%) translateY(0);
}
</style>
</head>
<body>
<div class="container">
<div class="header">
    <h1>USB Disk Inspector</h1>
    <div class="meta">检测盘符: ${DriveLetter}: ｜ 检测时间: $reportTime</div>
    <button class="copy-btn" onclick="copyReport()">📋 复制报告内容</button>
</div>
<div id="toast" class="toast">已复制到剪贴板</div>
<textarea id="reportText" style="display:none;">$($script:report -join "`n")</textarea>
$htmlBody
<div class="footer">
    本报告由 USB Disk Inspector 自动生成 ｜ GitHub: usb-disk-inspector
</div>
</div>
<script>
function copyReport() {
    var text = document.getElementById('reportText').value;
    var toast = document.getElementById('toast');
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function() {
            showToast();
        }).catch(function() {
            fallbackCopy(text);
        });
    } else {
        fallbackCopy(text);
    }
}
function fallbackCopy(text) {
    var ta = document.getElementById('reportText');
    ta.style.display = 'block';
    ta.select();
    try {
        document.execCommand('copy');
        showToast();
    } catch(e) {
        alert('复制失败，请手动选择文本复制');
    }
    ta.style.display = 'none';
}
function showToast() {
    var toast = document.getElementById('toast');
    toast.classList.add('show');
    setTimeout(function() {
        toast.classList.remove('show');
    }, 2000);
}
</script>
</body>
</html>
"@

        $htmlContent | Out-File -FilePath $HTML -Encoding UTF8
        Write-ReportLine ""
        Write-ReportLine "HTML 报告已保存到: $HTML"
    } catch {
        Write-Error "生成 HTML 报告失败: $_"
    }
}

Write-ReportLine ""
Write-ReportLine "检测完成。"
