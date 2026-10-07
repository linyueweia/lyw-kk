# lyw-kk — iNextOS for KICKPI K1 (Rockchip RK3568)

为 **KICKPI K1（RK3568B2，硬件版本 V1.2）** 适配的 iNextOS / Armbian 镜像构建仓库。

> 板子对外型号是 **K1**；厂商固件里的设备树标为 `rockchip,rk3568-kickpi-k1a`
> （"K1A" 是厂商内部的版本代号，官方产品线只有 K1 / K1B / K1 MINI）。

## 硬件（实测自本机运行中的设备树 + 内核）

| 项目 | 实测值 |
|---|---|
| SoC | Rockchip RK3568B2 |
| 内存 / eMMC | 4GB LPDDR4 / 64GB eMMC（可用 58.2G） |
| 有线网 | **2× 千兆**：gmac0@fe2a0000、gmac1@fe010000 |
| **PHY** | **Maxio MAE0621A-Q2C**（PHY ID `0x7b744411`）+ Q3C（`0x7b744412`） |
| 无线 | SDIO WiFi + BT（AIC8800 / SWT6621S 视版本） |
| 存储扩展 | M.2 NVMe（PCIe3x2） |
| PMIC | RK809 + fan53555(vdd_cpu) |
| 其它 | 控制台 ttyS2/0xfe660000@1500000、gpio-fan、adc-keys、HDMI/VOP、NPU |

## 关键点：两个千兆口必须编译 Maxio 树外驱动

K1 的网口 PHY 是 **Maxio MAE0621A**，**不在上游内核里**，必须打补丁启用
`CONFIG_MAXIO_PHY`，否则两个网口全部不通，且 DWMAC 会报
`DMA engine initialization failed`。

参考：`armbian/linux-rockchip` issue #471 —— 维护者原话
*"I actually was trapped by maxio phy.... One does need an out of tree driver for that"*。

本仓库的做法：

- `patch/kernel/rk35xx-vendor-6.1/general-drv-net-phy-maxio-mae0621a.patch`
  —— 移植自 `armbian/build` 的 `archive/rockchip64-7.3` 版本，**已针对
  `rk-6.1-rkr5.1` 厂商树重新锚定 `stmmac_resume` 那段 hunk**
  （厂商树用的是 `stmmac_hw_setup(ndev, false)` 两参数形式）；
  补丁已在本机拉取的厂商内核源码上做完 **dry-run + 实打验证**。
- `extensions/kickpi-k1-maxio.sh` —— 用框架的 `custom_kernel_config` 钩子
  写入 `opts_y+=("MAXIO_PHY")`，并在内核树里自检 Kconfig 项存在。
- CI 的 `Verify image` 步骤会**在编出来的镜像里**断言 `CONFIG_MAXIO_PHY=y`
  以及两个 GMAC 的状态，避免"配置里有但镜像里没有"。

## 树外驱动之二：SWT6621S SDIO WiFi + 蓝牙

实机 SDIO 器件 `mmc3:0001:1` = vendor `0x1ffe` / device `0x6621`（**Seekwave SWT6621S**），
实机加载的正是 `swt6621s_wifi` / `skw_sdio_lite` / `skwbt` 三个**树外**模块，
内核里**没有任何** SWT/SKW 配置项 —— 与 Maxio PHY 同性质，必须自行接入。
（armbian 框架默认开的 `AIC8800_WLAN_SUPPORT` 对这块板**无用**。）

做法：
- `patch/kernel/rk35xx-vendor-6.1/swt6621s-wifi-bt-driver.patch`
  —— 驱动源码取自 `retro98boy/seekwave-swt6621s @ b1b1501`，装入
  `drivers/net/wireless/seekwave/`，并挂好 `drivers/net/wireless/{Kconfig,Makefile}`；
  已用 `patch -p1 --dry-run` + 实际应用双重复核（110 个文件，0 失败）。
- `extensions/kickpi-k1-wifi.sh` —— 用 `custom_kernel_config` 钩子打开
  `SEEKWAVE_BSP_DRIVERS` / `SKW_SDIOHAL` / `WLAN_VENDOR_SWT6621S` / `SKW_BT`，
  并自检驱动确实已进入内核树。
- `firmware/SWT6621S_*`（15 个文件）—— **取自实机 v1.2 原厂系统**，
  经 `userpatches/overlay/lib/firmware/` 随镜像安装。

## SATA / USB3 / 4G-5G 的落地方式（无需额外补丁）

| 项目 | 依据 |
|---|---|
| **SATA** | 实机 `ata1` 控制器在线；框架内核已含 `SATA_AHCI_PLATFORM=y` + `AHCI_DWC=m`；DTS 里 3 个 sata 节点已转写。**仅作数据口**，不参与启动（系统从 SD/eMMC 起） |
| **USB3** | `USB_DWC3=y` + `PHY_ROCKCHIP_INNO_USB3=y` + `NANENG_COMBO_PHY=y` 均在位；DTS 的 `&usbdrd30`/`&usbhost30` 含 dwc3 子节点（`phy-names = "usb2-phy\0usb3-phy"`） |
| **4G/5G** | 框架内核已含 `USB_SERIAL_OPTION=m` `USB_SERIAL_QUALCOMM=m` `USB_NET_QMI_WWAN=m` `USB_NET_CDC_MBIM=m` `USB_ACM=y`；DTS 已含 4 个 USB2 口与 `vcc5v0_host`(PE6)/`vcc5v0_otg`(PE5) 供电（实机当前未插模块） |

## 仓库结构

```
config/boards/kickpi-k1.csc                                      板级配置
patch/kernel/rk35xx-vendor-6.1/dt/rk3568-kickpi-k1.dts            板级设备树
patch/kernel/rk35xx-vendor-6.1/general-drv-net-phy-maxio-*.patch  Maxio PHY 驱动
extensions/kickpi-k1-maxio.sh                                     打开 CONFIG_MAXIO_PHY
.github/workflows/build.yml                                       CI（含构建期自证）
```


## 本机实测的启动链 / 分区 / DDR（全部来自对这块板子的直接取证）

### 厂商分区布局（GPT，Rockchip Android 式，非常规 Linux 布局）

```
mmcblk0 (58.2G) 分区名(PARTLABEL)：
  p1   4M    uboot      前 16 字节 d00d feed...  ← Rockchip 引导器格式，U-Boot 在这
  p2   4M    misc       全零
  p3  64M    boot       d00d feed...            ← RK boot 镜像
  p4 128M    recovery   d00d feed...
  p5  32M    backup     全零
  p6  58G    rootfs     ext4 ← 当前根
  boot0/boot1：各 4M，全零（厂商引导器不在 eMMC boot 分区里）
cmdline：storagemedia=emmc  root=PARTUUID=614e0000-0000   ← RK 专有约定
```

### 启动链（从 eMMC `uboot` 分区里读出的厂商 U-Boot 环境）

```
U-Boot 2017.09 (Dec 09 2025)   board=evb_rk3568   bl31-v1.44
kickpi,cmd-uboot                     ← KICKPI 确实改过 U-Boot
LBA64: "RKNS"                        ← BootROM 读取的 idblock
boot_targets=mmc1 mmc0 mtd2 mtd1 mtd0 usb0 pxe dhcp
rkimg_bootdev=if mmc dev 1 && rkimgtest mmc 1; then ... Boot from SDcard;
              elif mmc dev 0; then ...          ← mmc1=SD 卡，优先于 mmc0=eMMC
"Found IDB in SDcard" / "Rockchip SD Boot Image"
```

**链路**：BootROM → eMMC LBA64 的 idbloader(`RKNS`) → `uboot` 分区里的厂商 U-Boot
→ 该 U-Boot 的 `rkimg_bootdev` **先探 SD 卡**（`mmc 1`）→ 所以**SD 卡启动这条路线是通的** ✓
（这也是 T68M 当年 TF 卡能启动的同一机制）。

### DDR

- 类型/频率：**LPDDR4 @ 1560MHz**（`/proc/device-tree/lpddr4-params` 的 `freq_0 = 0x618 = 1560`）
- → 框架对 rk3568 的默认 `rk35/rk3568_ddr_1560MHz_v1.21.bin` **正好匹配，不做任何替换**；
  且框架的 `rk3568_bl31_v1.44.elf` 与厂商引导器里的 `bl31-v1.44` **完全一致**。
- （T68M 当年需要换 1056MHz v1.23 是因为 T68M 的 DDR 训练过不了 1560，**那属于 T68M 的个体问题，
  不能照搬到 K1** —— 本仓库已删除该替换。）

### 没有 SPI NOR

`/proc/mtd` 无设备、dmesg 无 spi-nor → **本板无 SPI 闪存**，
故**不设** `BOOT_SUPPORT_SPI`（设了会让框架去生成 SPI loader，并因缺少
`spl-blobs` 场景下不存在的 `tpl/u-boot-tpl.bin` 而构建失败 —— 已实际踩过）。

## 构建

推送到 `main` 即触发；或在 Actions 页面手动 `workflow_dispatch`。
产物：`inextos-kickpi-k1` artifact（`.img` + `.img.xz` + `.sha`）。

框架：`jjm2473/armbian-easepi` @ `easepi-v26.02`，内核
`armbian/linux-rockchip` @ `rk-6.1-rkr5.1`，分支 `vendor`，发行版 `trixie`。

## 刷写（SD 卡，不碰 eMMC）

首次验证走 **SD 卡启动**：把 `.img.xz` 解压后写入 SD 卡（用 balenaEtcher，
或 `xz -dc <镜像> | sudo tee <SD卡设备>` 一类方式），插卡上电即可，
eMMC 里的原厂系统保持不动；验证通过后再讨论是否刷入 eMMC。
