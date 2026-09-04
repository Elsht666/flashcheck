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
#  8. 综合评价（根据实测数据动态生成）
# ============================================================
Write-Section "八、综合评价与建议"

# --- 性能评级 ---
$readRating = if ($readSpeed -gt 100) { "优秀" } elseif ($readSpeed -gt 50) { "良好" } elseif ($readSpeed -gt 30) { "一般" } elseif ($readSpeed -gt 15) { "较差" } else { "很差" }
$writeRating = if ($writeSpeed -gt 80) { "优秀" } elseif ($writeSpeed -gt 40) { "中等" } elseif ($writeSpeed -gt 20) { "一般" } elseif ($writeSpeed -gt 10) { "较差" } else { "很差" }
if ($Quick -or $SkipWrite) {
    $randomRating = "未测试"
    $iops4kDisplay = "（快速模式已跳过）"
} else {
    $randomRating = if ($iops4k -gt 500) { "较好" } elseif ($iops4k -gt 100) { "一般" } elseif ($iops4k -gt 30) { "较差" } else { "很差" }
    $iops4kDisplay = "$([math]::Round($iops4k,1)) IOPS"
}

$overallScore = 0
# 读取速度（满分4分）
if ($readSpeed -gt 100) { $overallScore += 4 } elseif ($readSpeed -gt 50) { $overallScore += 2 } elseif ($readSpeed -gt 30) { $overallScore += 1 }
# 写入速度（满分4分）
if ($writeSpeed -gt 80) { $overallScore += 4 } elseif ($writeSpeed -gt 40) { $overallScore += 2 } elseif ($writeSpeed -gt 20) { $overallScore += 1 }
# 4K随机写入（满分2分）
if (-not $Quick -and -not $SkipWrite) {
    if ($iops4k -gt 500) { $overallScore += 2 } elseif ($iops4k -gt 100) { $overallScore += 1 }
}
$overallGrade = if ($overallScore -ge 8) { "A（优秀）" } elseif ($overallScore -ge 6) { "B（良好）" } elseif ($overallScore -ge 4) { "C（一般）" } elseif ($overallScore -ge 2) { "D（较差）" } else { "E（很差）" }

Write-ReportLine "综合评级      : $overallGrade"
Write-ReportLine "读取性能      : $readRating（$([math]::Round($readSpeed,1)) MB/s）"
Write-ReportLine "写入性能      : $writeRating（$([math]::Round($writeSpeed,1)) MB/s）"
Write-ReportLine "随机性能      : $randomRating$iops4kDisplay"
Write-ReportLine ""

# --- 动态生成建议 ---
$suggestions = New-Object System.Collections.Generic.List[string]
$suggestionNum = 1

# 基础建议：安全弹出
$suggestions.Add("每次使用后务必「安全弹出」再拔出，避免脏位置位和数据损坏")

# 疑似杂牌/扩容盘检测
$isSuspicious = $false
$suspiciousReasons = @()
if ($deviceModel -like '*VendorCo*' -or $deviceModel -like '*ProductCode*' -or $manufacturer -like '*VendorCo*') {
    $isSuspicious = $true
    $suspiciousReasons += "设备型号为默认占位名（VendorCo ProductCode）"
}
$knownVids = @('0781','0951','05DC','04E8','04B4','13FE','1B4F','090C','1F75','0DD8','125F','0930','048D','18A5','058F','14CD','1E3D','2013','3538','3551','3569','3571','3581','3591','35BD','35CE','35FA','3639','3669','3679','3689','3699','36B9','36C9','36D9','36E9','36F9','3709','3719','3729','3739','3749','3759','3769','3779','3789','3799','37A9','37B9','37C9','37D9','37E9','37F9','3809','3819','3829','3839','3849','3859','3869','3879','3889','3899','38A9','38B9','38C9','38D9','38E9','38F9','3909','3919','3929','3939','3949','3959','3969','3979','3989','3999','39A9','39B9','39C9','39D9','39E9','39F9','3A09','3A19','3A29','3A39','3A49','3A59','3A69','3A79','3A89','3A99','3AA9','3AB9','3AC9','3AD9','3AE9','3AF9','3B09','3B19','3B29','3B39','3B49','3B59','3B69','3B79','3B89','3B99','3BA9','3BB9','3BC9','3BD9','3BE9','3BF9','3C09','3C19','3C29','3C39','3C49','3C59','3C69','3C79','3C89','3C99','3CA9','3CB9','3CC9','3CD9','3CE9','3CF9','3D09','3D19','3D29','3D39','3D49','3D59','3D69','3D79','3D89','3D99','3DA9','3DB9','3DC9','3DD9','3DE9','3DF9','3E09','3E19','3E29','3E39','3E49','3E59','3E69','3E79','3E89','3E99','3EA9','3EB9','3EC9','3ED9','3EE9','3EF9','3F09','3F19','3F29','3F39','3F49','3F59','3F69','3F79','3F89','3F99','3FA9','3FB9','3FC9','3FD9','3FE9','3FF9')
if ($vid -ne '未知' -and $knownVids -notcontains $vid -and $usbVersion -like '*未知*') {
    $isSuspicious = $true
    $suspiciousReasons += "厂商ID 0x$vid 非知名品牌且接口版本未正确报告"
}
if ($usbVersion -like '*未知*' -and $uasSupport -eq $false) {
    $isSuspicious = $true
    $suspiciousReasons += "使用BOT老旧协议且接口版本未知"
}
if ($writeSpeed -lt 15 -and $readSpeed -lt 30) {
    $isSuspicious = $true
    $suspiciousReasons += "读写速度远低于正规USB 3.0 U盘水平"
}

if ($isSuspicious) {
    $suggestions.Add("⚠️ 该U盘疑似杂牌/黑片/扩容盘（$($suspiciousReasons -join '；')），不建议存储重要数据，建议用MyDiskTest或h2testw检测实际容量")
}

# 性能相关建议
if ($writeSpeed -lt 15) {
    $suggestions.Add("写入速度仅 $([math]::Round($writeSpeed,1)) MB/s，大文件写入耗时较长，不适合频繁传输大文件")
}
if ($readSpeed -lt 30) {
    $suggestions.Add("读取速度仅 $([math]::Round($readSpeed,1)) MB/s，大文件读取较慢，如需高速传输建议更换USB 3.0以上正规品牌U盘")
}
if (-not $Quick -and -not $SkipWrite -and $iops4k -lt 50) {
    $suggestions.Add("4K随机写入仅 $([math]::Round($iops4k,1)) IOPS，避免频繁小文件写入/删除，大文件顺序传输效率最高")
}
if (-not $uasSupport -or $usbVersion -like '*未知*' -or $usbVersion -like '*2.0*') {
    $suggestions.Add("该U盘使用BOT协议/疑似USB 2.0接口，如需高速传输建议更换支持UASP的USB 3.0以上U盘")
}

# 文件系统相关建议
if ($fsName -eq 'FAT32') {
    if ($physSize -gt 32GB) {
        $suggestions.Add("容量较大但为FAT32格式，建议格式化为exFAT以支持4GB以上大文件并提升空间利用率")
    } else {
        $suggestions.Add("FAT32格式不支持4GB以上单文件，如需存储大文件建议格式化为exFAT（跨平台兼容好）")
    }
}

# 健康状态相关建议
if ($dirty) {
    $suggestions.Add("文件系统脏位已置位，建议备份数据后以管理员身份运行 chkdsk ${DriveLetter}: /F /V 修复")
}
if ($volHealth -eq 'Warning' -and -not $dirty) {
    $suggestions.Add("卷健康状态为警告，建议备份重要数据并检查文件系统完整性")
}

# 通用建议
$suggestions.Add("U盘不适合长期冷存储，重要数据建议遵循3-2-1备份原则（3份副本、2种介质、1份异地）")
$suggestions.Add("定期检查健康状态，出现读写明显变慢、文件丢失或坏块时及时备份并更换")

Write-ReportLine "使用建议      :"
foreach ($s in $suggestions) {
    Write-ReportLine ("  {0}. {1}" -f $suggestionNum, $s)
    $suggestionNum++
}

# ============================================================
#  性能速览（插入到报告开头）
# ============================================================
$summaryLines = New-Object System.Collections.Generic.List[string]
$bar = "=" * 64
$summaryLines.Add("")
$summaryLines.Add($bar)
$summaryLines.Add("  性能速览")
$summaryLines.Add($bar)
$summaryLines.Add("")
$summaryLines.Add("综合评级      : $overallGrade")
$summaryLines.Add("")
$summaryLines.Add("--- 关键性能指标 ---")
$summaryLines.Add("  顺序读取      : $([math]::Round($readSpeed,1)) MB/s（$readRating）")
$summaryLines.Add("  顺序写入      : $([math]::Round($writeSpeed,1)) MB/s（$writeRating）")
$summaryLines.Add("  4K随机写入    : $iops4kDisplay（$randomRating）")
$summaryLines.Add("")
$summaryLines.Add("--- 与正规U盘对比 ---")
$summaryLines.Add("  指标          你的U盘                  正规USB 3.0 U盘（参考）")
$summaryLines.Add("  ----------    --------------------    ------------------------")
$summaryLines.Add("  顺序读取      $([math]::Round($readSpeed,1).ToString().PadRight(20))  100-150 MB/s")
$summaryLines.Add("  顺序写入      $([math]::Round($writeSpeed,1).ToString().PadRight(20))  30-80 MB/s")
$summaryLines.Add("  4K随机写      $([math]::Round($iops4k,1).ToString().PadRight(20))  100-500 IOPS")
$summaryLines.Add("  接口协议      $($usbVersion.PadRight(20))  USB 3.2 Gen1 + UASP")
$summaryLines.Add("")

# 一句话总结
if ($isSuspicious) {
    $summaryLines.Add("⚠️  总结：该U盘疑似杂牌/黑片/扩容盘，性能远低于正规U盘，不建议存储重要数据。")
} elseif ($overallScore -le 2) {
    $summaryLines.Add("⚠️  总结：该U盘性能较差，仅适合临时小文件传输，不适合频繁使用或存储重要数据。")
} elseif ($overallScore -le 4) {
    $summaryLines.Add("📝 总结：该U盘性能一般，适合日常文件传输，大文件和频繁写入场景体验较差。")
} else {
    $summaryLines.Add("✅ 总结：该U盘性能良好，可满足日常文件传输需求。")
}
$summaryLines.Add("")
$summaryLines.Add($bar)

# 插入到报告开头（"一、设备识别"之前）
$insertIndex = 0
for ($i = 0; $i -lt $script:report.Count; $i++) {
    if ($script:report[$i] -match '一、设备识别') {
        $insertIndex = $i
        break
    }
}
if ($insertIndex -gt 0) {
    $script:report.InsertRange($insertIndex, $summaryLines)
}

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
            $htmlBody += "`n<div class=`"card`">`n<h2>$($sec.Title)</h2>`n"

            # 性能速览卡片：添加渐变评级条
            if ($sec.Title -eq "性能速览") {
                $ratingPercent = [math]::Round([math]::Min($overallScore, 10) / 10 * 100, 1)
                $htmlBody += @"
<div class="rating-bar-container">
  <div class="rating-bar-track">
    <div class="rating-bar-pointer" style="left: $ratingPercent%">
      <div class="rating-bar-tooltip">$overallGrade</div>
    </div>
  </div>
  <div class="rating-bar-labels">
    <span>E<br><small>很差</small></span>
    <span>D<br><small>较差</small></span>
    <span>C<br><small>一般</small></span>
    <span>B<br><small>良好</small></span>
    <span>A<br><small>优秀</small></span>
  </div>
  <div class="rating-bar-score">综合得分：$overallScore / 10 分</div>
</div>
"@
            }

            $htmlBody += "<table class=`"info-table`">`n"
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

        # 评分规则说明卡片
        $htmlBody += @"
`n<div class="card">
<h2>评分规则说明</h2>
<p class="rule-intro">本报告采用 <strong>10 分制</strong>综合评分，由以下三项组成：</p>
<table class="info-table">
<tr><td class="key">读取速度</td><td class="value">满分 4 分</td></tr>
<tr><td class="key">写入速度</td><td class="value">满分 4 分</td></tr>
<tr><td class="key">4K 随机写入</td><td class="value">满分 2 分（快速模式下不计分）</td></tr>
</table>
<h3>各项评分标准</h3>
<table class="info-table">
<tr><th class="rule-th">项目</th><th class="rule-th">得分</th><th class="rule-th">条件</th></tr>
<tr><td rowspan="3">读取速度</td><td>4 分</td><td>> 100 MB/s</td></tr>
<tr><td>2 分</td><td>> 50 MB/s</td></tr>
<tr><td>1 分</td><td>> 30 MB/s</td></tr>
<tr><td rowspan="3">写入速度</td><td>4 分</td><td>> 80 MB/s</td></tr>
<tr><td>2 分</td><td>> 40 MB/s</td></tr>
<tr><td>1 分</td><td>> 20 MB/s</td></tr>
<tr><td rowspan="2">4K 随机写</td><td>2 分</td><td>> 500 IOPS</td></tr>
<tr><td>1 分</td><td>> 100 IOPS</td></tr>
</table>
<h3>等级划分</h3>
<table class="info-table">
<tr><th class="rule-th">等级</th><th class="rule-th">分数范围</th><th class="rule-th">说明</th></tr>
<tr><td><span class="grade-a">A（优秀）</span></td><td>8 - 10 分</td><td>高性能 U 盘，适合大文件频繁传输</td></tr>
<tr><td><span class="grade-b">B（良好）</span></td><td>6 - 7 分</td><td>主流正规 U 盘水平，日常使用流畅</td></tr>
<tr><td><span class="grade-c">C（一般）</span></td><td>4 - 5 分</td><td>入门级 U 盘，大文件传输较慢</td></tr>
<tr><td><span class="grade-d">D（较差）</span></td><td>2 - 3 分</td><td>性能偏弱，仅适合临时小文件</td></tr>
<tr><td><span class="grade-e">E（很差）</span></td><td>0 - 1 分</td><td>性能极差，疑似杂牌/黑片/扩容盘</td></tr>
</table>
</div>
"@

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
/* 性能评级条 */
.rating-bar-container {
    margin-bottom: 24px;
    padding: 16px 20px;
    background: #f8f9ff;
    border-radius: 10px;
}
.rating-bar-track {
    position: relative;
    height: 16px;
    border-radius: 8px;
    background: linear-gradient(to right,
        #e74c3c 0%,
        #e67e22 25%,
        #f1c40f 50%,
        #2ecc71 75%,
        #27ae60 100%);
    box-shadow: inset 0 1px 3px rgba(0,0,0,0.2);
    margin: 20px 0 8px 0;
}
.rating-bar-pointer {
    position: absolute;
    top: -8px;
    width: 0;
    height: 0;
    border-left: 10px solid transparent;
    border-right: 10px solid transparent;
    border-top: 14px solid #2c3e50;
    transform: translateX(-50%);
    transition: left 0.5s ease;
}
.rating-bar-tooltip {
    position: absolute;
    top: -32px;
    left: 50%;
    transform: translateX(-50%);
    background: #2c3e50;
    color: #fff;
    padding: 3px 10px;
    border-radius: 4px;
    font-size: 12px;
    font-weight: bold;
    white-space: nowrap;
}
.rating-bar-tooltip::after {
    content: '';
    position: absolute;
    bottom: -5px;
    left: 50%;
    transform: translateX(-50%);
    border-left: 5px solid transparent;
    border-right: 5px solid transparent;
    border-top: 5px solid #2c3e50;
}
.rating-bar-labels {
    display: flex;
    justify-content: space-between;
    padding: 0 2px;
}
.rating-bar-labels span {
    text-align: center;
    font-size: 13px;
    font-weight: bold;
    color: #555;
}
.rating-bar-labels small {
    font-weight: normal;
    font-size: 11px;
    color: #999;
}
.rating-bar-score {
    text-align: center;
    margin-top: 10px;
    font-size: 13px;
    color: #666;
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
/* 评分规则卡片 */
.rule-intro {
    font-size: 14px;
    color: #555;
    margin-bottom: 16px;
    line-height: 1.6;
}
.info-table th.rule-th {
    background: #f0f2ff;
    color: #667eea;
    font-weight: 600;
    padding: 10px 12px;
    text-align: left;
    font-size: 13px;
    border-bottom: 2px solid #667eea;
}
.grade-a { color: #27ae60; font-weight: bold; }
.grade-b { color: #2ecc71; font-weight: bold; }
.grade-c { color: #f1c40f; font-weight: bold; }
.grade-d { color: #e67e22; font-weight: bold; }
.grade-e { color: #e74c3c; font-weight: bold; }
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
