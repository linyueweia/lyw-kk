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
| 无线 | SDIO WiFi + BT（AIC8800 / SWT6621S 视版本）；**本仓未支持**，见下方说明 |
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
- `extensions/kickpi-k1-maxio.sh` —— 用框架的 `custom_kernel_config` 钩子把
  **`MAXIO_PHY` 与 MAC 侧（`STMMAC_ETH`/`STMMAC_PLATFORM`/`DWMAC_ROCKCHIP`）都编成
  模块（`opts_m`）**，并在内核树里自检 Kconfig 项与模块名。
- CI 的 `Verify image` 步骤会**在编出来的镜像里**断言 `CONFIG_MAXIO_PHY=m`、
  模块名与三个 MAC 符号、`maxio.ko` 实际落在 rootfs，避免"配置里有但镜像里没有"。

### 为什么是模块（=m）而不是内建（=y）—— 在线更新安全

本板只有这两个网口做管理面，一旦驱动在升级中丢失，设备就只剩"拔卡救"。

- **内建（=y）是个死结**：`apt` 一升级内核，Image 连同驱动一起被换掉，
  而内建驱动既不能重新装载、也不能事后重建 —— 没有任何补救路径。
- **模块（=m）才有自愈链**（`extensions/kickpi-k1-module-selfheal.sh`）：
  树外源码随镜像 → DKMS 注册 → `/etc/kernel/postinst.d` 钩子对新内核重编 →
  开机自愈单元按 `uname -r` 补编后加载 → `/etc/modprobe.d` 的 `softdep` 保证
  maxio 先于 MAC 驱动注册（否则 PHY 会被通用驱动抢绑，`lyw-kf` 实测坑④）。
- 方案与实证来自同板同芯片的 **lyw-kf（飞牛线）**：2026-10-12 走官方在线更新装上
  新内核（c951→c1145），钩子自动编出 `maxio.ko`，**15 秒后双网口恢复**，全程无人干预。
- **刻意不钉死内核**：不做 `apt-mark hold`、不写 `apt preferences -1`。
  在线更新照常升，网口靠模块自愈回来；配套的 `extensions/kickpi-k1-update-guard.sh`
  负责"更新后自动体检"与"引导快照兜底回滚"，不是禁止更新。
- 开机路径零负担：自愈单元正常启动只做几次文件存在判断（毫秒级），
  **只有 maxio 缺失时才现编**；没有本内核 headers 时写标记，不会每开机白试一遍。

### 第二网口（eth1/fe2a0000）整口不可用的真因：PHY 复位脚写错（2026-10-14 串口实机定案）

串口日志的铁证：`mdio_bus stmmac-0: MDIO device at address 2/1/0 is missing.`（三个地址全无应答）
→ `rk_gmac-dwmac fe2a0000.ethernet eth1: __stmmac_open: Cannot attach to PHY (error: -19)`
→ 该口整口不可用；而 eth0(fe010000) 正常 `PHY [stmmac-1:00] driver [MAE0621A-Q2C]`。

把本仓 DTB 与**同板双口可用的飞牛线 DTB** 逐属性对照，差异只有一处：

| 节点 | 飞牛线（可用） | 本仓原值 |
|---|---|---|
| `ethernet@fe2a0000` | `/pinctrl/gpio@fe750000`（gpio2） **pin 27** | `/pinctrl/gpio@fe760000`（gpio3） pin 11 ❌ |
| `ethernet@fe010000` | `gpio@fe760000`（gpio3） pin 7 | 同左 ✅ |

即：第二 PHY 的复位脚被写到了**另一个控制器与引脚**上 → PHY 一直被按在复位里 → MDIO 不应答。
`&gmac0` 里那行**注释写的是 `fe750000 pin 0x1b`（正确值），代码却是 `&gpio3 RK_PB3`**——
注释与代码自相矛盾，是这次排障最耗时的干扰项；台账教训：注释里的寄存器/引脚值必须能被
门禁验证，否则就是误导。现已在 `tools/verify-image.sh` 加**复位脚门禁**（解析 DTB 的
`snps,reset-gpio` 并解析 phandle 到控制器，两个口都断言到实机定案值）。

### 网口 EEE：1G 在内核层关闭（`eee-broken-1000t`，2026-10-17 实机定案）

2026-10-13 曾用五层用户态件关 EEE；2026-10-17 上午先按"官方默认保持开启"撤掉，结果**当天就把自己打掉线了**：

- 现象：K1（fnOS，Maxio MAE0621A）与 T68M 主路由（RTL8211F）协商到 EEE 后，**灯亮、能发不能收** ——
  板上 ARP/DHCP 一直往外发，却收不到任何回应，ping 100% 丢包；链路 `carrier` 始终为 1，`carrier_changes` 不涨。
- 计数器（K1 侧 `ethtool -S end1`）：`irq_rx_path_in_lpi_mode_n = 14,222,411`（RX 侧在 LPI 里疯狂进出）、
  `phy_eee_wakeup_error_n = 241`；对端 T68M 的 `eth1` 同一时段也在涨。
- 对端 `ethtool --set-eee eth1 eee off` + 重协商 → **立刻恢复 0% 丢包、RTT 0.6ms**；K1 侧再关一次，双端都干净。

⇒ 决定性做法：**在 DT 的 PHY 节点写 `eee-broken-1000t`**（内核 `of_set_phy_eee_broken()` 会在每次自协商
清掉 1000T 的 EEE 通告位），只关 1G EEE、100M 保持默认，**不需要任何用户态脚本**；
CI 里对本仓 DTS 做硬断言（两个 PHY 节点都必须有、`phy-mode=rgmii` 且延迟值精确）。
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

### DDR —— 必须换成真机 eMMC 原厂同款（2026-10-12 定案，此前"不替换"是错的）

- 内存频率：**LPDDR4 @ 1560MHz**（`freq_0 = 0x618 = 1560`）——但这**不是**选 DDR 固件的依据。
- **真机原厂指纹才是金标准**：K1 eMMC 原厂 idbloader 的 DDR 固件 = `ddr-v1.23-03ea844c5d`
  （本机实测提取，与飞牛基镜像同哈希，飞牛线全部成功启动用的就是它）；
  该指纹对应 rkbin 的 **`rk3568_ddr_1056MHz_v1.23.bin`**（lyw-OS 侧 sha256 逐字节比对过）。
- **框架默认 `rk3568_ddr_1560MHz_v1.21.bin` 在本板不可信**：同方案 T68M 上 v1.21 训练失败
  （上电全无输出）；K1 飞牛线另一份 1560 系列（v1.26）SPL 阶段即断（电源灯亮系统灯不亮）。
  文件名频率 ≠ 可用判据。
- 本仓库因此与 lyw-OS 对齐：构建前 `sed` 替换为 `rk3568_ddr_1056MHz_v1.23.bin`，
  构建后 `verify-image.sh (0)` 回读断言**必须命中 `03ea844c5d` 指纹**
  （同时拒绝 T68M V1.18 `f366f69a7d` 与未实测的 `v1.21`）。
- BL31 不变：框架 `rk3568_bl31_v1.44.elf` 与厂商引导器 `bl31-v1.44` 一致 ✓。

### 没有 SPI NOR

`/proc/mtd` 无设备、dmesg 无 spi-nor → **本板无 SPI 闪存**，
故**不设** `BOOT_SUPPORT_SPI`（设了会让框架去生成 SPI loader，并因缺少
`spl-blobs` 场景下不存在的 `tpl/u-boot-tpl.bin` 而构建失败 —— 已实际踩过）。

## 关机断电（vendor 属性名，2026-10-22）

`&rk809 { rockchip,system-power-controller; }` —— **必须带 `rockchip,` 前缀**。

- vendor 6.1 的 `drivers/mfd/rk808.c` 只认这一个名字，`of_property_read_bool(np, "rockchip,system-power-controller")`；主线写法无前缀 `system-power-controller;` （immortalwrt 风格板级 DTS 常见）在 vendor 树里不命中。
- 后果不是报错，而是**没有关机句柄**：`poweroff` 退化成 halt，PMIC 不停机 → 整板仍带电（风扇照转、网口灯亮、SoC 空转）。同一块 T68M 实测对照：iStoreOS（6.12 主线）关机风扇停，本镜像（6.1 vendor）关机风扇不停。
- 验证：`dtc -I dtb -O dts /boot/dtb/rockchip/rk3568-kickpi-k1.dtb | grep -n "^\s*rockchip,system-power-controller;"`；判据是**锚行首**，裸 grep 会被长名里的短名命中。
- 门禁：`tools/verify-image.sh` 在反解的产物 DTB 上断言 vendor 名存在、无前缀写法不存在（两条同时生效）。

## roceos 版本口径（2026-10-31，四仓统一）

- 镜像内置 roceos = 官方在线通道最新版 **3.0.2**（`channel=stable_arm`、`arch=arm64`）。
- 官方更新地址（从 roceos 二进制里取的常量，非文档抄录）：
  `http://update.roceos.com:14380/api/v1/updates/check?version=<当前>&channel=stable_arm&arch=arm64`
- 版本记录在 `official-roceos.txt`；由 `.github/workflows/build.yml` 的 `roceos` job 每天 03:00 CST
  核对并**自动跟版**（重建载荷 → 发本仓 release → 改三处 pin → 推送；同一次 run 的 build 直接接着编）。
  自查：`python3 tools/check-roceos.py --pinned official-roceos.txt`。
- 载荷 = `roceos-payload-v2`（**本仓 release**，跟版时自动重发），sha256 `cbd911c6…39dd48`；
  取件/打包/判据见 lyw-rr 与 lyw-hh 的 docs「roceos 载荷怎么跟官方版本」（四仓同一套）。

## 构建

推送到 `main` 即触发；或在 Actions 页面手动 `workflow_dispatch`。
产物：`inextos-kickpi-k1` artifact（`.img` + `.img.xz` + `.sha`）。

框架：`jjm2473/armbian-easepi` @ `easepi-v26.02`，内核
`armbian/linux-rockchip` @ `rk-6.1-rkr5.1`，分支 `vendor`，发行版 `trixie`。

## 刷写（SD 卡，不碰 eMMC）

首次验证走 **SD 卡启动**：把 `.img.xz` 解压后写入 SD 卡（用 balenaEtcher，
或 `xz -dc <镜像> | sudo tee <SD卡设备>` 一类方式），插卡上电即可，
eMMC 里的原厂系统保持不动；验证通过后再讨论是否刷入 eMMC。
