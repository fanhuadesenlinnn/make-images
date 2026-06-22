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
- `authselect`
- `pam_faillock.so` 和 `pam_pwquality.so`
- `sudo` / `visudo`
- `sshd`

脚本需要在 Kylin 虚拟机内用 `root` 权限执行。

## 目录结构

```text
README.md
docs/
  h3c-qcow2-workflow.md
  h3c-v7-manual-mapping.md
scripts/
  01-install-base.sh
  02-configure-level3-basic.sh
  03-configure-virtio-initramfs.sh
  04-clean-old-kernels.sh
  05-configure-h3c-cloud-init.sh
  06-seal-image.sh
  lib/
    common.sh
```

## 执行顺序

第一阶段：安装基础组件并完成系统升级。`01-install-base.sh` 可能安装新内核，所以执行后先重启，确保后续操作基于最终启动内核。

```bash
sudo bash scripts/01-install-base.sh
sudo reboot
```

第二阶段：完成等保基础配置并重建所有已安装内核的 initramfs。

```bash
uname -r
sudo bash scripts/02-configure-level3-basic.sh
sudo bash scripts/03-configure-virtio-initramfs.sh
sudo reboot
```

第三阶段：重启后确认系统能正常进入 Kylin，再清理旧内核、配置 cloud-init，并执行最终封装。

```bash
uname -r
sudo bash scripts/04-clean-old-kernels.sh
sudo bash scripts/05-configure-h3c-cloud-init.sh
sudo bash scripts/06-seal-image.sh
sudo shutdown -h now
```

`06-seal-image.sh` 是最后一步。执行后不要继续在 VMware 里配置系统，应该直接关机并转换镜像。

## 每个脚本做什么

### 01-install-base.sh

写入 EPEL 8 yum 源，刷新缓存，执行系统升级，然后安装基础软件、排障工具、磁盘工具、cloud-init、cloud-utils-growpart、dracut、linux-firmware 等组件。

如果系统升级遇到 `python3-IPy` 因不同 yum 源候选包导致的 Python ABI 依赖冲突，脚本会自动只排除这个包后重试：

```bash
yum update -y --exclude=python3-IPy
```

脚本不会使用 `--skip-broken` 跳过一批包；如果排除 `python3-IPy` 后仍然失败，会直接停止，避免掩盖其他源冲突。

这个脚本还会按 H3C V7 手册关闭 `firewalld`、将 SELinux 设置为 `disabled`，创建普通用户 `appuser`，并启用 SSH 服务。

`appuser` 的初始密码为：

```text
1234qwer!@#$
```

这个脚本只安装 cloud-init，不会清理 cloud-init 状态，也不会清空 `machine-id`。

### 02-configure-level3-basic.sh

执行基础等保三级主机侧配置。它是独立脚本，放在基础软件安装之后、重建 initramfs 之前执行。

主要动作包括：

- 配置登录失败锁定：900 秒内失败 8 次后锁定 300 秒。
- 配置密码复杂度：最小长度 12，要求数字、小写字母、特殊字符，不强制大写。
- 配置密码周期：普通用户最长 90 天过期，root 密码不过期。
- 配置 sudo：只允许 root 和 wheel 组使用 sudo，并禁用 `/etc/sudoers.d/` 下其他直接授权文件。
- 确保 `appuser` 是普通用户，默认不能 sudo。
- 配置交互式 shell 1 小时无操作超时。
- 关闭 SSH 端口转发、Agent 转发、X11 转发和隧道能力。

脚本会优先使用 `authselect` 管理 PAM。如果系统无法确认 PAM 配置可安全启用 faillock/pwquality，脚本会停止并输出原因，避免直接写坏登录认证链。

### 03-configure-virtio-initramfs.sh

写入 `/etc/dracut.conf.d/99-h3c-kvm-generic.conf`，设置 `hostonly="no"`，并把当前系统存在的 VirtIO、SCSI、光驱、ISO 文件系统、SATA/IDE、NVMe、VMware PVSCSI 等存储相关模块加入 initramfs。

脚本会遍历 `/boot/vmlinuz-*`，只要对应的 `/lib/modules/<内核版本>` 存在，就对该内核执行 `dracut -f --add-drivers`。这样可以避免 `01-install-base.sh` 升级内核后，只重建旧运行内核 initramfs 的问题。

执行完成后必须重启一次，确认当前内核和 initramfs 可以正常启动。

### 04-clean-old-kernels.sh

清理升级后残留的旧内核，只保留当前可启动内核，并刷新 grub。

这个脚本应该只在 `03` 后重启成功之后执行。

### 05-configure-h3c-cloud-init.sh

修补 `/etc/cloud/cloud.cfg`，并写入 H3C 云平台镜像使用的 cloud-init drop-in 配置：

```yaml
disable_root: 0
mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']
resize_rootfs_tmp: /dev
ssh_deletekeys: 0
ssh_genkeytypes: ~
ssh_pwauth: 1
chpasswd: { expire: False}
datasource_list: ['ConfigDrive']
```

同时按 H3C V7 手册修补 cloud-init 的 root 密码设置逻辑和网卡 MAC 映射逻辑，并启用 cloud-init 相关 systemd 服务，让模板在云平台首次启动时可以读取元数据。

这个脚本不清理 `machine-id`，不清理网卡配置，不执行 `cloud-init clean`。

### 06-seal-image.sh

最后封装清理：

- 停止 cloud-init 服务。
- 执行 `cloud-init clean --logs --seed`。
- 清理 `/var/lib/cloud/instances` 和 `/var/lib/cloud/instance`。
- 清空 `/etc/machine-id`。
- 重建 `/var/lib/dbus/machine-id` 到 `/etc/machine-id` 的软链接。
- 清理 VMware 常见网卡痕迹，并把非 `lo` 的 `ifcfg-*` 网卡配置规范为只保留 `DEVICE`、`ONBOOT`、`BOOTPROTO`、`TYPE`、`NM_CONTROLLED`。
- 清理 yum/dnf 缓存和临时目录。

执行时需要输入 `YES` 确认。

## 修改的系统路径

脚本会修改或清理这些路径：

```text
/etc/yum.repos.d/epel.repo
/etc/selinux/config
/etc/passwd
/etc/shadow
/etc/group
/etc/gshadow
/home/appuser
/etc/security/faillock.conf
/etc/security/pwquality.conf
/etc/login.defs
/etc/pam.d/system-auth
/etc/pam.d/password-auth
/etc/authselect
/etc/nsswitch.conf
/etc/sudoers
/etc/sudoers.d
/etc/profile.d/99-kylin-timeout.sh
/etc/ssh/sshd_config
/etc/dracut.conf.d/99-h3c-kvm-generic.conf
/etc/cloud/cloud.cfg
/etc/cloud/cloud.cfg.d/98-growpart-root.cfg
/etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg
/usr/lib/python*/site-packages/cloudinit/config/cc_set_passwords.py
/usr/lib/python*/site-packages/cloudinit/distros/net_util.py
/usr/local/lib/python*/site-packages/cloudinit/config/cc_set_passwords.py
/usr/local/lib/python*/site-packages/cloudinit/distros/net_util.py
/boot/initramfs-*.img
/boot/grub2/grub.cfg
/boot/efi/EFI/kylin/grub.cfg
/etc/machine-id
/var/lib/dbus/machine-id
/var/lib/cloud
/etc/udev/rules.d/70-persistent-net.rules
/lib/udev/rules.d/75-persistent-net-generator.rules
/etc/sysconfig/network-scripts/ifcfg-*
/var/cache/yum
/var/cache/dnf
```

脚本覆盖 `/etc` 下已有配置前会先创建时间戳备份。

## 验收命令

在执行 `01` 后可以检查普通用户：

```bash
id appuser
```

在执行 `02` 后可以检查等保基础配置：

```bash
grep -E '^(deny|unlock_time|fail_interval)[[:space:]]*=' /etc/security/faillock.conf
grep -E '^(minlen|dcredit|lcredit|ocredit|ucredit|retry|maxrepeat)[[:space:]]*=' /etc/security/pwquality.conf
chage -l appuser
sshd -t -f /etc/ssh/sshd_config
```

在执行 `03` 后可以检查 initramfs：

```bash
for vmlinuz in /boot/vmlinuz-*; do
  KVER="${vmlinuz#/boot/vmlinuz-}"
  [ -d "/lib/modules/${KVER}" ] || continue
  echo "=== ${KVER} ==="
  lsinitrd "/boot/initramfs-${KVER}.img" | grep -E 'virtio|virtio_pci|virtio_ring|virtio_blk|virtio_scsi|scsi_mod|sd_mod|dm-mod|xfs|ext4|ahci|libata|ata_piix|nvme|vmw_pvscsi'
done
```

在执行 `05` 后可以检查 cloud-init 配置：

```bash
cat /etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg
systemctl is-enabled cloud-init-local cloud-init cloud-config cloud-final
```

执行 `06` 后可以检查封装状态：

```bash
test ! -s /etc/machine-id && echo "machine-id is empty"
test -L /var/lib/dbus/machine-id && echo "dbus machine-id is linked"
test ! -d /var/lib/cloud/instance && echo "cloud-init instance is clean"
```

## VMDK 转 QCOW2

关机后再转换镜像，详细步骤见 [docs/h3c-qcow2-workflow.md](docs/h3c-qcow2-workflow.md)。

H3C V7 手册中的配置步骤与脚本对应关系见 [docs/h3c-v7-manual-mapping.md](docs/h3c-v7-manual-mapping.md)。

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
- `05` 写最终云平台配置。
- `06` 才做封装清理。

### 为什么 `01` 后要先重启？

因为 `01-install-base.sh` 会执行系统升级，可能安装新内核。先重启可以确认系统已经运行在升级后的内核上，避免后续误判当前内核状态。

### 为什么 `03` 后要重启？

因为 `03` 会重建所有已安装内核的 initramfs。只有重启成功，才能证明当前内核和 initramfs 还能正常启动。确认成功后再执行 `04` 删除旧内核。

### 如果 `01` 系统升级遇到 python3-IPy 依赖错误怎么办？

类似错误：

```text
nothing provides python(abi) = 3.6 needed by python3-IPy-1.00-3.el8.noarch
```

这是不同 yum 源之间的更新候选包冲突，不按坏包处理。`01-install-base.sh` 会先正常执行 `yum update -y`，失败后只使用 `--exclude=python3-IPy` 排除这个包再重试。如果仍然失败，脚本会停止并要求检查剩余源冲突。

### 如果 `04` 清理旧内核失败怎么办？

先不要继续执行 `05` 和 `06`。检查当前系统的包管理器和内核包状态：

```bash
uname -r
rpm -qa 'kernel*' | sort
sudo bash -x scripts/04-clean-old-kernels.sh
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
