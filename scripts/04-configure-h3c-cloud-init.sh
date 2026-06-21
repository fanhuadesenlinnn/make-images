#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DATASOURCE_CFG="/etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg"
GROWPART_CFG="/etc/cloud/cloud.cfg.d/98-growpart-root.cfg"

write_cloud_init_datasource() {
  log_info "写入 H3C cloud-init datasource 配置"

  write_file_if_changed "$DATASOURCE_CFG" <<'EOF'
# H3C 云平台镜像模板使用。
datasource_list: [ ConfigDrive, NoCloud, None ]
EOF
}

write_growpart_config() {
  log_info "写入根分区自动扩容配置"

  write_file_if_changed "$GROWPART_CFG" <<'EOF'
# 首次启动后尝试扩容根分区和根文件系统。
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
EOF
}

enable_cloud_init_services() {
  check_systemd

  enable_unit_if_exists cloud-init-local.service
  enable_unit_if_exists cloud-init.service
  enable_unit_if_exists cloud-config.service
  enable_unit_if_exists cloud-final.service
}

main() {
  require_root
  require_cmd cloud-init
  print_os_info
  write_growpart_config
  write_cloud_init_datasource
  enable_cloud_init_services
  cloud-init --version || true
  log_info "04 完成：cloud-init 已配置为下次云平台启动使用。下一步执行 scripts/05-seal-image.sh"
}

main "$@"
