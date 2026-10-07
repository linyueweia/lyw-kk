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

## 仓库结构

```
config/boards/kickpi-k1.csc                                      板级配置
patch/kernel/rk35xx-vendor-6.1/dt/rk3568-kickpi-k1.dts            板级设备树
patch/kernel/rk35xx-vendor-6.1/general-drv-net-phy-maxio-*.patch  Maxio PHY 驱动
extensions/kickpi-k1-maxio.sh                                     打开 CONFIG_MAXIO_PHY
.github/workflows/build.yml                                       CI（含构建期自证）
```

## 构建

推送到 `main` 即触发；或在 Actions 页面手动 `workflow_dispatch`。
产物：`inextos-kickpi-k1` artifact（`.img` + `.img.xz` + `.sha`）。

框架：`jjm2473/armbian-easepi` @ `easepi-v26.02`，内核
`armbian/linux-rockchip` @ `rk-6.1-rkr5.1`，分支 `vendor`，发行版 `trixie`。

## 刷写（SD 卡，不碰 eMMC）

首次验证走 **SD 卡启动**：把 `.img.xz` 解压后写入 SD 卡（用 balenaEtcher，
或 `xz -dc <镜像> | sudo tee <SD卡设备>` 一类方式），插卡上电即可，
eMMC 里的原厂系统保持不动；验证通过后再讨论是否刷入 eMMC。
