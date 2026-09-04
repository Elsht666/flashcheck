# USB Disk Inspector

🔧 **U 盘硬件信息与性能自动检测脚本** — 一键查询接口协议、读写性能、闪存颗粒、容量、文件系统、健康状态。

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 在线预览报告

👉 [打开可视化样例报告](https://Elsht666.github.io/flashcheck/examples/sample-report.html)


## ✨ 功能特性

| 检测维度 | 具体内容 |
|---|---|
| **设备识别** | 型号、厂商、VID/PID、序列号、固件版本、产品系列推断 |
| **接口协议** | USB 版本、UASP/BOT 协议、USB 控制器、连接端口、设备类代码 |
| **读写性能** | 顺序写入（强制落盘）、无缓存顺序读取（FILE_FLAG_NO_BUFFERING）、4K 随机写入 IOPS |
| **闪存颗粒** | 主控推断、颗粒类型推断、精确识别建议 |
| **容量** | 物理总容量、卷容量、已用/空闲、扇区大小、标称容量推断 |
| **文件系统** | 格式、分区表、簇大小、卷序列号、脏位检测、文件系统特性 |
| **寿命与稳定性** | 健康状态、SMART 支持、脏位检测、可靠性计数器、综合评价与建议 |

### 性能测试特点

- **无缓存读取**：通过 P/Invoke 调用 `CreateFile` 并指定 `FILE_FLAG_NO_BUFFERING`，彻底绕过 Windows 文件系统缓存，测得真实磁盘读取速度
- **强制落盘写入**：使用 `FlushFileBuffers` 确保数据写入物理介质后再计时
- **随机数据**：使用加密级随机数生成器填充测试数据，避免可压缩数据导致速度虚高
- **自动适配**：FAT32 自动限制 4GB 单文件，空间不足自动调整测试大小

---

## 📋 系统要求

- **操作系统**：Windows 10 / Windows 11（推荐）
- **PowerShell**：5.1 或更高版本（PowerShell 7+ 也支持）
- **权限**：普通用户即可运行（性能测试写入 U 盘临时文件，测试后自动清理）
- **.NET Framework**：4.5 或更高（系统默认自带）

---

## 🚀 快速开始

### 1. 下载脚本

```bash
git clone https://github.com/yourname/usb-disk-inspector.git
cd usb-disk-inspector
```

或直接下载 `USB-Disk-Inspector.ps1` 到本地。

### 2. 允许脚本执行（首次使用）

以管理员身份打开 PowerShell，执行：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. 运行检测

#### 方式一：双击运行（推荐，零命令行）

直接双击 `run.bat`，按提示输入盘符（或直接回车自动检测第一个 U 盘），检测完成后会自动弹出浏览器显示美化的 HTML 报告。

也可以命令行指定盘符：`run.bat D`

#### 方式二：PowerShell 命令行

```powershell
# 检测 D 盘（默认 1GB 测试文件）
.\USB-Disk-Inspector.ps1 -DriveLetter D

# 检测 E 盘，使用 2GB 测试文件，保存文本报告
.\USB-Disk-Inspector.ps1 -DriveLetter E -TestSizeMB 2048 -OutputFile report.txt

# 生成美化的 HTML 报告（浏览器打开）
.\USB-Disk-Inspector.ps1 -DriveLetter D -HTML report.html

# 快速模式（跳过 4K 随机写入测试）
.\USB-Disk-Inspector.ps1 -DriveLetter D -Quick

# 只读模式（不写入任何测试文件，仅读取设备信息）
.\USB-Disk-Inspector.ps1 -DriveLetter D -SkipWrite
```

---

## ⚙️ 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `-DriveLetter` | string | **必填** | 要检测的盘符，如 `D` 或 `D:` |
| `-TestSizeMB` | int | `1024` | 顺序读写测试文件大小（MB）。FAT32 自动限制为 4095MB |
| `-OutputFile` | string | （无） | 报告输出文件路径。不指定则仅输出到控制台 |
| `-Quick` | switch | `$false` | 快速模式，跳过 4K 随机写入测试 |
| `-SkipWrite` | switch | `$false` | 只读模式，跳过所有写入测试 |
| `-NoCleanup` | switch | `$false` | 保留测试临时文件（用于调试） |
| `-HTML` | string | （无） | 生成美化的 HTML 报告文件路径，可用浏览器打开 |

---

## 📊 输出示例

```
==============================================================
  一、设备识别
==============================================================
设备型号      : USB SanDisk 3.2Gen1
厂商          : USB
序列号        : 03021330102225062344
固件版本      : 1.00
磁盘编号      : PHYSICALDRIVE1
分区表样式    : MBR
USB VID       : 0x0781
USB PID       : 0x55AD
产品系列推断  : SanDisk Ultra Flair (SDCZ73) 系列（推断）

==============================================================
  二、接口协议
==============================================================
总线类型      : USB
接口标准      : USB 3.2 Gen 1 (原 USB 3.0, 理论 5Gbps)
传输协议      : UASP (USB Attached SCSI Protocol)
...

==============================================================
  六、读写性能测试
==============================================================
--- 顺序写入测试 ---
  写入耗时    : 32.37 秒
  写入速度    : 63.26 MB/s
--- 顺序读取测试（无缓存 I/O）---
  读取耗时    : 13.39 秒
  读取速度    : 153.01 MB/s
--- 4K 随机写入测试（1000 x 4KB 文件）---
  IOPS        : 149.66
  写入速度    : 0.58 MB/s
```

完整文本示例请查看 [examples/sample-report.txt](examples/sample-report.txt)，HTML 美化报告示例请查看 [examples/sample-report.html](examples/sample-report.html)（用浏览器打开）。

---

## ❓ 常见问题

### Q: 为什么读取速度比 CrystalDiskMark 低/高？
A: 本脚本使用 1MB 块大小的纯顺序读取，且完全绕过系统缓存。CrystalDiskMark 默认使用 128KB 块和队列深度 32，测试条件不同。本脚本更贴近大文件实际拷贝场景。

### Q: 为什么无法读取闪存颗粒型号？
A: SanDisk、Kingston 等品牌 U 盘普遍采用自研主控并加密固件，Windows 内置接口不暴露颗粒信息。需拆机查看丝印或使用 ChipGenius 等专用工具。

### Q: 检测到脏位（Dirty Bit）怎么办？
A: 脏位置位通常是因为未安全弹出就拔出。备份数据后，以管理员身份运行 `chkdsk D: /F /V` 即可修复。

### Q: 可以检测移动硬盘吗？
A: 可以。脚本会检测到非可移动磁盘时给出警告，但大部分检测项仍适用。对于 NVMe/SATA SSD，建议使用 CrystalDiskInfo 等专业工具获取 SMART 信息。

### Q: 支持手机端检测吗？
A: 当前版本仅支持 Windows 电脑端。原因如下：
- **读写速度测试**需要直接访问本地文件系统，手机浏览器（WebUSB）无法做到
- **iOS** 对 USB 存储设备限制严格，普通 App 无法读取底层硬件信息
- **Android** 理论上可以通过 OTG + 专用 App 实现，但需要单独开发原生应用

未来可能考虑推出 Android 版本，但目前专注于把 Windows 电脑端的检测精度和体验做好。

### Q: 测试会损坏我的数据吗？
A: 不会。性能测试仅在 U 盘根目录创建临时文件（`__usbinspect_tmp.bin` 和 `__usbinspect_4k` 文件夹），测试完成后自动删除，不会触碰现有文件。

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

---

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。

---

## ⚠️ 免责声明

- 本脚本仅用于硬件信息检测和性能测试，不对任何数据丢失负责
- 性能测试会向 U 盘写入临时数据，虽然会自动清理，但建议在测试前备份重要数据
- 产品系列推断基于 VID/PID 和设备名称，仅供参考，不保证 100% 准确
