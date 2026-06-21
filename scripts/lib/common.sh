#!/usr/bin/env bash

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  have_cmd "$1" || die "缺少命令：$1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限执行"
}

check_systemd() {
  require_cmd systemctl
  [ -d /run/systemd/system ] || die "当前系统不是 systemd 运行环境"
}

detect_pkg_manager() {
  if have_cmd dnf; then
    printf 'dnf\n'
    return
  fi

  if have_cmd yum; then
    printf 'yum\n'
    return
  fi

  die "未找到 dnf 或 yum"
}

backup_file() {
  local file="$1"
  local backup

  if [ -e "$file" ] || [ -L "$file" ]; then
    backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$file" "$backup"
    log_info "已备份：$file -> $backup"
  fi
}

write_file_if_changed() {
  local path="$1"
  local mode="${2:-0644}"
  local tmp

  tmp="$(mktemp)"
  cat > "$tmp"

  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    log_info "配置未变化：$path"
    return
  fi

  mkdir -p "$(dirname "$path")"
  backup_file "$path"
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  log_info "已写入：$path"
}

systemctl_unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

enable_unit_if_exists() {
  local unit="$1"

  if systemctl_unit_exists "$unit"; then
    systemctl enable "$unit" >/dev/null
    log_info "已启用服务：$unit"
  else
    log_warn "服务不存在，跳过启用：$unit"
  fi
}

enable_now_unit_if_exists() {
  local unit="$1"

  if systemctl_unit_exists "$unit"; then
    systemctl enable --now "$unit" >/dev/null
    log_info "已启用并启动服务：$unit"
  else
    log_warn "服务不存在，跳过启用：$unit"
  fi
}

disable_now_unit_if_exists() {
  local unit="$1"

  if systemctl_unit_exists "$unit"; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    log_info "已禁用并停止服务：$unit"
  else
    log_warn "服务不存在，跳过禁用：$unit"
  fi
}

stop_unit_if_exists() {
  local unit="$1"

  if systemctl_unit_exists "$unit"; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
    log_info "已停止服务：$unit"
  else
    log_warn "服务不存在，跳过停止：$unit"
  fi
}

clean_pkg_cache() {
  local pm

  pm="$(detect_pkg_manager)"
  "$pm" clean all || log_warn "清理 ${pm} 缓存失败"
  rm -rf /var/cache/yum /var/cache/dnf
  log_info "已清理包管理器缓存"
}

refresh_grub() {
  local wrote="false"

  if ! have_cmd grub2-mkconfig; then
    log_warn "未找到 grub2-mkconfig，跳过 grub 刷新"
    return
  fi

  if [ -d /boot/grub2 ]; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
    wrote="true"
    log_info "已刷新：/boot/grub2/grub.cfg"
  fi

  if [ -d /boot/efi/EFI/kylin ]; then
    grub2-mkconfig -o /boot/efi/EFI/kylin/grub.cfg
    wrote="true"
    log_info "已刷新：/boot/efi/EFI/kylin/grub.cfg"
  fi

  if [ "$wrote" != "true" ]; then
    log_warn "没有找到常见 grub 配置目录，请人工确认启动配置"
  fi
}

print_os_info() {
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    log_info "系统：${PRETTY_NAME:-unknown}"
  fi

  log_info "内核：$(uname -r)"
}
