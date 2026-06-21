#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 脚本名称：
#   02-configure-level3-basic.sh
#
# 脚本用途：
#   针对麒麟 / RHEL / CentOS / openEuler 兼容系统做基础等保三级主机侧配置。
#
# 实现功能：
#   1. 登录失败锁定：
#        - 900 秒内失败 8 次后锁定
#        - 锁定 300 秒
#
#   2. sudo 权限控制：
#        - 只有 wheel 组用户允许使用 sudo
#        - root 保留 sudo 权限
#        - 其他用户或其他组的 sudo 授权会被注释或禁用
#
#   3. 创建普通用户：
#        - 用户名：appuser
#        - 密码：1234qwer!@#$
#        - 默认不加入 wheel 组，因此默认不能 sudo
#
#   4. 密码复杂度：
#        - 密码最小长度 12
#        - 至少 1 个数字
#        - 至少 1 个小写字母
#        - 至少 1 个特殊字符
#        - 不强制大写字母
#        - 修改密码时最多重试 3 次
#        - 同一字符最多连续重复 5 次
#
#   5. 密码周期：
#        - 普通用户密码最长 90 天过期
#        - 密码至少使用 1 天后才能修改
#        - 密码过期前 30 天提醒
#        - root 用户密码不过期
#
# 主要影响：
#   1. 登录失败锁定会影响 SSH、su、控制台登录、图形化登录等 PAM 认证。
#   2. 密码复杂度会影响 passwd 修改密码、新建用户设置密码等场景。
#   3. sudo 限制会影响之前通过 /etc/sudoers 或 /etc/sudoers.d 单独授权的用户或组。
#   4. /etc/sudoers.d/ 下已有的 sudo 授权文件会被备份并禁用，防止绕过 wheel。
#   5. appuser 是普通用户，不能 sudo。如果需要 sudo，必须加入 wheel 组。
#   6. root 密码不过期属于例外策略，如果测评要求所有账号统一过期，需要单独说明。
#
# 备份策略：
#   - 所有被修改文件都会在原文件同目录生成备份。
#   - 备份格式：原文件.bak.20250506-102309
#
# 可重复执行：
#   1. 不重复创建用户
#   2. 不重复追加 PAM 配置
#   3. 不重复追加 sudoers 配置
#   4. 每次执行都会生成本次时间戳备份
#
# 注意：
#   1. 脚本内置明文密码，仅适合初始化或现场整改场景。
#   2. 生产环境建议执行后修改 appuser 密码。
#   3. 执行前建议保留一个已登录 root 会话，防止误操作导致无法重新登录。
# ==============================================================================


# ------------------------------------------------------------------------------
# 全局参数
# ------------------------------------------------------------------------------

# 时间戳格式：
#   例如：20250506-102309
TS="$(date +%Y%m%d-%H%M%S)"

# 登录失败锁定参数。
DENY="${DENY:-8}"
UNLOCK_TIME="${UNLOCK_TIME:-300}"
FAIL_INTERVAL="${FAIL_INTERVAL:-900}"

# 普通用户参数。
APP_USER="${APP_USER:-appuser}"

# 注意：
#   密码写在脚本中属于明文密码，适合一次性初始化场景。
#   生产环境建议执行脚本后立即执行 passwd appuser 修改密码。
APP_PASSWORD='1234qwer!@#$'

# 密码周期配置文件。
LOGIN_DEFS="/etc/login.defs"

# 密码复杂度配置文件。
PWQUALITY_CONF="/etc/security/pwquality.conf"

# 普通用户密码周期策略。
PASS_MAX_DAYS="${PASS_MAX_DAYS:-90}"
PASS_MIN_DAYS="${PASS_MIN_DAYS:-1}"
PASS_WARN_AGE="${PASS_WARN_AGE:-30}"

# 密码复杂度策略。
PASS_MIN_LEN="${PASS_MIN_LEN:-12}"

# 至少 1 个数字。
PASS_D_CREDIT="${PASS_D_CREDIT:--1}"

# 至少 1 个小写字母。
PASS_L_CREDIT="${PASS_L_CREDIT:--1}"

# 至少 1 个特殊字符。
PASS_O_CREDIT="${PASS_O_CREDIT:--1}"

# 不强制大写字母。
# 影响说明：
#   appuser 默认密码 1234qwer!@#$ 没有大写字母，所以这里不强制大写。
PASS_U_CREDIT="${PASS_U_CREDIT:-0}"

# 修改密码最多重试 3 次。
PASS_RETRY="${PASS_RETRY:-3}"

# 同一字符最多连续重复 5 次。
PASS_MAX_REPEAT="${PASS_MAX_REPEAT:-5}"

# faillock 主配置文件。
FAILLOCK_CONF="/etc/security/faillock.conf"

# PAM 公共认证文件。
PAM_FILES=(
  "/etc/pam.d/system-auth"
  "/etc/pam.d/password-auth"
)

# 默认不手工修改 PAM 文件。
# 如现场明确确认 PAM 栈模板兼容，可设置 ALLOW_MANUAL_PAM=1 启用旧的手工插入逻辑。
ALLOW_MANUAL_PAM="${ALLOW_MANUAL_PAM:-0}"

# authselect 接管配置。
# 当前系统安装 authselect 但尚未选择 profile 时，默认选择 minimal 并启用 with-faillock。
# 如果现场使用 SSSD/域账号，可执行：AUTHSELECT_PROFILE=sssd bash 02-configure-level3-basic.sh
ENABLE_AUTHSELECT_MANAGE="${ENABLE_AUTHSELECT_MANAGE:-1}"
AUTHSELECT_PROFILE="${AUTHSELECT_PROFILE:-minimal}"

# sudo 配置文件。
SUDOERS_FILE="/etc/sudoers"
SUDOERS_D_DIR="/etc/sudoers.d"
WHEEL_ONLY_FILE="/etc/sudoers.d/00-wheel-only"

# 会话超时配置：默认 1 小时。
SESSION_TIMEOUT="${SESSION_TIMEOUT:-3600}"
PROFILE_TIMEOUT_FILE="/etc/profile.d/99-kylin-timeout.sh"

# SSH 加固配置：关闭 SSH 端口转发相关能力。
SSHD_CONFIG="/etc/ssh/sshd_config"
RELOAD_SSHD="${RELOAD_SSHD:-1}"

# authselect 可能改写 nsswitch.conf。
NSSWITCH_CONF="/etc/nsswitch.conf"


# ------------------------------------------------------------------------------
# 基础输出函数
# ------------------------------------------------------------------------------

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

die() {
    error "$*"
    exit 1
}


# ------------------------------------------------------------------------------
# root 权限检查
# ------------------------------------------------------------------------------

require_root() {
    # 影响说明：
    #   PAM、sudoers、用户创建、chage 均属于系统级配置，必须 root 权限执行。
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 用户执行该脚本"
    fi
}


# ------------------------------------------------------------------------------
# 备份函数
# ------------------------------------------------------------------------------

backup_path() {
    local path="$1"

    # 影响说明：
    #   所有修改前先备份，备份放在原文件同目录，方便现场快速回滚。
    #   备份格式：
    #     原文件.bak.20250506-102309

    if [ -e "$path" ]; then
        local bak="${path}.bak.${TS}"

        if [ ! -e "$bak" ]; then
            cp -a "$path" "$bak"
            log "已备份：$path -> $bak"
        else
            warn "备份已存在，跳过：$bak"
        fi
    else
        warn "路径不存在，跳过备份：$path"
    fi
}


# ------------------------------------------------------------------------------
# 一、配置登录失败锁定
# ------------------------------------------------------------------------------

check_pam_faillock_module() {
    # 影响说明：
    #   pam_faillock.so 是登录失败锁定的核心 PAM 模块。
    #   如果模块不存在，写入 PAM 配置可能导致认证异常，所以直接停止。
    if [ ! -f /usr/lib64/security/pam_faillock.so ] && [ ! -f /usr/lib/security/pam_faillock.so ]; then
        die "未找到 pam_faillock.so，请先安装 pam 相关软件包"
    fi
}

set_faillock_conf_value() {
    local key="$1"
    local value="$2"
    local file="$FAILLOCK_CONF"

    if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|g" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

configure_faillock_conf() {
    # 影响说明：
    #   配置 /etc/security/faillock.conf 后，PAM faillock 会按这里的策略锁定用户。
    #
    # 当前设置：
    #   deny = 8
    #   unlock_time = 300
    #   fail_interval = 900
    #
    # 默认不启用 even_deny_root。
    # 原因：
    #   避免 root 被锁定后，现场无法远程维护。

    if [ ! -f "$FAILLOCK_CONF" ]; then
        touch "$FAILLOCK_CONF"
        chmod 0644 "$FAILLOCK_CONF"
        log "已创建：$FAILLOCK_CONF"
    fi

    backup_path "$FAILLOCK_CONF"

    set_faillock_conf_value "deny" "$DENY"
    set_faillock_conf_value "unlock_time" "$UNLOCK_TIME"
    set_faillock_conf_value "fail_interval" "$FAIL_INTERVAL"

    log "已配置登录失败锁定：失败 ${DENY} 次，锁定 ${UNLOCK_TIME} 秒，统计窗口 ${FAIL_INTERVAL} 秒"
}

authselect_profile_exists() {
    local profile="$1"

    authselect list 2>/dev/null | awk -v profile="$profile" '
        $1 == "-" && $2 == profile { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

ensure_authselect_profile_selected() {
    # 影响说明：
    #   authselect current 显示“未检测到现有配置”时，说明 authselect 尚未接管 PAM/NSS。
    #   本函数会在备份关键文件后执行 authselect select，使后续 enable-feature 可生效。
    #
    # 默认 profile：
    #   minimal：适合只使用本地账号的最小化系统。
    #
    # 如使用 SSSD/域账号：
    #   AUTHSELECT_PROFILE=sssd bash 02-configure-level3-basic.sh

    if ! command -v authselect >/dev/null 2>&1; then
        return 1
    fi

    if authselect current >/dev/null 2>&1; then
        return 0
    fi

    if [ "$ENABLE_AUTHSELECT_MANAGE" != "1" ]; then
        warn "authselect 尚未接管配置，且 ENABLE_AUTHSELECT_MANAGE 不为 1，跳过 authselect 自动接管"
        return 1
    fi

    if ! authselect_profile_exists "$AUTHSELECT_PROFILE"; then
        warn "authselect profile 不存在：$AUTHSELECT_PROFILE"
        authselect list >&2 || true
        return 1
    fi

    log "authselect 尚未接管配置，准备选择 profile：$AUTHSELECT_PROFILE"

    backup_path "/etc/authselect"
    backup_path "$NSSWITCH_CONF"

    for f in "${PAM_FILES[@]}"; do
        backup_path "$f"
    done

    if authselect select "$AUTHSELECT_PROFILE" with-faillock --force >/dev/null 2>&1; then
        authselect apply-changes >/dev/null 2>&1 || true
        log "authselect 已选择 profile：$AUTHSELECT_PROFILE，并启用 with-faillock"
        return 0
    fi

    warn "authselect select $AUTHSELECT_PROFILE with-faillock --force 执行失败"
    return 1
}

configure_authselect_faillock_if_available() {
    # 影响说明：
    #   麒麟 V10 / EL8 部分系统使用 authselect 管理 PAM。
    #   如果系统启用了 authselect，优先使用 authselect enable-feature with-faillock。
    #
    # 优点：
    #   避免直接手工修改 /etc/pam.d/system-auth 后被 authselect 覆盖。
    #
    # 如果 authselect 不可用或启用失败，默认停止；只有 ALLOW_MANUAL_PAM=1 时才使用手工 PAM 修改方式。

    if ! command -v authselect >/dev/null 2>&1; then
        return 1
    fi

    if ! ensure_authselect_profile_selected; then
        return 1
    fi

    log "检测到 authselect，尝试启用 with-faillock"

    backup_path "/etc/authselect"

    for f in "${PAM_FILES[@]}"; do
        backup_path "$f"
    done

    if authselect current | grep -q "with-faillock"; then
        log "authselect 已启用 with-faillock"
        return 0
    fi

    if authselect enable-feature with-faillock >/dev/null 2>&1; then
        authselect apply-changes >/dev/null 2>&1 || true
        log "authselect 已启用 with-faillock"
        return 0
    else
        warn "authselect 启用 with-faillock 失败，将改用手工 PAM 配置"
        return 1
    fi
}

configure_pam_faillock_file_manual() {
    local file="$1"
    local module_args="deny=${DENY} unlock_time=${UNLOCK_TIME} fail_interval=${FAIL_INTERVAL}"

    [ -f "$file" ] || {
        warn "PAM 文件不存在，跳过：$file"
        return 0
    }

    backup_path "$file"

    # 影响说明：
    #   手工修改 PAM 的目标：
    #
    #   1. preauth：
    #      认证前检查用户是否已经被锁定。
    #
    #   2. authfail：
    #      密码错误时记录失败次数。
    #
    #   3. account：
    #      账户阶段检查锁定状态。
    #
    #   重复执行策略：
    #      先删除已有 pam_faillock.so 相关行，再插入标准行。
    #
    #   影响范围：
    #      SSH、su、控制台登录、图形化登录等调用这些 PAM 栈的认证行为。

    local tmp
    tmp="$(mktemp)"

    awk -v module_args="$module_args" '
    BEGIN {
        inserted_preauth = 0
        inserted_authfail = 0
        inserted_account = 0
    }

    /^[[:space:]]*auth[[:space:]].*pam_faillock\.so/ {
        next
    }

    /^[[:space:]]*account[[:space:]].*pam_faillock\.so/ {
        next
    }

    /^[[:space:]]*auth[[:space:]].*pam_unix\.so/ && inserted_preauth == 0 {
        print "auth        required      pam_faillock.so preauth silent audit " module_args
        print $0
        inserted_preauth = 1
        next
    }

    /^[[:space:]]*auth[[:space:]].*pam_deny\.so/ && inserted_authfail == 0 {
        print "auth        [default=die] pam_faillock.so authfail audit " module_args
        print $0
        inserted_authfail = 1
        next
    }

    /^[[:space:]]*account[[:space:]].*pam_unix\.so/ && inserted_account == 0 {
        print "account     required      pam_faillock.so"
        print $0
        inserted_account = 1
        next
    }

    {
        print $0
    }

    END {
        if (inserted_preauth == 0) {
            print ""
            print "# Added by 02-configure-level3-basic.sh"
            print "auth        required      pam_faillock.so preauth silent audit " module_args
        }

        if (inserted_authfail == 0) {
            print "auth        [default=die] pam_faillock.so authfail audit " module_args
        }

        if (inserted_account == 0) {
            print "account     required      pam_faillock.so"
        }
    }
    ' "$file" > "$tmp"

    cat "$tmp" > "$file"
    rm -f "$tmp"

    log "已手工配置 PAM faillock 文件：$file"
}

configure_pam_faillock() {
    if configure_authselect_faillock_if_available; then
        if grep -q "pam_faillock.so" /etc/pam.d/system-auth 2>/dev/null; then
            log "PAM 已通过 authselect 配置 pam_faillock"
            return 0
        fi
    fi

    if existing_pam_module_enabled "pam_faillock.so"; then
        log "检测到 PAM 已存在 pam_faillock.so，保持现有 PAM 配置并继续"
        warn_existing_faillock_inline_options
        return 0
    fi

    if [ "$ALLOW_MANUAL_PAM" != "1" ]; then
        die "authselect 未能确认启用 pam_faillock，且 ALLOW_MANUAL_PAM 未设置为 1。为避免手工改 PAM 导致认证异常，已停止。"
    fi

    log "开始手工配置 PAM faillock"

    for f in "${PAM_FILES[@]}"; do
        configure_pam_faillock_file_manual "$f"
    done
}


# ------------------------------------------------------------------------------
# 二、配置密码复杂度和密码周期
# ------------------------------------------------------------------------------

check_pwquality_module() {
    # 影响说明：
    #   pam_pwquality.so 是密码复杂度检查模块。
    #   如果模块不存在，仅配置 /etc/security/pwquality.conf 可能不会生效。
    #
    # 常见软件包名称：
    #   libpwquality
    #   libpwquality-pam
    #   pam_pwquality

    if [ ! -f /usr/lib64/security/pam_pwquality.so ] && [ ! -f /usr/lib/security/pam_pwquality.so ]; then
        warn "未找到 pam_pwquality.so，密码复杂度可能不会生效，请确认是否安装 libpwquality / pam_pwquality 相关包"
        return 1
    fi

    return 0
}

set_login_defs_value() {
    local key="$1"
    local value="$2"
    local file="$LOGIN_DEFS"

    # 影响说明：
    #   /etc/login.defs 主要影响新建用户的默认密码周期。
    #   对已经存在的用户，需要额外用 chage 设置。

    if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key}   ${value}|g" "$file"
    else
        echo "${key}   ${value}" >> "$file"
    fi
}

set_pwquality_value() {
    local key="$1"
    local value="$2"
    local file="$PWQUALITY_CONF"

    # 影响说明：
    #   /etc/security/pwquality.conf 控制密码复杂度。
    #   如果原配置被注释，也会替换成生效配置。

    if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|g" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

configure_password_policy() {
    # 影响说明：
    #   本函数配置系统默认密码周期和密码复杂度。
    #
    # 普通用户密码周期：
    #   PASS_MAX_DAYS 90
    #   PASS_MIN_DAYS 1
    #   PASS_WARN_AGE 30
    #
    # 密码复杂度：
    #   minlen = 12
    #   dcredit = -1
    #   lcredit = -1
    #   ocredit = -1
    #   ucredit = 0
    #   retry = 3
    #   maxrepeat = 5
    #
    # 注意：
    #   root 用户密码不过期会在 apply_password_policy_to_users 函数中单独设置。

    if [ -f "$LOGIN_DEFS" ]; then
        backup_path "$LOGIN_DEFS"

        set_login_defs_value "PASS_MAX_DAYS" "$PASS_MAX_DAYS"
        set_login_defs_value "PASS_MIN_DAYS" "$PASS_MIN_DAYS"
        set_login_defs_value "PASS_WARN_AGE" "$PASS_WARN_AGE"

        log "已配置默认密码周期：最长 ${PASS_MAX_DAYS} 天，最短 ${PASS_MIN_DAYS} 天，过期前 ${PASS_WARN_AGE} 天提醒"
    else
        warn "未找到 $LOGIN_DEFS，跳过密码周期配置"
    fi

    if [ ! -f "$PWQUALITY_CONF" ]; then
        touch "$PWQUALITY_CONF"
        chmod 0644 "$PWQUALITY_CONF"
        log "已创建：$PWQUALITY_CONF"
    fi

    backup_path "$PWQUALITY_CONF"

    set_pwquality_value "minlen" "$PASS_MIN_LEN"
    set_pwquality_value "dcredit" "$PASS_D_CREDIT"
    set_pwquality_value "lcredit" "$PASS_L_CREDIT"
    set_pwquality_value "ocredit" "$PASS_O_CREDIT"
    set_pwquality_value "ucredit" "$PASS_U_CREDIT"
    set_pwquality_value "retry" "$PASS_RETRY"
    set_pwquality_value "maxrepeat" "$PASS_MAX_REPEAT"

    log "已配置密码复杂度：长度 >= ${PASS_MIN_LEN}，要求数字、小写、特殊字符，不强制大写"
}

configure_authselect_pwquality_if_available() {
    # 影响说明：
    #   如果系统由 authselect 管理 PAM，优先尝试启用 with-pwquality。
    #   如果系统不支持该 feature，默认停止；只有 ALLOW_MANUAL_PAM=1 时才继续走手工 PAM 检查。

    if ! command -v authselect >/dev/null 2>&1; then
        return 1
    fi

    if ! ensure_authselect_profile_selected; then
        return 1
    fi

    if grep -q "pam_pwquality.so" /etc/pam.d/system-auth 2>/dev/null; then
        log "authselect profile 已包含 pam_pwquality"
        return 0
    fi

    if authselect current | grep -q "with-pwquality"; then
        log "authselect 已启用 with-pwquality"
        return 0
    fi

    if authselect enable-feature with-pwquality >/dev/null 2>&1; then
        authselect apply-changes >/dev/null 2>&1 || true
        log "authselect 已启用 with-pwquality"
        return 0
    fi

    return 1
}

existing_pam_module_enabled() {
    local module="$1"
    local file
    local missing_module=0
    local found_file=0

    for file in "${PAM_FILES[@]}"; do
        [ -f "$file" ] || {
            warn "PAM 文件不存在，跳过模块检查：$file"
            continue
        }

        found_file=1

        if ! grep -q "$module" "$file"; then
            warn "$file 未检测到 $module"
            missing_module=1
        fi
    done

    [ "$found_file" -eq 1 ] && [ "$missing_module" -eq 0 ]
}

warn_existing_faillock_inline_options() {
    local lines

    lines="$(grep -En "pam_faillock\.so.*(deny=|unlock_time=|fail_interval=|even_deny_root|root_unlock_time=)" "${PAM_FILES[@]}" 2>/dev/null || true)"

    if [ -n "$lines" ]; then
        warn "检测到 pam_faillock.so 行内参数；这些参数可能优先于 $FAILLOCK_CONF，例如 deny/unlock_time/even_deny_root。脚本不会手工修改 PAM，请人工确认策略是否符合要求。"
        echo "$lines" >&2
    fi
}

ensure_pam_pwquality() {
    # 影响说明：
    #   仅配置 pwquality.conf 不一定生效。
    #   PAM 认证栈中需要存在 pam_pwquality.so。
    #
    #   如果 system-auth / password-auth 中没有 pam_pwquality.so，
    #   脚本会在 password pam_unix.so 前插入。
    #
    # 影响范围：
    #   passwd 修改密码
    #   图形化用户管理工具
    #   其他调用 PAM 修改密码的程序

    check_pwquality_module || return 0

    if configure_authselect_pwquality_if_available; then
        if grep -q "pam_pwquality.so" /etc/pam.d/system-auth 2>/dev/null; then
            log "PAM 已通过 authselect 配置 pam_pwquality"
            return 0
        fi
    fi

    if existing_pam_module_enabled "pam_pwquality.so"; then
        log "检测到 PAM 已存在 pam_pwquality.so，保持现有 PAM 配置并继续"
        return 0
    fi

    if [ "$ALLOW_MANUAL_PAM" != "1" ]; then
        die "authselect 未能确认启用 pam_pwquality，且 ALLOW_MANUAL_PAM 未设置为 1。为避免手工改 PAM 导致认证异常，已停止。"
    fi

    for file in "${PAM_FILES[@]}"; do
        [ -f "$file" ] || {
            warn "PAM 文件不存在，跳过 pwquality 检查：$file"
            continue
        }

        backup_path "$file"

        if grep -q "pam_pwquality.so" "$file"; then
            log "$file 已存在 pam_pwquality.so，跳过"
            continue
        fi

        local tmp
        tmp="$(mktemp)"

        awk '
        BEGIN {
            inserted = 0
        }

        /^[[:space:]]*password[[:space:]].*pam_unix\.so/ && inserted == 0 {
            print "password    requisite     pam_pwquality.so try_first_pass local_users_only retry=3 authtok_type="
            print $0
            inserted = 1
            next
        }

        {
            print $0
        }

        END {
            if (inserted == 0) {
                print ""
                print "# Added by 02-configure-level3-basic.sh"
                print "password    requisite     pam_pwquality.so try_first_pass local_users_only retry=3 authtok_type="
            }
        }
        ' "$file" > "$tmp"

        cat "$tmp" > "$file"
        rm -f "$tmp"

        log "已在 $file 中启用 pam_pwquality.so"
    done
}

apply_password_policy_to_users() {
    # 影响说明：
    #   /etc/login.defs 对已存在用户不一定立即生效。
    #   所以这里使用 chage 对指定用户直接设置密码周期。
    #
    # appuser：
    #   密码最长 90 天过期
    #   至少使用 1 天后才能修改
    #   过期前 30 天提醒
    #
    # root：
    #   密码不过期
    #
    # 注意：
    #   root 密码不过期属于例外策略。
    #   如果测评要求所有账号统一 90 天过期，root 不过期可能需要单独写说明。

    if id "$APP_USER" >/dev/null 2>&1; then
        chage -M "$PASS_MAX_DAYS" -m "$PASS_MIN_DAYS" -W "$PASS_WARN_AGE" "$APP_USER"
        log "已应用普通用户密码周期到：$APP_USER"
    else
        warn "用户不存在，暂不执行 chage：$APP_USER"
    fi

    if id root >/dev/null 2>&1; then
        # 优先使用 -M -1 设置 root 密码永不过期。
        # 部分系统如果不支持 -M -1，则回退到 99999 天。
        if chage -M -1 -m 0 -E -1 root >/dev/null 2>&1; then
            log "已设置 root 用户密码不过期"
        else
            chage -M 99999 -m 0 -E -1 root
            log "已设置 root 用户密码长期不过期：99999 天"
        fi
    fi
}


# ------------------------------------------------------------------------------
# 三、配置 sudo：只有 wheel 组用户允许 sudo
# ------------------------------------------------------------------------------

check_sudo_installed() {
    # 影响说明：
    #   sudo 命令依赖 sudo 软件包。
    #   如果未安装 sudo，则无法配置 sudoers。
    if ! command -v sudo >/dev/null 2>&1; then
        die "系统未安装 sudo，请先执行：yum install -y sudo"
    fi

    if ! command -v visudo >/dev/null 2>&1; then
        die "未找到 visudo，sudo 软件包可能不完整"
    fi
}

backup_sudo_files() {
    # 影响说明：
    #   sudoers 配置错误会导致普通用户无法 sudo。
    #   修改前必须备份 /etc/sudoers 和 /etc/sudoers.d。
    backup_path "$SUDOERS_FILE"

    if [ -d "$SUDOERS_D_DIR" ]; then
        backup_path "$SUDOERS_D_DIR"
    else
        mkdir -p "$SUDOERS_D_DIR"
        chmod 0750 "$SUDOERS_D_DIR"
        log "已创建目录：$SUDOERS_D_DIR"
    fi
}

disable_extra_sudoers_d_files() {
    # 影响说明：
    #   /etc/sudoers.d/ 目录里的文件也可以授予 sudo 权限。
    #   如果只修改 /etc/sudoers，不处理 /etc/sudoers.d，则其他用户可能仍然可以 sudo。
    #
    #   本逻辑会禁用 /etc/sudoers.d/ 下除了 00-wheel-only 之外的文件。
    #   禁用方式：
    #     原文件 -> 原文件.disabled.时间戳
    #
    #   影响：
    #     如果现场已有自动化账号、业务账号依赖 /etc/sudoers.d/ 授权，会失效。
    #     后续如需恢复，可从 .bak.时间戳 或 .disabled.时间戳 文件恢复。

    [ -d "$SUDOERS_D_DIR" ] || return 0

    find "$SUDOERS_D_DIR" -maxdepth 1 -type f \
        ! -name "00-wheel-only" \
        ! -name "*.bak.*" \
        ! -name "*.disabled.*" | while read -r f; do

        backup_path "$f"
        mv "$f" "${f}.disabled.${TS}"
        log "已禁用 sudoers.d 文件：$f -> ${f}.disabled.${TS}"
    done
}

configure_sudoers_main_file() {
    # 影响说明：
    #   /etc/sudoers 是 sudo 主配置文件。
    #
    # 本脚本会保留：
    #   root    ALL=(ALL)       ALL
    #   %wheel  ALL=(ALL)       ALL
    #
    # 本脚本会注释其他直接 sudo 授权：
    #   user1   ALL=(ALL)       ALL
    #   %admin  ALL=(ALL)       ALL
    #   %sudo   ALL=(ALL)       ALL
    #
    # 结果：
    #   只有 wheel 组用户可以 sudo。
    #   普通用户 appuser 不能 sudo。

    backup_path "$SUDOERS_FILE"

    local tmp
    tmp="$(mktemp)"

    awk '
    BEGIN {
        wheel_seen = 0
        root_seen = 0
    }

    /^[[:space:]]*#/ {
        print
        next
    }

    /^[[:space:]]*$/ {
        print
        next
    }

    /^[[:space:]]*root[[:space:]]+ALL[[:space:]]*=/ {
        print "root    ALL=(ALL)       ALL"
        root_seen = 1
        next
    }

    /^[[:space:]]*%wheel[[:space:]]+ALL[[:space:]]*=/ {
        if (wheel_seen == 0) {
            print "%wheel  ALL=(ALL)       ALL"
            wheel_seen = 1
        } else {
            print "# Disabled duplicate wheel sudo rule by 02-configure-level3-basic.sh: " $0
        }
        next
    }

    /^[[:space:]]*[^#][^[:space:]]+[[:space:]]+ALL[[:space:]]*=/ {
        print "# Disabled non-wheel sudo rule by 02-configure-level3-basic.sh: " $0
        next
    }

    {
        print
    }

    END {
        if (root_seen == 0) {
            print ""
            print "# Added by 02-configure-level3-basic.sh"
            print "root    ALL=(ALL)       ALL"
        }

        if (wheel_seen == 0) {
            print ""
            print "# Added by 02-configure-level3-basic.sh"
            print "%wheel  ALL=(ALL)       ALL"
        }
    }
    ' "$SUDOERS_FILE" > "$tmp"

    # 影响说明：
    #   写入 sudoers 前必须使用 visudo 校验，避免 sudoers 语法错误导致 sudo 不可用。
    if visudo -cf "$tmp" >/dev/null 2>&1; then
        cat "$tmp" > "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        log "已配置 /etc/sudoers：仅 root 和 wheel 组允许 sudo"
    else
        rm -f "$tmp"
        die "新的 sudoers 文件语法校验失败，已停止修改"
    fi

    rm -f "$tmp"
}

create_wheel_only_sudoers_d() {
    # 影响说明：
    #   创建独立 sudoers.d 文件，明确 wheel 组拥有 sudo 权限。
    #   文件权限必须是 0440，否则 sudo 可能拒绝读取。

    cat > "$WHEEL_ONLY_FILE" <<'EOR'
# Managed by 02-configure-level3-basic.sh
#
# 影响说明：
#   只有 wheel 组用户允许使用 sudo。
#   普通用户如果没有加入 wheel 组，即使知道密码，也不能 sudo。
#
# 如需让某用户可以 sudo：
#   usermod -aG wheel 用户名
#
%wheel  ALL=(ALL)       ALL
EOR

    chmod 0440 "$WHEEL_ONLY_FILE"

    if visudo -cf "$WHEEL_ONLY_FILE" >/dev/null 2>&1; then
        log "已创建 wheel 专用 sudoers 文件：$WHEEL_ONLY_FILE"
    else
        rm -f "$WHEEL_ONLY_FILE"
        die "$WHEEL_ONLY_FILE 语法校验失败，已删除"
    fi
}

configure_sudo_wheel_only() {
    check_sudo_installed
    backup_sudo_files
    disable_extra_sudoers_d_files
    configure_sudoers_main_file
    create_wheel_only_sudoers_d

    if visudo -c >/dev/null 2>&1; then
        log "sudoers 整体语法校验通过"
    else
        die "sudoers 整体语法校验失败，请检查配置"
    fi
}


# ------------------------------------------------------------------------------
# 四、创建普通用户 appuser
# ------------------------------------------------------------------------------

create_app_user() {
    # 影响说明：
    #   创建普通用户 appuser。
    #   默认不加入 wheel 组，因此该用户不能 sudo。
    #   该用户可用于普通登录、应用运行、非特权操作。
    #
    # 安全说明：
    #   脚本内置明文密码，仅适合初始化。
    #   建议执行后修改密码：
    #     passwd appuser

    if id "$APP_USER" >/dev/null 2>&1; then
        log "用户已存在，跳过创建：$APP_USER"
    else
        useradd -m -s /bin/bash "$APP_USER"
        log "已创建普通用户：$APP_USER"
    fi

    # 设置密码。
    # 使用 printf + chpasswd，避免密码中的特殊字符被 shell 展开。
    printf '%s:%s\n' "$APP_USER" "$APP_PASSWORD" | chpasswd
    log "已设置用户密码：$APP_USER"

    # 确保 appuser 不在 wheel 组。
    # 影响说明：
    #   只有 wheel 组用户允许 sudo。
    #   appuser 是普通用户，所以这里主动从 wheel 组移除。
    if id -nG "$APP_USER" | tr ' ' '\n' | grep -qx "wheel"; then
        gpasswd -d "$APP_USER" wheel >/dev/null 2>&1 || true
        log "已从 wheel 组移除：$APP_USER"
    else
        log "$APP_USER 未加入 wheel 组，保持普通用户权限"
    fi
}


# ------------------------------------------------------------------------------
# 五、配置会话超时
# ------------------------------------------------------------------------------

configure_session_timeout() {
    # 影响说明：
    #   通过 /etc/profile.d/ 配置交互式 shell 的 TMOUT。
    #   默认 3600 秒，即 1 小时无操作后自动退出 shell。
    #   该策略主要影响 bash/sh 登录会话，对图形会话或应用自身会话不一定生效。

    if ! [[ "$SESSION_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SESSION_TIMEOUT" -le 0 ]; then
        die "SESSION_TIMEOUT 必须是大于 0 的秒数，当前值：$SESSION_TIMEOUT"
    fi

    if [ -e "$PROFILE_TIMEOUT_FILE" ]; then
        backup_path "$PROFILE_TIMEOUT_FILE"
    fi

    cat > "$PROFILE_TIMEOUT_FILE" <<EOF
# Managed by 02-configure-level3-basic.sh
# Interactive shell idle timeout: ${SESSION_TIMEOUT} seconds.

case "\$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

TMOUT=${SESSION_TIMEOUT}
readonly TMOUT
export TMOUT
EOF

    chmod 0644 "$PROFILE_TIMEOUT_FILE"
    log "已配置交互式 shell 会话超时：${SESSION_TIMEOUT} 秒"
}


# ------------------------------------------------------------------------------
# 六、配置 SSH：关闭端口转发
# ------------------------------------------------------------------------------

resolve_sshd_binary() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return 0
    fi

    if [ -x /usr/sbin/sshd ]; then
        echo "/usr/sbin/sshd"
        return 0
    fi

    if [ -x /sbin/sshd ]; then
        echo "/sbin/sshd"
        return 0
    fi

    return 1
}

set_sshd_config_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local tmp

    tmp="$(mktemp)"

    awk -v key="$key" -v value="$value" '
    BEGIN {
        inserted = 0
        lower_key = tolower(key)
    }

    {
        line = $0
        active_line = line
        sub(/^[[:space:]]*/, "", active_line)

        if (inserted == 0 && active_line ~ /^(Include|Match)[[:space:]]/) {
            print key " " value
            inserted = 1
        }

        sub(/^[[:space:]]*#[[:space:]]*/, "", line)
        split(line, parts, /[[:space:]]+/)

        if (tolower(parts[1]) == lower_key) {
            print "# Disabled " key " by 02-configure-level3-basic.sh: " $0
            next
        }

        print $0
    }

    END {
        if (inserted == 0) {
            print key " " value
        }
    }
    ' "$file" > "$tmp"

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

reload_sshd_if_requested() {
    if [ "$RELOAD_SSHD" != "1" ]; then
        warn "RELOAD_SSHD 不为 1，SSH 配置已写入但尚未 reload/restart"
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "未找到 systemctl，请手工 reload/restart sshd 使 SSH 配置生效"
        return 0
    fi

    if systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1; then
        log "已 reload SSH 服务"
    else
        warn "SSH 服务 reload 失败，请手工执行：systemctl reload sshd 或 systemctl reload ssh"
    fi
}

configure_ssh_disable_forwarding() {
    # 影响说明：
    #   关闭 SSH 端口转发、Agent 转发、X11 转发和隧道能力。
    #   这会影响依赖 ssh -L / -R / -D、ProxyJump 动态转发、远程调试隧道、
    #   X11 图形转发和 SSH Agent 转发的运维或业务场景。

    if [ ! -f "$SSHD_CONFIG" ]; then
        warn "未找到 $SSHD_CONFIG，跳过 SSH 端口转发配置"
        return 0
    fi

    local sshd_bin
    if ! sshd_bin="$(resolve_sshd_binary)"; then
        warn "未找到 sshd 命令，跳过 SSH 配置校验和端口转发配置"
        return 0
    fi

    local bak="${SSHD_CONFIG}.bak.${TS}"
    backup_path "$SSHD_CONFIG"

    set_sshd_config_value "AllowTcpForwarding" "no" "$SSHD_CONFIG"
    set_sshd_config_value "AllowStreamLocalForwarding" "no" "$SSHD_CONFIG"
    set_sshd_config_value "GatewayPorts" "no" "$SSHD_CONFIG"
    set_sshd_config_value "PermitTunnel" "no" "$SSHD_CONFIG"
    set_sshd_config_value "AllowAgentForwarding" "no" "$SSHD_CONFIG"
    set_sshd_config_value "X11Forwarding" "no" "$SSHD_CONFIG"

    if "$sshd_bin" -t -f "$SSHD_CONFIG" >/dev/null 2>&1; then
        log "SSH 配置校验通过，已关闭端口转发相关能力"
        reload_sshd_if_requested
    else
        if [ -f "$bak" ]; then
            cp -a "$bak" "$SSHD_CONFIG"
            warn "SSH 配置校验失败，已从备份恢复：$bak"
        fi
        die "SSH 配置校验失败，已停止"
    fi
}


# ------------------------------------------------------------------------------
# 七、结果展示
# ------------------------------------------------------------------------------

show_result() {
    echo
    echo "================ 登录失败锁定配置 ================"
    grep -E "^[[:space:]]*(deny|unlock_time|fail_interval)[[:space:]]*=" "$FAILLOCK_CONF" 2>/dev/null || true

    echo
    echo "================ PAM faillock 检查 ================"
    grep -R "pam_faillock.so" /etc/pam.d/system-auth /etc/pam.d/password-auth 2>/dev/null || true

    echo
    echo "================ 密码复杂度配置 ================"
    grep -E "^[[:space:]]*(minlen|dcredit|lcredit|ocredit|ucredit|retry|maxrepeat)[[:space:]]*=" "$PWQUALITY_CONF" 2>/dev/null || true

    echo
    echo "================ 密码周期默认配置 ================"
    grep -E "^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]+" "$LOGIN_DEFS" 2>/dev/null || true

    echo
    echo "================ appuser 密码周期 ================"
    chage -l "$APP_USER" 2>/dev/null || true

    echo
    echo "================ root 密码周期 ================"
    chage -l root 2>/dev/null || true

    echo
    echo "================ sudo 权限检查 ================"
    echo "wheel 组成员："
    getent group wheel || true

    echo
    echo "sudoers wheel 规则："
    grep -R "^[[:space:]]*%wheel[[:space:]]" /etc/sudoers /etc/sudoers.d 2>/dev/null || true

    echo
    echo "================ 用户检查 ================"
    id "$APP_USER" || true

    echo
    echo "================ 会话超时配置 ================"
    grep -E "^[[:space:]]*(TMOUT|readonly TMOUT|export TMOUT)" "$PROFILE_TIMEOUT_FILE" 2>/dev/null || true

    echo
    echo "================ SSH 端口转发配置 ================"
    grep -Ei "^[[:space:]]*(AllowTcpForwarding|AllowStreamLocalForwarding|GatewayPorts|PermitTunnel|AllowAgentForwarding|X11Forwarding)[[:space:]]+" "$SSHD_CONFIG" 2>/dev/null || true

    echo
    echo "================ 影响说明 ================"
    echo "1. ${FAIL_INTERVAL} 秒内登录失败 ${DENY} 次，会锁定 ${UNLOCK_TIME} 秒。"
    echo "2. 登录失败锁定影响 SSH、su、控制台登录、图形化登录等 PAM 认证。"
    echo "3. 普通用户密码最长 ${PASS_MAX_DAYS} 天过期，至少使用 ${PASS_MIN_DAYS} 天后才能修改，过期前 ${PASS_WARN_AGE} 天提醒。"
    echo "4. root 用户密码设置为不过期。"
    echo "5. 密码最小长度 ${PASS_MIN_LEN}，要求数字、小写、特殊字符，不强制大写。"
    echo "6. 只有 wheel 组用户允许使用 sudo。"
    echo "7. ${APP_USER} 是普通用户，默认不能 sudo。"
    echo "8. /etc/sudoers.d/ 下其他 sudo 授权文件已被禁用，可能影响已有自动化账号。"
    echo "9. 交互式 shell 会话超时为 ${SESSION_TIMEOUT} 秒。"
    echo "10. SSH 端口转发、Agent 转发、X11 转发和隧道能力已关闭。"
    echo "11. 修改文件已在原目录生成 .bak.${TS} 备份。"

    echo
    echo "================ 常用命令 ================"
    echo "让 ${APP_USER} 可以 sudo：usermod -aG wheel ${APP_USER}"
    echo "确认 ${APP_USER} 是否在 wheel：id ${APP_USER}"
    echo "查看用户锁定状态：faillock --user ${APP_USER}"
    echo "解锁用户：faillock --user ${APP_USER} --reset"
    echo "修改 ${APP_USER} 密码：passwd ${APP_USER}"
    echo "查看 root 密码周期：chage -l root"
    echo "查看 SSH 配置是否有效：sshd -t -f ${SSHD_CONFIG}"
}


# ------------------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------------------

main() {
    require_root

    check_pam_faillock_module
    configure_faillock_conf
    configure_pam_faillock

    configure_password_policy
    ensure_pam_pwquality

    configure_sudo_wheel_only

    create_app_user
    apply_password_policy_to_users

    configure_session_timeout
    configure_ssh_disable_forwarding

    show_result

    log "02 完成：等保三级基础配置已完成。下一步执行 scripts/03-configure-virtio-initramfs.sh"
}

main "$@"
