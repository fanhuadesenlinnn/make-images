# H3C QCOW2 镜像转换和上传流程

本文档描述 VMware Kylin 虚拟机完成脚本配置后的镜像转换流程。

## 1. Kylin 内部最后确认

在 Kylin 虚拟机内完成：

```bash
sudo bash scripts/01-install-base.sh
sudo bash scripts/02-configure-virtio-initramfs.sh
sudo reboot
```

重启成功后：

```bash
sudo bash scripts/03-clean-old-kernels.sh
sudo bash scripts/04-configure-h3c-cloud-init.sh
sudo bash scripts/05-seal-image.sh
sudo shutdown -h now
```

确认虚拟机是关机状态，不要使用挂起或休眠状态。

## 2. 找到 VMware VMDK

如果 VMware 目录里有多个 VMDK 文件，通常要选择描述文件，例如：

```text
Kylin.vmdk
Kylin-s001.vmdk
Kylin-s002.vmdk
```

转换时一般选择 `Kylin.vmdk`，不要直接选择 `Kylin-s001.vmdk`。

## 3. 转换为 QCOW2

在有 `qemu-img` 的机器上执行：

```bash
qemu-img convert -p -f vmdk -O qcow2 Kylin.vmdk kylin-h3c.qcow2
qemu-img info kylin-h3c.qcow2
```

Windows PowerShell 示例：

```powershell
qemu-img.exe convert -p -f vmdk -O qcow2 .\Kylin.vmdk .\kylin-h3c.qcow2
qemu-img.exe info .\kylin-h3c.qcow2
```

如果 H3C 平台对 QCOW2 兼容版本有要求，可以改用：

```bash
qemu-img convert -p -f vmdk -O qcow2 -o compat=1.1 Kylin.vmdk kylin-h3c.qcow2
```

## 4. 上传到 H3C 云平台

上传时建议选择：

```text
镜像类型：系统盘镜像
操作系统：Linux / Kylin
磁盘格式：QCOW2
启动方式：按原虚拟机安装方式选择 BIOS 或 UEFI
磁盘总线：VirtIO 或平台默认高性能总线
网卡模型：VirtIO
```

具体字段以现场 H3C 云平台页面为准。

## 5. 下发云主机后验证

新建云主机后检查：

```bash
hostnamectl
ip addr
lsblk
df -hT
cloud-init status --long
journalctl -u cloud-init --no-pager
```

重点确认：

- 系统盘能正常启动。
- 网卡能正常识别并获取地址。
- `cloud-init` 首次启动成功。
- 主机名、SSH 密钥、网络配置符合 H3C 下发结果。
- 根分区按预期扩容。

如果系统无法启动，优先检查 initramfs 是否包含 VirtIO/SCSI/文件系统相关模块，以及 H3C 创建云主机时选择的启动方式是否和 VMware 内系统一致。
