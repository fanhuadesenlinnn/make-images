# H3C V7 手册步骤与脚本对应关系

本文档根据 `/Users/caohengyuan/Downloads/云平台V7手册V4(2).docx` 整理，说明手册中的 Kylin/Linux 镜像配置步骤在本项目中由哪些脚本完成。

## 执行顺序

```bash
sudo bash scripts/01-install-base.sh
sudo bash scripts/02-configure-virtio-initramfs.sh
sudo reboot

sudo bash scripts/03-clean-old-kernels.sh
sudo bash scripts/04-configure-h3c-cloud-init.sh
sudo bash scripts/05-seal-image.sh
sudo shutdown -h now
```

## 手册步骤映射

### 修改 cloud-init 配置文件

由 `scripts/04-configure-h3c-cloud-init.sh` 完成。

脚本会修补主配置文件，并额外写入 drop-in 覆盖配置：

```text
/etc/cloud/cloud.cfg
/etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg
```

覆盖项包括：

```yaml
disable_root: 0
mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']
resize_rootfs_tmp: /dev
ssh_deletekeys: 0
ssh_genkeytypes: ~
ssh_pwauth: 1
chpasswd: { expire: False}
datasource_list: ['ConfigDrive']
system_info:
  default_user:
    name: root
```

### 修改 cloud-init 设置密码逻辑

由 `scripts/04-configure-h3c-cloud-init.sh` 完成。

脚本会自动查找：

```text
/usr/lib/python*/site-packages/cloudinit/config/cc_set_passwords.py
/usr/local/lib/python*/site-packages/cloudinit/config/cc_set_passwords.py
```

并把 cloud-init 从元数据读取到的 `admin_pass` 应用到 `root` 用户。

如果目标代码结构和手册不一致，脚本会输出告警，不会静默跳过。

### 修改 cloud-init 网卡映射逻辑

由 `scripts/04-configure-h3c-cloud-init.sh` 完成。

脚本会自动查找：

```text
/usr/lib/python*/site-packages/cloudinit/distros/net_util.py
/usr/local/lib/python*/site-packages/cloudinit/distros/net_util.py
```

并按手册思路增加基于 MAC 地址查找真实网卡名的逻辑，避免云平台下发的网络配置名和系统内实际网卡名不一致。

如果目标代码结构和手册不一致，脚本会输出告警，需要人工确认。

### 编辑 Linux 网卡配置文件

手册中的 `ifcfg-ens14` 是示例网卡名，不适合在模板脚本里硬编码。

本项目不固定写入某个 `ifcfg-ens14`。`scripts/05-seal-image.sh` 会遍历 `/etc/sysconfig/network-scripts/ifcfg-*`，跳过 `ifcfg-lo`，保留原有网卡名，并把配置规范为：

```ini
DEVICE=<原网卡名>
ONBOOT=no
BOOTPROTO=dhcp
TYPE=Ethernet
NM_CONTROLLED=no
```

### 关闭 firewalld，永久关闭 SELinux

由 `scripts/01-install-base.sh` 完成。

脚本会：

```text
systemctl disable --now firewalld.service
setenforce 0
修改 /etc/selinux/config 为 SELINUX=disabled
```

如果系统没有 firewalld 或 SELinux 工具，会输出告警并继续。

### 启用 SSH 服务

由 `scripts/01-install-base.sh` 完成。

脚本会启用并启动：

```text
sshd.service
```

### 清除 Network Persistence Rules

由 `scripts/05-seal-image.sh` 完成。

脚本会处理：

```text
/etc/udev/rules.d/70-persistent-net.rules
/lib/udev/rules.d/75-persistent-net-generator.rules
```

其中 `/etc/udev/rules.d/70-persistent-net.rules` 会备份后删除，`/lib/udev/rules.d/75-persistent-net-generator.rules` 会备份后清空。

### 设置 cloud-init 服务开机自启

由 `scripts/04-configure-h3c-cloud-init.sh` 完成。

脚本会启用：

```text
cloud-init-local.service
cloud-init.service
cloud-config.service
cloud-final.service
```

### 关闭系统

手册中的 `init 0` 对应项目 README 中的最终命令：

```bash
sudo shutdown -h now
```

必须在 `scripts/05-seal-image.sh` 完成后执行。
