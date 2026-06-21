#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

confirm_final_step() {
  if [ "${KYLIN_IMAGE_SEAL_YES:-}" = "1" ]; then
    log_warn "检测到 KYLIN_IMAGE_SEAL_YES=1，跳过交互确认"
    return
  fi

  cat <<'EOF'

即将执行镜像封装清理。

执行后这台 VMware 虚拟机不应继续作为普通系统配置使用，
应该立即关机，并将 VMDK 转换为 QCOW2 上传到 H3C 云平台。

请输入 YES 继续：
EOF

  local answer
  read -r answer
  [ "$answer" = "YES" ] || die "用户取消封装清理"
}

stop_cloud_init_services() {
  check_systemd

  enable_unit_if_exists cloud-init-local.service
  enable_unit_if_exists cloud-init.service
  enable_unit_if_exists cloud-config.service
  enable_unit_if_exists cloud-final.service

  stop_unit_if_exists cloud-final.service
  stop_unit_if_exists cloud-config.service
  stop_unit_if_exists cloud-init.service
  stop_unit_if_exists cloud-init-local.service
}

clean_cloud_init_state() {
  if have_cmd cloud-init; then
    log_info "清理 cloud-init 状态"
    cloud-init clean --logs --seed
  else
    log_warn "未找到 cloud-init，跳过 cloud-init clean"
  fi

  rm -rf /var/lib/cloud/instances/*
  rm -rf /var/lib/cloud/instance
  log_info "已清理 /var/lib/cloud 实例状态"
}

clean_machine_id() {
  log_info "清理 machine-id"

  if [ -e /etc/machine-id ] || [ -L /etc/machine-id ]; then
    backup_file /etc/machine-id
  fi

  : > /etc/machine-id

  mkdir -p /var/lib/dbus
  if [ -e /var/lib/dbus/machine-id ] || [ -L /var/lib/dbus/machine-id ]; then
    backup_file /var/lib/dbus/machine-id
    rm -f /var/lib/dbus/machine-id
  fi

  ln -sf /etc/machine-id /var/lib/dbus/machine-id
  log_info "已清空 /etc/machine-id 并重建 dbus 软链接"
}

clean_vmware_network_state() {
  local file

  log_info "清理 VMware 常见网卡痕迹"

  file="/etc/udev/rules.d/70-persistent-net.rules"
  if [ -e "$file" ] || [ -L "$file" ]; then
    backup_file "$file"
    rm -f "$file"
    log_info "已删除：$file"
  fi

  for file in \
    /etc/sysconfig/network-scripts/ifcfg-ens160 \
    /etc/sysconfig/network-scripts/ifcfg-ens192
  do
    if [ -e "$file" ] || [ -L "$file" ]; then
      backup_file "$file"
      rm -f "$file"
      log_info "已删除：$file"
    fi
  done
}

clean_runtime_files() {
  clean_pkg_cache

  rm -rf /tmp/* /var/tmp/*

  if have_cmd journalctl; then
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  fi

  sync
  log_info "已清理临时文件和日志缓存"
}

final_check() {
  if [ -s /etc/machine-id ]; then
    die "/etc/machine-id 仍然存在内容，封装检查失败"
  fi

  if [ ! -L /var/lib/dbus/machine-id ]; then
    die "/var/lib/dbus/machine-id 不是软链接，封装检查失败"
  fi

  log_info "封装检查通过"
}

main() {
  require_root
  print_os_info
  confirm_final_step
  stop_cloud_init_services
  clean_cloud_init_state
  clean_machine_id
  clean_vmware_network_state
  clean_runtime_files
  final_check
  log_info "05 完成：请立即执行 sudo shutdown -h now，然后转换 QCOW2"
}

main "$@"
