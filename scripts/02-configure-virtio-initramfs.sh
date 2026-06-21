#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DRACUT_CONF="/etc/dracut.conf.d/99-h3c-kvm-generic.conf"
PREFERRED_DRIVERS=(
  virtio_blk
  virtio_scsi
  virtio_console
  sd_mod
  dm_mod
  xfs
  ext4
  ahci
  libata
  ata_piix
)

module_available() {
  local module="$1"

  modinfo "$module" >/dev/null 2>&1
}

build_driver_list() {
  local module
  local drivers=()
  local skipped=()

  for module in "${PREFERRED_DRIVERS[@]}"; do
    if module_available "$module"; then
      drivers+=("$module")
    else
      skipped+=("$module")
    fi
  done

  if [ "${#skipped[@]}" -gt 0 ]; then
    log_warn "以下模块当前系统未发现，dracut 配置中不强制写入：${skipped[*]}"
  fi

  printf '%s\n' "${drivers[*]}"
}

write_dracut_config() {
  local driver_text="$1"

  log_info "写入 dracut 通用 initramfs 配置"
  write_file_if_changed "$DRACUT_CONF" <<EOF
# VMware 迁移到 H3C/KVM 云平台使用。
# hostonly=no 表示生成通用 initramfs，不只适配当前 VMware 虚拟硬件。
hostonly="no"

# 只写当前内核实际能识别的模块；内建模块不需要写入 initramfs。
add_drivers+=" ${driver_text} "
EOF
}

rebuild_initramfs() {
  local kver
  local image

  require_cmd dracut

  kver="$(uname -r)"
  image="/boot/initramfs-${kver}.img"

  log_info "重建 initramfs：$image"
  dracut -f "$image" "$kver"
}

verify_initramfs() {
  local kver
  local image

  kver="$(uname -r)"
  image="/boot/initramfs-${kver}.img"

  if ! have_cmd lsinitrd; then
    log_warn "未找到 lsinitrd，跳过 initramfs 内容检查"
    return
  fi

  log_info "检查 initramfs 中的关键模块"
  if lsinitrd "$image" | grep -Eq 'virtio_blk|virtio_scsi|virtio_console|sd_mod|dm-mod|xfs|ext4|ahci|libata|ata_piix'; then
    lsinitrd "$image" | grep -E 'virtio_blk|virtio_scsi|virtio_console|sd_mod|dm-mod|xfs|ext4|ahci|libata|ata_piix' || true
    log_info "initramfs 检查通过"
  else
    log_warn "没有在 initramfs 中看到预期模块，请人工执行 lsinitrd 检查"
  fi
}

main() {
  local drivers

  require_root
  require_cmd modinfo
  print_os_info
  drivers="$(build_driver_list)"
  [ -n "$drivers" ] || die "当前系统没有发现可写入 initramfs 的目标模块"
  write_dracut_config "$drivers"
  rebuild_initramfs
  verify_initramfs
  refresh_grub
  log_info "02 完成：请现在执行 sudo reboot，重启成功后再执行 03"
}

main "$@"
