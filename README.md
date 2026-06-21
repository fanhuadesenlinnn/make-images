# Kylin H3C 镜像制作脚本

这个项目用于把 VMware 里的 Kylin 虚拟机整理成可以上传到华三云平台的镜像母盘。流程目标是：

- 在 Kylin 内安装基础工具、云平台所需组件和 VirtIO/KVM 迁移相关驱动。
- 重建通用 initramfs，避免 VMDK 转 QCOW2 后在云平台无法识别系统盘或 cloud-init 数据光驱。
- 清理旧内核，减小模板体积。
- 在最后一步配置 cloud-init 并封装系统状态。
- 关机后把 VMware VMDK 转成 QCOW2，上传到 H3C 云平台作为镜像模板。

## 支持系统

当前脚本按 Kylin/RHEL 8 系发行版编写，要求系统中存在：

- `bash`
- `systemd`
- `dnf` 或 `yum`
- `rpm`
- `grub2-mkconfig`
- `dracut`

脚本需要在 Kylin 虚拟机内用 `root` 权限执行。

## 目录结构

```text
README.md
docs/
  h3c-qcow2-workflow.md
scripts/
  01-install-base.sh
  02-configure-virtio-initramfs.sh
  03-clean-old-kernels.sh
  04-configure-h3c-cloud-init.sh
  05-seal-image.sh
  lib/
    common.sh
```

## 执行顺序

第一阶段：系统准备。

```bash
sudo bash scripts/01-install-base.sh
sudo bash scripts/02-configure-virtio-initramfs.sh
sudo reboot
```

重启后确认系统能正常进入 Kylin，再执行第二阶段。

```bash
uname -r
sudo bash scripts/03-clean-old-kernels.sh
sudo bash scripts/04-configure-h3c-cloud-init.sh
sudo bash scripts/05-seal-image.sh
sudo shutdown -h now
```

`05-seal-image.sh` 是最后一步。执行后不要继续在 VMware 里配置系统，应该直接关机并转换镜像。

## 每个脚本做什么

### 01-install-base.sh

写入 EPEL 8 yum 源，刷新缓存，安装基础软件、排障工具、磁盘工具、cloud-init、cloud-utils-growpart、dracut、linux-firmware 等组件。

这个脚本只安装 cloud-init，不会清理 cloud-init 状态，也不会清空 `machine-id`。

### 02-configure-virtio-initramfs.sh

写入 `/etc/dracut.conf.d/99-h3c-kvm-generic.conf`，设置 `hostonly="no"`，并把当前系统存在的 VirtIO、SCSI、光驱、ISO 文件系统和磁盘控制器模块加入 initramfs。

然后用 `dracut -f --add-drivers` 重建当前内核的 initramfs，并刷新 grub。

执行完成后必须重启一次，确认当前内核和 initramfs 可以正常启动。

### 03-clean-old-kernels.sh

清理升级后残留的旧内核，只保留当前可启动内核，并刷新 grub。

这个脚本应该只在 `02` 后重启成功之后执行。

### 04-configure-h3c-cloud-init.sh

写入 H3C 云平台镜像使用的 cloud-init 配置：

```yaml
datasource_list: [ ConfigDrive, NoCloud, None ]
```

同时启用 cloud-init 相关 systemd 服务，让模板在云平台首次启动时可以读取元数据。

这个脚本不清理 `machine-id`，不清理网卡配置，不执行 `cloud-init clean`。

### 05-seal-image.sh

最后封装清理：

- 停止 cloud-init 服务。
- 执行 `cloud-init clean --logs --seed`。
- 清理 `/var/lib/cloud/instances` 和 `/var/lib/cloud/instance`。
- 清空 `/etc/machine-id`。
- 重建 `/var/lib/dbus/machine-id` 到 `/etc/machine-id` 的软链接。
- 清理 VMware 常见网卡痕迹。
- 清理 yum/dnf 缓存和临时目录。

执行时需要输入 `YES` 确认。

## 修改的系统路径

脚本会修改或清理这些路径：

```text
/etc/yum.repos.d/epel.repo
/etc/dracut.conf.d/99-h3c-kvm-generic.conf
/etc/cloud/cloud.cfg.d/98-growpart-root.cfg
/etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg
/boot/initramfs-*.img
/boot/grub2/grub.cfg
/boot/efi/EFI/kylin/grub.cfg
/etc/machine-id
/var/lib/dbus/machine-id
/var/lib/cloud
/etc/udev/rules.d/70-persistent-net.rules
/etc/sysconfig/network-scripts/ifcfg-ens160
/etc/sysconfig/network-scripts/ifcfg-ens192
/var/cache/yum
/var/cache/dnf
```

脚本覆盖 `/etc` 下已有配置前会先创建时间戳备份。

## 验收命令

在执行 `02` 后可以检查 initramfs：

```bash
KVER="$(uname -r)"
lsinitrd "/boot/initramfs-${KVER}.img" | grep -E 'cdrom|sr_mod|isofs|virtio_blk|virtio_scsi|virtio_console|sg|sd_mod|dm-mod|xfs|ext4|ahci|libata|ata_piix'
```

在执行 `04` 后可以检查 cloud-init 配置：

```bash
cat /etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg
systemctl is-enabled cloud-init-local cloud-init cloud-config cloud-final
```

执行 `05` 后可以检查封装状态：

```bash
test ! -s /etc/machine-id && echo "machine-id is empty"
test -L /var/lib/dbus/machine-id && echo "dbus machine-id is linked"
test ! -d /var/lib/cloud/instance && echo "cloud-init instance is clean"
```

## VMDK 转 QCOW2

关机后再转换镜像，详细步骤见 [docs/h3c-qcow2-workflow.md](docs/h3c-qcow2-workflow.md)。

基本命令：

```bash
qemu-img convert -p -f vmdk -O qcow2 source.vmdk kylin-h3c.qcow2
qemu-img info kylin-h3c.qcow2
```

## 常见问题

### 为什么不一开始就配置并清理 cloud-init？

因为 `cloud-init clean`、清空 `machine-id`、清理网卡配置都属于镜像封装动作。提前执行后，VMware 里的这台系统可能不适合继续作为普通机器配置。

所以脚本把 cloud-init 分成两段：

- `01` 只安装。
- `04` 写最终云平台配置。
- `05` 才做封装清理。

### 为什么 `02` 后要重启？

因为 `02` 会重建 initramfs。只有重启成功，才能证明当前内核和 initramfs 还能正常启动。确认成功后再执行 `03` 删除旧内核。

### 如果 `03` 清理旧内核失败怎么办？

先不要继续执行 `04` 和 `05`。检查当前系统的包管理器和内核包状态：

```bash
uname -r
rpm -qa 'kernel*' | sort
sudo bash -x scripts/03-clean-old-kernels.sh
```

### 上传 H3C 后首次启动检查什么？

建议检查：

```bash
hostnamectl
ip addr
lsblk
df -hT
cloud-init status --long
sudo journalctl -u cloud-init --no-pager
```
