#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DATASOURCE_CFG="/etc/cloud/cloud.cfg.d/99-h3c-datasource.cfg"
GROWPART_CFG="/etc/cloud/cloud.cfg.d/98-growpart-root.cfg"
CLOUD_CFG="/etc/cloud/cloud.cfg"

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
  log_info "写入 H3C V7 cloud-init drop-in 配置"

  write_file_if_changed "$DATASOURCE_CFG" <<'EOF'
# H3C 云平台 V7 镜像模板使用。
disable_root: 0
mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']
resize_rootfs_tmp: /dev
ssh_deletekeys: 0
ssh_genkeytypes: ~
ssh_pwauth: 1
chpasswd: { expire: False}
datasource_list: ['ConfigDrive']
EOF
}

patch_cloud_cfg_main() {
  local tmp

  if [ ! -f "$CLOUD_CFG" ]; then
    log_warn "未找到 $CLOUD_CFG，跳过主 cloud-init 配置文件修补"
    return
  fi

  tmp="$(mktemp)"

  python3 - "$CLOUD_CFG" > "$tmp" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

desired = [
    ("disable_root", "disable_root: 0"),
    ("mount_default_fields", "mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']"),
    ("resize_rootfs_tmp", "resize_rootfs_tmp: /dev"),
    ("ssh_deletekeys", "ssh_deletekeys: 0"),
    ("ssh_genkeytypes", "ssh_genkeytypes: ~"),
    ("ssh_pwauth", "ssh_pwauth: 1"),
    ("chpasswd", "chpasswd: { expire: False}"),
    ("datasource_list", "datasource_list: ['ConfigDrive']"),
]
desired_map = dict(desired)
seen = set()
out = []
i = 0

def indent_width(line):
    return len(line) - len(line.lstrip(" "))

def patch_system_info_default_user(block):
    patched = []
    in_default_user = False
    default_user_seen = False
    default_user_indent = None
    default_user_name_seen = False

    for index, line in enumerate(block):
        if index == 0:
            patched.append(line)
            continue

        stripped = line.strip()
        indent = indent_width(line)
        default_user_match = re.match(r"^(\s*)default_user\s*:\s*(?:#.*)?$", line)

        if default_user_match:
            if in_default_user and not default_user_name_seen:
                patched.append(" " * (default_user_indent + 2) + "name: root")

            in_default_user = True
            default_user_seen = True
            default_user_indent = len(default_user_match.group(1))
            default_user_name_seen = False
            patched.append(line)
            continue

        if in_default_user:
            if stripped and not stripped.startswith("#") and indent <= default_user_indent:
                if not default_user_name_seen:
                    patched.append(" " * (default_user_indent + 2) + "name: root")
                in_default_user = False
                default_user_indent = None
                default_user_name_seen = False
            else:
                name_match = re.match(r"^(\s*)name\s*:.*$", line)
                if name_match:
                    patched.append(f"{name_match.group(1)}name: root")
                    default_user_name_seen = True
                    continue

        patched.append(line)

    if in_default_user and not default_user_name_seen:
        patched.append(" " * (default_user_indent + 2) + "name: root")

    if not default_user_seen:
        patched.append("  default_user:")
        patched.append("    name: root")

    return patched

while i < len(lines):
    line = lines[i]
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:", line)

    if match and match.group(1) == "system_info":
        block = [line]
        i += 1
        while i < len(lines) and not re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*:", lines[i]):
            block.append(lines[i])
            i += 1

        out.extend(patch_system_info_default_user(block))
        continue

    if match and match.group(1) in desired_map:
        key = match.group(1)
        if key not in seen:
            out.append(desired_map[key])
            seen.add(key)

        i += 1
        while i < len(lines) and lines[i].startswith((" ", "\t")):
            i += 1
        continue

    out.append(line)
    i += 1

missing = [line for key, line in desired if key not in seen]
if missing:
    if out and out[-1].strip():
        out.append("")
    out.append("# H3C V7 cloud-init image settings")
    out.extend(missing)

sys.stdout.write("\n".join(out) + "\n")
PY

  if cmp -s "$tmp" "$CLOUD_CFG"; then
    rm -f "$tmp"
    log_info "主 cloud-init 配置未变化：$CLOUD_CFG"
    return
  fi

  backup_file "$CLOUD_CFG"
  install -m 0644 "$tmp" "$CLOUD_CFG"
  rm -f "$tmp"
  log_info "已修补主 cloud-init 配置：$CLOUD_CFG"
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

password_pattern = re.compile(
    r'(?m)^(\s*)password\s*=\s*util\.get_cfg_option_str\(cfg,\s*["\']password["\'],\s*None\)[ \t]*$'
)
match = password_pattern.search(text)
if not match:
    print("password config lookup pattern not found", file=sys.stderr)
    raise SystemExit(1)

admin_pass_pattern = re.compile(
    r'\n+\s*if not password:\n'
    r'\s+metadata\s*=\s*cloud\.datasource\.metadata\n'
    r'\s+if metadata and [\'"]admin_pass[\'"] in metadata:\n'
    r'\s+password\s*=\s*metadata\[[\'"]admin_pass[\'"]\]'
)
text = admin_pass_pattern.sub("", text, count=1)

match = password_pattern.search(text)
password_indent = match.group(1)
if password_indent.endswith("    "):
    block_indent = password_indent[:-4]
elif password_indent.endswith("\t"):
    block_indent = password_indent[:-1]
else:
    block_indent = password_indent

metadata_indent = password_indent
password_value_indent = metadata_indent + ("    " if "\t" not in metadata_indent else "\t")
admin_pass_block = (
    f"{match.group(0)}\n\n"
    f"{block_indent}if not password:\n"
    f"{metadata_indent}metadata = cloud.datasource.metadata\n"
    f"{metadata_indent}if metadata and 'admin_pass' in metadata:\n"
    f"{password_value_indent}password = metadata['admin_pass']"
)
rest_start = match.end()
while rest_start < len(text) and text[rest_start] == "\n":
    rest_start += 1
rest = text[rest_start:]
text = text[:match.start()] + admin_pass_block + ("\n" + rest if rest else "")
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

def remove_legacy_h3c_block(source):
    source_lines = source.splitlines()
    cleaned = []
    removed = False
    index = 0

    while index < len(source_lines):
        if source_lines[index].strip() == "# H3C: map metadata hwaddress to actual guest device name.":
            index += 9
            removed = True
            continue

        cleaned.append(source_lines[index])
        index += 1

    return "\n".join(cleaned) + "\n", removed

text, removed_legacy = remove_legacy_h3c_block(text)
changed = changed or removed_legacy

if "for (dev, d) in netdev.iteritems():" not in text:
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
                f"{indent}for (dev, d) in netdev.iteritems():",
                f"{inner}if d[\"hwaddr\"] == hw_addr:",
                f"{inner2}dev_name = dev.strip().split(':')[0]",
            ])
            inserted = True

    if not inserted:
        print("iface_info['hwaddress'] assignment not found", file=sys.stderr)
        raise SystemExit(1)

    text = "\n".join(out) + "\n"
    changed = True

lines = text.splitlines()
out = []
auto_checked = False
auto_inserted = False
pattern = re.compile(r"^(\s*)real_ifaces\[dev_name\]\s*=\s*iface_info\s*$")

for index, line in enumerate(lines):
    out.append(line)
    match = pattern.match(line)
    if match and not auto_checked:
        indent = match.group(1)
        expected = f"{indent}real_ifaces[dev_name]['auto'] = True"
        next_line = lines[index + 1] if index + 1 < len(lines) else ""
        auto_checked = True

        if next_line != expected:
            out.append(expected)
            auto_inserted = True

if not auto_checked:
    print("real_ifaces[dev_name] assignment not found", file=sys.stderr)
    raise SystemExit(1)

if auto_inserted:
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
  patch_cloud_cfg_main
  write_growpart_config
  write_cloud_init_datasource
  patch_cloudinit_set_passwords
  patch_cloudinit_net_util
  enable_cloud_init_services
  cloud-init --version || true
  log_info "04 完成：cloud-init 已配置为下次云平台启动使用。下一步执行 scripts/05-seal-image.sh"
}

main "$@"
