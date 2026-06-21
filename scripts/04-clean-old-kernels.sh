#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

show_kernel_packages() {
  log_info "当前运行内核：$(uname -r)"
  log_info "已安装 kernel 包："
  rpm -qa 'kernel*' | sort || true
}

ensure_current_kernel_boot_files() {
  local kver

  kver="$(uname -r)"

  if [ ! -f "/boot/initramfs-${kver}.img" ]; then
    die "未找到当前内核 initramfs：/boot/initramfs-${kver}.img，请先执行 03 并重启验证"
  fi

  if [ ! -f "/boot/vmlinuz-${kver}" ]; then
    log_warn "未找到当前内核 vmlinuz：/boot/vmlinuz-${kver}，请人工确认 /boot 内容"
  fi
}

remove_old_kernels() {
  local pm
  local current
  local name
  local pkg
  local old_packages=()
  local installonly_names=(
    kernel
    kernel-core
    kernel-modules
    kernel-modules-core
    kernel-modules-extra
    kernel-devel
  )

  pm="$(detect_pkg_manager)"
  current="$(uname -r)"

  log_info "清理旧内核，仅保留当前运行内核：$current"

  for name in "${installonly_names[@]}"; do
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      if [[ "$pkg" != *"$current"* ]]; then
        old_packages+=("$pkg")
      fi
    done < <(rpm -q "$name" 2>/dev/null || true)
  done

  if [ "${#old_packages[@]}" -eq 0 ]; then
    log_info "没有发现需要清理的旧内核包"
    return
  fi

  log_info "将删除旧内核包：${old_packages[*]}"
  "$pm" remove -y "${old_packages[@]}"
}

main() {
  require_root
  require_cmd rpm
  print_os_info
  ensure_current_kernel_boot_files
  show_kernel_packages
  remove_old_kernels
  refresh_grub
  clean_pkg_cache
  show_kernel_packages
  log_info "04 完成：旧内核清理完成。下一步执行 scripts/05-configure-h3c-cloud-init.sh"
}

main "$@"
