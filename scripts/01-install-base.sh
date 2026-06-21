#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

EPEL_REPO="/etc/yum.repos.d/epel.repo"

REQUIRED_PACKAGES=(
  acpid
  bash-completion
  bind-utils
  bzip2
  chrony
  cloud-init
  cloud-utils-growpart
  curl
  dmidecode
  dracut
  e2fsprogs
  file
  gdisk
  gzip
  iproute
  iputils
  jq
  kmod
  less
  linux-firmware
  logrotate
  lvm2
  net-tools
  openssh-clients
  openssh-server
  parted
  pciutils
  psmisc
  python3
  rsync
  smartmontools
  sudo
  tar
  unzip
  usbutils
  wget
  which
  xfsprogs
  xz
  zip
)

OPTIONAL_PACKAGES=(
  dosfstools
  git
  hdparm
  htop
  iftop
  iotop
  lsof
  nmap
  nmap-ncat
  ncdu
  python3-pip
  python3-setuptools
  python3-wheel
  screen
  sshpass
  strace
  sysstat
  tcpdump
  telnet
  tmux
  traceroute
  tree
  vim-enhanced
)

configure_epel_repo() {
  log_info "写入 EPEL 8 yum 源"

  write_file_if_changed "$EPEL_REPO" <<'EOF'
[epel]
name=Extra Packages for Enterprise Linux 8 - $basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-8&arch=$basearch
enabled=1
gpgcheck=0
skip_if_unavailable=True
EOF
}

refresh_package_cache() {
  local pm

  pm="$(detect_pkg_manager)"
  log_info "刷新 ${pm} 缓存"
  "$pm" clean all
  rm -rf /var/cache/yum /var/cache/dnf
  "$pm" makecache
}

install_required_packages() {
  local pm

  pm="$(detect_pkg_manager)"
  log_info "安装必须软件包"
  "$pm" install -y "${REQUIRED_PACKAGES[@]}"
}

install_optional_packages() {
  local pm
  local pkg

  pm="$(detect_pkg_manager)"
  log_info "安装常用工具包，个别包不存在时会跳过"

  for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      log_info "已安装，跳过：$pkg"
      continue
    fi

    if "$pm" install -y "$pkg"; then
      log_info "已安装：$pkg"
    else
      log_warn "安装失败，已跳过：$pkg"
    fi
  done
}

configure_services_for_build_phase() {
  check_systemd

  enable_now_unit_if_exists sshd.service
  enable_now_unit_if_exists chronyd.service
  enable_now_unit_if_exists acpid.service

  log_info "cloud-init 仅安装，构建阶段先禁用，最终封装前由 04 脚本启用"
  disable_now_unit_if_exists cloud-init-local.service
  disable_now_unit_if_exists cloud-init.service
  disable_now_unit_if_exists cloud-config.service
  disable_now_unit_if_exists cloud-final.service
}

main() {
  require_root
  print_os_info
  configure_epel_repo
  refresh_package_cache
  install_required_packages
  install_optional_packages
  configure_services_for_build_phase
  log_info "01 完成：基础软件已安装。下一步执行 scripts/02-configure-virtio-initramfs.sh"
}

main "$@"
