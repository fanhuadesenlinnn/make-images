#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DRACUT_CONF="/etc/dracut.conf.d/99-h3c-kvm-generic.conf"
VERIFY_PATTERN='cdrom|sr_mod|isofs|virtio|virtio_pci|virtio_ring|virtio_blk|virtio_scsi|virtio_console|sg|scsi_mod|sd_mod|dm-mod|dm_mod|xfs|ext4|ahci|libata|ata_piix|nvme|mptspi|mptscsih|vmw_pvscsi'

PREFERRED_DRIVERS=(
  # 光驱 / ISO / ConfigDrive。
  cdrom
  sr_mod
  isofs

  # KVM / H3C 常见 VirtIO 总线与磁盘控制器。
  virtio
  virtio_pci
  virtio_ring
  virtio_blk
  virtio_scsi
  virtio_console

  # SCSI / device-mapper / 文件系统。
  sg
  scsi_mod
  sd_mod
  dm_mod
  xfs
  ext4

  # SATA / IDE / NVMe 兼容控制器。
  ahci
  libata
  ata_piix
  nvme

  # VMware 源端常见存储控制器，保留兼容性。
  mptspi
  mptscsih
  vmw_pvscsi
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
    log_warn "如果这些模块是内核内建模块，未写入 initramfs 属于正常现象"
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

# 只写当前系统实际存在的模块；内建模块不需要写入 initramfs。
add_drivers+=" ${driver_text} "
EOF
}

for_each_boot_kernel() {
  local callback="$1"
  local vmlinuz
  local kver
  local count=0

  shopt -s nullglob
  for vmlinuz in /boot/vmlinuz-*; do
    [ -f "$vmlinuz" ] || continue

    kver="${vmlinuz#/boot/vmlinuz-}"

    case "$kver" in
      *rescue*|*.hmac)
        log_warn "跳过非标准内核文件：$vmlinuz"
        continue
        ;;
    esac

    if [ ! -d "/lib/modules/$kver" ]; then
      log_warn "跳过 $kver：未找到 /lib/modules/$kver"
      continue
    fi

    "$callback" "$kver"
    count=$((count + 1))
  done
  shopt -u nullglob

  [ "$count" -gt 0 ] || die "未在 /boot/vmlinuz-* 和 /lib/modules 中找到可重建的内核"
}

rebuild_one_initramfs() {
  local kver="$1"
  local image="/boot/initramfs-${kver}.img"

  log_info "重建 initramfs：$image"
  log_info "内核版本：$kver"
  log_info "本次 dracut 显式加入驱动：$DRIVER_TEXT"
  dracut -f --add-drivers "$DRIVER_TEXT" "$image" "$kver"
}

rebuild_initramfs() {
  local driver_text="$1"

  require_cmd dracut

  # 不能只用 uname -r。01-install-base.sh 可能升级并安装新内核，
  # 但重启前 uname -r 仍然是旧内核；这里只重建当前内核会导致新内核的 initramfs 缺驱动。
  DRIVER_TEXT="$driver_text"
  export DRIVER_TEXT
  for_each_boot_kernel rebuild_one_initramfs
}

verify_one_initramfs() {
  local kver="$1"
  local image="/boot/initramfs-${kver}.img"

  if [ ! -f "$image" ]; then
    log_warn "未找到 $image，跳过检查"
    return
  fi

  log_info "检查 initramfs：$image"
  if lsinitrd "$image" | grep -Eq "$VERIFY_PATTERN"; then
    lsinitrd "$image" | grep -E "$VERIFY_PATTERN" || true
    log_info "initramfs 检查通过：$image"
  else
    log_warn "没有在 $image 中看到预期模块，请人工执行 lsinitrd 检查"
  fi
}

verify_initramfs() {
  if ! have_cmd lsinitrd; then
    log_warn "未找到 lsinitrd，跳过 initramfs 内容检查"
    return
  fi

  for_each_boot_kernel verify_one_initramfs
}

main() {
  local drivers

  require_root
  require_cmd modinfo
  print_os_info
  drivers="$(build_driver_list)"
  [ -n "$drivers" ] || die "当前系统没有发现可写入 initramfs 的目标模块"
  write_dracut_config "$drivers"
  rebuild_initramfs "$drivers"
  verify_initramfs
  refresh_grub
  log_info "03 完成：请现在执行 sudo reboot，重启成功后再执行 scripts/04-clean-old-kernels.sh"
}

main "$@"
