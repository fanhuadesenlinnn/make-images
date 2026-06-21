#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DATASOURCE_CFG="/etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg"
GROWPART_CFG="/etc/cloud/cloud.cfg.d/98-growpart-root.cfg"

find_cloudinit_python_file() {
  local relative_path="$1"
  local candidate

  for candidate in \
    "/usr/lib/python"*/site-packages/cloudinit/"$relative_path" \
    "/usr/local/lib/python"*/site-packages/cloudinit/"$relative_path"
  do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  return 1
}

write_cloud_init_datasource() {
  log_info "写入 H3C V7 cloud-init 配置"

  write_file_if_changed "$DATASOURCE_CFG" <<'EOF'
# H3C 云平台 V7 镜像模板使用。
disable_root: 0
mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']
resize_rootfs_tmp: /dev
ssh_deletekeys: 0
ssh_genkeytypes: ~
ssh_pwauth: 1
chpasswd: { expire: false }
datasource_list: [ ConfigDrive ]
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

patch_cloudinit_set_passwords() {
  local target

  if ! target="$(find_cloudinit_python_file "config/cc_set_passwords.py")"; then
    log_warn "未找到 cloudinit/config/cc_set_passwords.py，跳过 root 密码目标补丁"
    return
  fi

  backup_file "$target"
  log_info "修补 cloud-init admin_pass 读取和 root 密码目标用户：$target"

  if python3 - "$target" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

changed = False

if "metadata = cloud.datasource.metadata" not in text or "'admin_pass' in metadata" not in text:
    pattern = re.compile(
        r'(?m)^(\s*)password\s*=\s*util\.get_cfg_option_str\(cfg,\s*["\']password["\'],\s*None\)\s*$'
    )
    match = pattern.search(text)
    if not match:
        print("password config lookup pattern not found", file=sys.stderr)
        raise SystemExit(1)

    indent = match.group(1)
    admin_pass_block = (
        f"{match.group(0)}\n"
        f"{indent}if not password:\n"
        f"{indent}    metadata = cloud.datasource.metadata\n"
        f"{indent}    if metadata and 'admin_pass' in metadata:\n"
        f"{indent}        password = metadata['admin_pass']"
    )
    text = text[:match.start()] + admin_pass_block + text[match.end():]
    changed = True

needle = 'plist = ["%s:%s" % (user, password)]'
replacement = 'plist = ["%s:%s" % ("root", password)]'

if '"root", password' in text:
    pass
elif needle in text:
    text = text.replace(needle, replacement, 1)
    changed = True
else:
    print(f"pattern not found: {needle}", file=sys.stderr)
    raise SystemExit(1)

if changed:
    path.write_text(text, encoding="utf-8")
else:
    print("already patched")
PY
  then
    log_info "cc_set_passwords.py 补丁完成"
  else
    log_warn "cc_set_passwords.py 未能自动补丁，请按 H3C V7 手册人工确认"
  fi
}

patch_cloudinit_net_util() {
  local target

  if ! target="$(find_cloudinit_python_file "distros/net_util.py")"; then
    log_warn "未找到 cloudinit/distros/net_util.py，跳过网卡 MAC 映射补丁"
    return
  fi

  backup_file "$target"
  log_info "修补 cloud-init 网卡 MAC 到真实设备名映射：$target"

  if python3 - "$target" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

changed = False

lines = text.splitlines()
in_cloudinit_multiline_import = False
netinfo_import_present = False
cleaned_lines = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith("from cloudinit.") and stripped.endswith("("):
        in_cloudinit_multiline_import = True
    if in_cloudinit_multiline_import and stripped == "from cloudinit import netinfo":
        changed = True
        continue
    if not in_cloudinit_multiline_import and stripped == "from cloudinit import netinfo":
        netinfo_import_present = True
    cleaned_lines.append(line)
    if in_cloudinit_multiline_import and stripped.endswith(")"):
        in_cloudinit_multiline_import = False

lines = cleaned_lines

if not netinfo_import_present:
    insert_at = None
    in_multiline_import = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("from cloudinit.") and stripped.endswith("("):
            in_multiline_import = True
        if in_multiline_import:
            if stripped.endswith(")"):
                insert_at = i + 1
                in_multiline_import = False
            continue
        if stripped.startswith("from cloudinit ") or stripped.startswith("from cloudinit."):
            insert_at = i + 1

    if insert_at is None:
        print("cloudinit import block not found", file=sys.stderr)
        raise SystemExit(1)

    lines.insert(insert_at, "from cloudinit import netinfo")
    changed = True

if changed:
    text = "\n".join(lines) + "\n"

if "netdev = netinfo.netdev_info()" not in text:
    needle = "def translate_network(settings):\n"
    if needle not in text:
        print("translate_network(settings) not found", file=sys.stderr)
        raise SystemExit(1)
    text = text.replace(needle, needle + "    netdev = netinfo.netdev_info()\n", 1)
    changed = True

if "H3C: map metadata hwaddress to actual guest device name." not in text:
    lines = text.splitlines()
    out = []
    inserted = False
    pattern = re.compile(r"^(\s*)iface_info\[['\"]hwaddress['\"]\]\s*=\s*hw_addr\s*$")

    for line in lines:
        out.append(line)
        match = pattern.match(line)
        if match and not inserted:
            indent = match.group(1)
            inner = indent + "    "
            inner2 = inner + "    "
            out.extend([
                f"{indent}# H3C: map metadata hwaddress to actual guest device name.",
                f"{indent}for (dev, d) in netdev.items():",
                f"{inner}if d.get(\"hwaddr\", \"\").lower() == hw_addr:",
                f"{inner2}dev_name = dev.strip().split(':')[0]",
                f"{inner2}if dev_name in real_ifaces:",
                f"{inner2}    real_ifaces[dev_name].update(iface_info)",
                f"{inner2}else:",
                f"{inner2}    real_ifaces[dev_name] = iface_info",
                f"{inner2}real_ifaces[dev_name]['auto'] = True",
            ])
            inserted = True

    if not inserted:
        print("iface_info['hwaddress'] assignment not found", file=sys.stderr)
        raise SystemExit(1)

    text = "\n".join(out) + "\n"
    changed = True

if changed:
    path.write_text(text, encoding="utf-8")
else:
    print("already patched")
PY
  then
    log_info "net_util.py 补丁完成"
  else
    log_warn "net_util.py 未能自动补丁，请按 H3C V7 手册人工确认"
  fi
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
  require_cmd python3
  require_cmd cloud-init
  print_os_info
  write_growpart_config
  write_cloud_init_datasource
  patch_cloudinit_set_passwords
  patch_cloudinit_net_util
  enable_cloud_init_services
  cloud-init --version || true
  log_info "04 完成：cloud-init 已配置为下次云平台启动使用。下一步执行 scripts/05-seal-image.sh"
}

main "$@"
