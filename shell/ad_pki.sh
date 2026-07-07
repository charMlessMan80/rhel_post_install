#!/bin/bash
#
# RHEL 9 - Post-Installation Configuration Script
# Translation of main.yml + all tasks/*.yml into pure bash.
# Run as root on the target RHEL 9 host.
#
set -euo pipefail

# ============================================================================
# Configuration - edit these variables before running
# (Mirrors inventory/hosts.ini [rhel9_hosts:vars])
# ============================================================================

# --- Hostname ---------------------------------------------------------------
INVENTORY_HOSTNAME="$(hostname -s)"                     # e.g. "rhel9host1", should match inventory hostname

# --- DNS (DNS_config.yml) ---------------------------------------------------
DNS_SERVERS=("8.8.8.8" "8.8.4.4")                  # empty array = skip module
DNS_SEARCH_DOMAINS=("example.com")                 # empty array = skip module

# --- Red Hat Subscription Manager (RHSM_config.yml) -------------------------
RHSM_USERNAME=""                                   # leave empty to skip module
RHSM_PASSWORD=""
RHSM_AUTO_ATTACH=true
RHSM_REPOS=("rhel-9-for-x86_64-baseos-rpms" "rhel-9-for-x86_64-appstream-rpms")                                      # e.g. ("rhel-9-for-x86_64-baseos-rpms")
RHSM_PROXY_HOSTNAME=""                             # e.g. "proxy.example.com" - empty = skip
RHSM_PROXY_PORT=""                                 # e.g. "3128" - empty = skip

# --- NTP (NTP_config.yml) ---------------------------------------------------
NTP_SERVERS=("0.rhel.pool.ntp.org" "1.rhel.pool.ntp.org" "2.rhel.pool.ntp.org") # empty array = skip module
NTP_TIMEZONE="UTC"                                 # e.g. "America/New_York", leave empty to skip timezone config

# --- Active Directory (AD_join.yml) -----------------------------------------
AD_DOMAIN="example.com"
AD_JOIN_USER="admin"
AD_JOIN_PASSWORD=''                                # leave empty to be prompted
AD_OU=""                                           # e.g. "OU=Servers,DC=example,DC=com"
AD_ALLOWED_GROUPS=("linux-admins" "linux-users")

# --- AD CS / certmonger (PKI_enrolment.yml) ---------------------------------
ADCS_CA_NAME="cepces"                              # certmonger CA registered by the cepces package
ADCS_HOST=""                                      # leave empty to skip module (e.g. "ca.example.com")
ADCS_TEMPLATE="Machine"
ADCS_ROOT_CA_CERT=""                               # local path to .crt (optional)

# --- Local admin (local_admin.yml) ------------------------------------------
LOCAL_ADMIN_USER="localadmin"
LOCAL_ADMIN_PASSWORD=''                            # leave empty to skip module
LOCAL_ADMIN_SSH_KEY=""

# --- GRUB (secure_grub.yml) -------------------------------------------------
GRUB_SUPERUSER="grubadmin"
GRUB_PASSWORD=''                                   # leave empty to skip module

# --- Firewall (firewall_config.yml) -----------------------------------------
SSH_ALLOWED_IPS=("10.0.0.0/24" "192.168.1.0/24")   # empty array = skip module
FIREWALL_ZONE="public"

# ============================================================================
# Derived values & helpers
# ============================================================================
FQDN="${INVENTORY_HOSTNAME}.${AD_DOMAIN}"
KRB_REALM="${AD_DOMAIN^^}"
CERT_KEY_PATH="/etc/pki/tls/private/${FQDN}.key"
CERT_PATH="/etc/pki/tls/certs/${FQDN}.crt"
CERT_KEY_SIZE=2048

log()    { echo "[$(date +%H:%M:%S)] $*"; }
phase()  { echo; echo "===== $* ====="; }
warn()   { echo "WARNING: $*" >&2; }
fatal()  { echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    fatal "This script must be run as root."
fi

if ! grep -q "release 9" /etc/redhat-release 2>/dev/null; then
    warn "Not RHEL 9 - some modules may not behave as expected."
fi

# ============================================================================
# Module: set_hostname.yml
# ============================================================================
phase "Hostname configuration"

# Task: Set hostname
hostnamectl set-hostname "${FQDN}"

# Task: Ensure hostname is in /etc/hosts (lineinfile regexp ^\s*127\.0\.0\.1)
if grep -qP '^\s*127\.0\.0\.1' /etc/hosts; then
    sed -i -E "s|^\s*127\.0\.0\.1.*|127.0.0.1 ${INVENTORY_HOSTNAME} ${FQDN}|" /etc/hosts
else
    echo "127.0.0.1  ${INVENTORY_HOSTNAME} ${FQDN}" >> /etc/hosts
fi

# Task: Verify hostname / Display hostname status
hostnamectl status

# ============================================================================
# Module: DNS_config.yml
# ============================================================================
NM_ACTIVE_CONN=""
NM_RESTART_PENDING=false

if [[ ${#DNS_SERVERS[@]} -eq 0 && ${#DNS_SEARCH_DOMAINS[@]} -eq 0 ]]; then
    log "Skipping DNS configuration module (DNS_SERVERS and DNS_SEARCH_DOMAINS empty)."
else
    phase "DNS configuration"

    # Task: Get active NetworkManager connection
    NM_ACTIVE_CONN="$(nmcli -t -f NAME con show --active | head -n1 || true)"

    # Task: Set DNS servers via NetworkManager
    if [[ -n "${NM_ACTIVE_CONN}" ]]; then
        if [[ ${#DNS_SERVERS[@]} -gt 0 ]]; then
            nmcli con mod "${NM_ACTIVE_CONN}" ipv4.dns "${DNS_SERVERS[*]}"
        fi
        if [[ ${#DNS_SEARCH_DOMAINS[@]} -gt 0 ]]; then
            nmcli con mod "${NM_ACTIVE_CONN}" ipv4.dns-search "${DNS_SEARCH_DOMAINS[*]}"
        fi
        NM_RESTART_PENDING=true
    else
        warn "No active NetworkManager connection - skipping DNS via nmcli."
    fi

    # Task: Ensure NetworkManager manages resolv.conf
    mkdir -p /etc/NetworkManager/conf.d
    install -o root -g root -m 0644 /dev/null /etc/NetworkManager/conf.d/dns.conf
    {
        echo "[main]"
        echo "dns=default"
    } > /etc/NetworkManager/conf.d/dns.conf

    # Task: Reload NetworkManager to apply DNS settings
    systemctl reload NetworkManager

    # Flush handler: restart_networkmanager
    if [[ "${NM_RESTART_PENDING}" == true ]]; then
        systemctl restart NetworkManager
        NM_RESTART_PENDING=false
    fi

    # Task: Verify DNS resolution / Display result
    host google.com || warn "DNS resolution test failed."
fi

# ============================================================================
# Module: RHSM_config.yml   (when: rhsm_username is defined and rhsm_password is defined)
# ============================================================================
if [[ -n "${RHSM_USERNAME}" && -n "${RHSM_PASSWORD}" ]]; then
    phase "Red Hat Subscription Manager"

    # Task: Configure proxy in /etc/rhsm/rhsm.conf
    RHSM_CONF="/etc/rhsm/rhsm.conf"
    if [[ -n "${RHSM_PROXY_HOSTNAME}" ]]; then
        if grep -qE '^\s*proxy_hostname\s*=' "${RHSM_CONF}"; then
            sed -i -E "s|^\s*proxy_hostname\s*=.*|proxy_hostname = ${RHSM_PROXY_HOSTNAME}|" "${RHSM_CONF}"
        else
            echo "proxy_hostname = ${RHSM_PROXY_HOSTNAME}" >> "${RHSM_CONF}"
        fi
    fi
    if [[ -n "${RHSM_PROXY_PORT}" ]]; then
        if grep -qE '^\s*proxy_port\s*=' "${RHSM_CONF}"; then
            sed -i -E "s|^\s*proxy_port\s*=.*|proxy_port = ${RHSM_PROXY_PORT}|" "${RHSM_CONF}"
        else
            echo "proxy_port = ${RHSM_PROXY_PORT}" >> "${RHSM_CONF}"
        fi
    fi

    # Task: Check if system is already registered
    set +e
    subscription-manager identity >/dev/null 2>&1
    RHSM_IDENTITY_RC=$?
    set -e

    # Task: Register with Red Hat Subscription Manager
    if [[ ${RHSM_IDENTITY_RC} -ne 0 ]]; then
        REG_ARGS=(--username="${RHSM_USERNAME}" --password="${RHSM_PASSWORD}")
        if [[ "${RHSM_AUTO_ATTACH}" == true ]]; then
            REG_ARGS+=(--auto-attach)
        fi
        subscription-manager register "${REG_ARGS[@]}"
    fi

    # Task: Enable specific repositories
    if [[ ${#RHSM_REPOS[@]} -gt 0 ]]; then
        for repo in "${RHSM_REPOS[@]}"; do
            subscription-manager repos --enable="${repo}"
        done
    fi

    # Task: Verify subscription status / Display
    subscription-manager status || true
else
    log "Skipping RHSM module (rhsm_username/rhsm_password not set)."
fi

# ============================================================================
# Module: kernel_hotpatch.yml   (when: RHEL 9)
# ============================================================================
if grep -q "release 9" /etc/redhat-release 2>/dev/null; then
    phase "Kernel hot patching"

    # Task: Install kpatch and kpatch-dnf
    dnf install -y kpatch kpatch-dnf

    # Task: Enable kpatch-dnf plugin
    set +e
    KPATCH_AUTO_OUT="$(dnf kpatch auto -y 2>&1)"
    set -e
    echo "${KPATCH_AUTO_OUT}"

    # Task: Check for available kpatch modules
    kpatch list || true

    # Task: Install available kpatch modules (state: latest)
    KPATCH_BEFORE="$(rpm -qa 'kpatch-patch-*' | sort)"
    dnf install -y 'kpatch-patch-*' || true
    KPATCH_AFTER="$(rpm -qa 'kpatch-patch-*' | sort)"

    # Task: Load all installed kpatch modules (when: kpatch_install.changed)
    if [[ "${KPATCH_BEFORE}" != "${KPATCH_AFTER}" ]]; then
        kpatch load --all || true
    fi

    # Task: Verify loaded kpatch modules / Display
    kpatch list || true
else
    log "Skipping kernel hot patching module (not RHEL 9)."
fi

# ============================================================================
# Module: packages_update.yml
# ============================================================================
phase "Package updates"

# Task: Check for available kernel updates / Determine if kernel update pending
KERNEL_UPDATE_PENDING=false
if dnf -q list --upgrades kernel 2>/dev/null | awk '{print $1}' | grep -qx 'kernel'; then
    KERNEL_UPDATE_PENDING=true
fi

# Task: Update all packages
dnf -y update

# Task: Reboot if kernel was updated / Wait for system to come back online
if [[ "${KERNEL_UPDATE_PENDING}" == true ]]; then
    warn "Kernel was updated. The system needs to reboot to complete this module."
    warn "Bash cannot resume after reboot like Ansible does - rerun the script after the host is back."
    log "Rebooting in 10 seconds (pre_reboot_delay)..."
    sleep 10
    systemctl reboot
    exit 0
fi

# Task: Verify running kernel version / Display
uname -r

# ============================================================================
# Module: NTP_config.yml
# ============================================================================
if [[ ${#NTP_SERVERS[@]} -eq 0 && -z "${NTP_TIMEZONE}" ]]; then
    log "Skipping NTP module (NTP_SERVERS and NTP_TIMEZONE empty)."
else
    phase "NTP / chrony"

    # Task: Install chrony
    dnf install -y chrony

    # Task: Set timezone
    if [[ -n "${NTP_TIMEZONE}" ]]; then
        timedatectl set-timezone "${NTP_TIMEZONE}"
    fi

    if [[ ${#NTP_SERVERS[@]} -gt 0 ]]; then
        # Task: Remove default pool/server entries
        sed -i -E '/^pool[[:space:]]+/d;  /^server[[:space:]]+/d' /etc/chrony.conf

        # Task: Configure NTP servers
        for s in "${NTP_SERVERS[@]}"; do
            echo "server ${s} iburst" >> /etc/chrony.conf
        done

        # Task: Enable NTP makestep for initial large offset
        if grep -qE '^makestep' /etc/chrony.conf; then
            sed -i -E 's|^makestep.*|makestep 1.0 3|' /etc/chrony.conf
        else
            echo "makestep 1.0 3" >> /etc/chrony.conf
        fi

        # Task: Enable and restart chronyd
        systemctl enable chronyd
        systemctl restart chronyd

        # Task: Wait for chrony to sync / Display
        chronyc tracking || true
    fi
fi

# ============================================================================
# Module: AD_join.yml
# ============================================================================
phase "Active Directory join"

# Task: Install required packages for AD join
dnf install -y \
    realmd \
    oddjob \
    oddjob-mkhomedir \
    sssd \
    sssd-tools \
    adcli \
    krb5-workstation \
    samba-common-tools \
    NetworkManager

# Task: Check if already joined to domain
REALM_LIST_OUTPUT="$(realm list 2>/dev/null || true)"

# Task: Discover the Active Directory domain
if ! grep -q "${AD_DOMAIN}" <<<"${REALM_LIST_OUTPUT}"; then
    realm discover "${AD_DOMAIN}"
fi

# Task: Join the host to the AD domain
if ! grep -q "${AD_DOMAIN}" <<<"${REALM_LIST_OUTPUT}"; then
    if [[ -z "${AD_JOIN_PASSWORD}" ]]; then
        read -rsp "Password for ${AD_JOIN_USER}@${AD_DOMAIN}: " AD_JOIN_PASSWORD
        echo
    fi
    JOIN_ARGS=(--user="${AD_JOIN_USER}")
    if [[ -n "${AD_OU}" ]]; then
        JOIN_ARGS+=(--computer-ou="${AD_OU}")
    fi
    echo "${AD_JOIN_PASSWORD}" | realm join --automatic-id-mapping=no "${JOIN_ARGS[@]}" "${AD_DOMAIN}"
fi

# Task: Verify the host is joined to the domain
realm list | grep -q "${AD_DOMAIN}" || fatal "Domain join verification failed."

# Task: Enable automatic home directory creation
authselect select sssd with-mkhomedir --force

# Task: Start and enable the oddjobd service
systemctl enable --now oddjobd

# Task: Configure realm to deny all users by default
realm deny --all

# Task: Allow specific AD groups to log in
if [[ ${#AD_ALLOWED_GROUPS[@]} -gt 0 ]]; then
    for g in "${AD_ALLOWED_GROUPS[@]}"; do
        realm permit -g "${g}"
    done
fi

# Task: Configure SSSD for AD (blockinfile equivalent)
SSSD_CONF="/etc/sssd/sssd.conf"
SSSD_BEGIN="# BEGIN ANSIBLE MANAGED - AD CONFIG"
SSSD_END="# END ANSIBLE MANAGED - AD CONFIG"
touch "${SSSD_CONF}"
chmod 600 "${SSSD_CONF}"
SSSD_CHANGED=false
if grep -qF "${SSSD_BEGIN}" "${SSSD_CONF}"; then
    sed -i "/${SSSD_BEGIN}/,/${SSSD_END}/d" "${SSSD_CONF}"
fi
{
    echo "${SSSD_BEGIN}"
    echo "ldap_tls_reqcert = demand"
    echo "ad_gpo_access_control = enforcing"
    echo "fallback_homedir = /home/%u@%d"
    echo "default_shell = /bin/bash"
    echo "# DNS dynamic update"
    echo "dyndns_update = true"
    echo "dyndns_refresh_interval = 43200"
    echo "dyndns_update_ptr = true"
    echo "dyndns_auth = GSS-TSIG"
    echo "dyndns_ttl = 3600"
    echo "${SSSD_END}"
} >> "${SSSD_CONF}"
SSSD_CHANGED=true

# Task: Start and enable SSSD
systemctl enable --now sssd

# Flush handler: restart_sssd
if [[ "${SSSD_CHANGED}" == true ]]; then
    systemctl restart sssd
fi

# ============================================================================
# Module: PKI_enrolment.yml   (when: ADCS_HOST is set)
# ============================================================================
if [[ -n "${ADCS_HOST}" ]]; then
    phase "AD CS certificate enrollment (certmonger)"

    CEPCES_ENDPOINT="https://${ADCS_HOST}/ADPolicyProvider_CEP_Kerberos/service.svc/CEP"

    # Task: Install certmonger and cepces dependencies
    dnf install -y certmonger cepces ca-certificates crudini

    # Task: Start and enable certmonger
    systemctl enable --now certmonger

    # Task: Import AD CS root CA certificate
    CA_TRUST_PENDING=false
    if [[ -n "${ADCS_ROOT_CA_CERT}" ]]; then
        [[ -f "${ADCS_ROOT_CA_CERT}" ]] || fatal "ADCS_ROOT_CA_CERT '${ADCS_ROOT_CA_CERT}' not found."
        install -o root -g root -m 0644 "${ADCS_ROOT_CA_CERT}" /etc/pki/ca-trust/source/anchors/adcs-root-ca.crt
        CA_TRUST_PENDING=true
    fi

    # Flush handler: update_ca_trust
    if [[ "${CA_TRUST_PENDING}" == true ]]; then
        update-ca-trust extract
    fi

    # Task: Configure cepces CEP endpoint and authentication
    mkdir -p /etc/cepces
    CEPCES_CONF="/etc/cepces/cepces.conf"
    touch "${CEPCES_CONF}"
    chmod 0644 "${CEPCES_CONF}"
    crudini --set "${CEPCES_CONF}" global endpoint "${CEPCES_ENDPOINT}" \
        && crudini --set "${CEPCES_CONF}" global auth Kerberos \
        && crudini --set "${CEPCES_CONF}" kerberos realm "${KRB_REALM}"

    # Task: Check that the cepces CA is registered in certmonger
    CERTMONGER_CAS="$(getcert list-cas 2>/dev/null || true)"
    if ! grep -q "${ADCS_CA_NAME}" <<<"${CERTMONGER_CAS}"; then
        fatal "The '${ADCS_CA_NAME}' CA is not registered in certmonger. Ensure the cepces package is installed correctly."
    fi

    # Task: Check if certificate already tracked
    set +e
    getcert list -f "${CERT_PATH}" >/dev/null 2>&1
    GETCERT_RC=$?
    set -e

    # Task: Request certificate from AD CS via certmonger (CES)
    if [[ ${GETCERT_RC} -ne 0 ]]; then
        getcert request \
            -c "${ADCS_CA_NAME}" \
            -k "${CERT_KEY_PATH}" \
            -f "${CERT_PATH}" \
            -g "${CERT_KEY_SIZE}" \
            -N "CN=${FQDN}" \
            -D "${FQDN}" \
            -K "host/${FQDN}@${KRB_REALM}" \
            -T "${ADCS_TEMPLATE}" \
            -C "systemctl reload httpd || true"
    fi

    # Task: Wait for certificate issuance (retries=12, delay=5)
    for i in $(seq 1 12); do
        if getcert list -f "${CERT_PATH}" 2>/dev/null | grep -q "MONITORING"; then
            break
        fi
        if [[ ${i} -eq 12 ]]; then
            getcert list -f "${CERT_PATH}" || true
            fatal "Certificate not in MONITORING state after 60s."
        fi
        sleep 5
    done

    # Task: Verify certificate file exists
    [[ -f "${CERT_PATH}" ]] || fatal "Certificate file '${CERT_PATH}' not found."

    # Task: Display certificate info
    openssl x509 -in "${CERT_PATH}" -noout -subject -issuer -dates
else
    log "Skipping PKI enrolment module (ADCS_HOST not set)."
fi

# ============================================================================
# Module: local_admin.yml   (when: local_admin_password is defined)
# ============================================================================
if [[ -n "${LOCAL_ADMIN_PASSWORD}" ]]; then
    phase "Local admin account"

    # Task: Create local admin user (password hashed with sha512)
    HASHED_PW="$(openssl passwd -6 "${LOCAL_ADMIN_PASSWORD}")"
    if id -u "${LOCAL_ADMIN_USER}" >/dev/null 2>&1; then
        usermod -aG wheel -s /bin/bash -p "${HASHED_PW}" "${LOCAL_ADMIN_USER}"
    else
        useradd -m -s /bin/bash -G wheel -p "${HASHED_PW}" "${LOCAL_ADMIN_USER}"
    fi

    # Task: Ensure wheel group has sudo privileges (with visudo validate)
    SUDO_FILE="/etc/sudoers.d/${LOCAL_ADMIN_USER}"
    SUDO_LINE="${LOCAL_ADMIN_USER} ALL=(ALL) NOPASSWD: ALL"
    SUDO_TMP="$(mktemp)"
    if [[ -f "${SUDO_FILE}" ]] && grep -qF "${SUDO_LINE}" "${SUDO_FILE}"; then
        :
    else
        printf '%s\n' "${SUDO_LINE}" > "${SUDO_TMP}"
        chmod 0440 "${SUDO_TMP}"
        visudo -cf "${SUDO_TMP}" >/dev/null
        install -o root -g root -m 0440 "${SUDO_TMP}" "${SUDO_FILE}"
    fi
    rm -f "${SUDO_TMP}"

    # Task: Add SSH authorized key for local admin
    if [[ -n "${LOCAL_ADMIN_SSH_KEY}" ]]; then
        ADMIN_HOME="$(getent passwd "${LOCAL_ADMIN_USER}" | cut -d: -f6)"
        install -d -o "${LOCAL_ADMIN_USER}" -g "${LOCAL_ADMIN_USER}" -m 0700 "${ADMIN_HOME}/.ssh"
        AUTH_KEYS="${ADMIN_HOME}/.ssh/authorized_keys"
        touch "${AUTH_KEYS}"
        chown "${LOCAL_ADMIN_USER}:${LOCAL_ADMIN_USER}" "${AUTH_KEYS}"
        chmod 0600 "${AUTH_KEYS}"
        if ! grep -qF "${LOCAL_ADMIN_SSH_KEY}" "${AUTH_KEYS}"; then
            echo "${LOCAL_ADMIN_SSH_KEY}" >> "${AUTH_KEYS}"
        fi
    fi

    # Task: Verify local admin account / Display
    id "${LOCAL_ADMIN_USER}"
else
    log "Skipping local admin module (local_admin_password not set)."
fi

# ============================================================================
# Module: ssh_hardening.yml   (when: LOCAL_ADMIN_PASSWORD is set)
# Skipped when no local admin exists to avoid being locked out via SSH.
# ============================================================================
if [[ -n "${LOCAL_ADMIN_PASSWORD}" ]]; then
    phase "SSH hardening (disable root login)"

    SSHD_RESTART_PENDING=false

    # Task: Disable root login via SSH (lineinfile with sshd validate)
    SSHD_CONF="/etc/ssh/sshd_config"
    SSHD_TMP="$(mktemp)"
    cp "${SSHD_CONF}" "${SSHD_TMP}"
    if grep -qE '^#?\s*PermitRootLogin' "${SSHD_TMP}"; then
        sed -i -E 's|^#?\s*PermitRootLogin.*|PermitRootLogin no|' "${SSHD_TMP}"
    else
        echo "PermitRootLogin no" >> "${SSHD_TMP}"
    fi
    sshd -t -f "${SSHD_TMP}"
    if ! cmp -s "${SSHD_TMP}" "${SSHD_CONF}"; then
        install -o root -g root -m 0600 "${SSHD_TMP}" "${SSHD_CONF}"
        SSHD_RESTART_PENDING=true
    fi
    rm -f "${SSHD_TMP}"

    # Task: Disable root login in sshd_config.d drop-ins
    DROPIN="/etc/ssh/sshd_config.d/01-permitrootlogin.conf"
    DROPIN_TMP="$(mktemp)"
    if [[ -f "${DROPIN}" ]]; then
        cp "${DROPIN}" "${DROPIN_TMP}"
    fi
    if grep -qE '^PermitRootLogin' "${DROPIN_TMP}" 2>/dev/null; then
        sed -i -E 's|^PermitRootLogin.*|PermitRootLogin no|' "${DROPIN_TMP}"
    else
        echo "PermitRootLogin no" >> "${DROPIN_TMP}"
    fi
    sshd -t -f "${DROPIN_TMP}"
    if [[ ! -f "${DROPIN}" ]] || ! cmp -s "${DROPIN_TMP}" "${DROPIN}"; then
        install -o root -g root -m 0600 "${DROPIN_TMP}" "${DROPIN}"
        SSHD_RESTART_PENDING=true
    fi
    rm -f "${DROPIN_TMP}"

    # Task: Verify SSH root login is disabled / Display
    sshd -T 2>/dev/null | grep -i '^permitrootlogin' || true

    # Flush handler: restart_sshd
    if [[ "${SSHD_RESTART_PENDING}" == true ]]; then
        systemctl restart sshd
    fi
else
    log "Skipping SSH hardening module (LOCAL_ADMIN_PASSWORD not set; would risk lockout)."
fi

# ============================================================================
# Module: secure_root.yml   (when: LOCAL_ADMIN_PASSWORD is set)
# Skipped when no local admin exists to avoid being locked out of root.
# ============================================================================
if [[ -n "${LOCAL_ADMIN_PASSWORD}" ]]; then
    phase "Secure root shell access"

    # Task: Set root shell to /sbin/nologin
    usermod -s /sbin/nologin root

    # Task: Lock root account password
    passwd -l root >/dev/null

    # Task: Restrict su to wheel group only
    PAM_SU="/etc/pam.d/su"
    if grep -qE '^#?\s*auth\s+required\s+pam_wheel\.so\s+use_uid' "${PAM_SU}"; then
        sed -i -E 's|^#?\s*auth\s+required\s+pam_wheel\.so\s+use_uid.*|auth           required        pam_wheel.so use_uid|' "${PAM_SU}"
    else
        echo "auth           required        pam_wheel.so use_uid" >> "${PAM_SU}"
    fi

    # Task: Restrict access to root cron (failed_when: false)
    for f in /etc/crontab /var/spool/cron/root; do
        if [[ -e "${f}" ]]; then
            chown root:root "${f}"
            chmod 0600 "${f}"
        fi
    done

    # Task: Disable root login on all TTYs via securetty (force empty file)
    install -o root -g root -m 0600 /dev/null /etc/securetty

    # Task: Verify root shell setting / Display
    getent passwd root
else
    log "Skipping secure root module (LOCAL_ADMIN_PASSWORD not set; would risk lockout)."
fi

# ============================================================================
# Module: secure_grub.yml   (when: grub_password is defined)
# ============================================================================
if [[ -n "${GRUB_PASSWORD}" ]]; then
    phase "GRUB password protection"

    GRUB_RECONFIG_PENDING=false

    # Task: Generate GRUB password hash
    GRUB_HASH_OUT="$(printf '%s\n%s\n' "${GRUB_PASSWORD}" "${GRUB_PASSWORD}" | grub2-mkpasswd-pbkdf2)"
    GRUB_PASSWORD_HASH="$(grep -oE 'grub\.pbkdf2\.sha512\.[^[:space:]]+' <<<"${GRUB_HASH_OUT}" | head -n1)"
    [[ -n "${GRUB_PASSWORD_HASH}" ]] || fatal "Failed to extract GRUB pbkdf2 hash."

    # Task: Configure GRUB superuser and password
    # /etc/grub.d/01_users is executed by grub2-mkconfig; its stdout becomes
    # the grub.cfg snippet. It must be a shell script, not raw GRUB directives.
    GRUB_USERS="/etc/grub.d/01_users"
    GRUB_USERS_TMP="$(mktemp)"
    cat > "${GRUB_USERS_TMP}" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# This file provides an easy way to add custom users to the grub bootloader.
set superusers="${GRUB_SUPERUSER}"
password_pbkdf2 ${GRUB_SUPERUSER} ${GRUB_PASSWORD_HASH}
EOF
    if [[ ! -f "${GRUB_USERS}" ]] || ! cmp -s "${GRUB_USERS_TMP}" "${GRUB_USERS}"; then
        install -o root -g root -m 0700 "${GRUB_USERS_TMP}" "${GRUB_USERS}"
        GRUB_RECONFIG_PENDING=true
    fi
    rm -f "${GRUB_USERS_TMP}"

    # Task: Allow normal boot without password (lineinfile with backrefs)
    GRUB_LINUX="/etc/grub.d/10_linux"
    if grep -qE '^\s*CLASS="--class gnu-linux' "${GRUB_LINUX}"; then
        if ! grep -qE '^\s*CLASS=".*--unrestricted"' "${GRUB_LINUX}"; then
            sed -i -E 's|^\s*CLASS="--class gnu-linux.*|CLASS="--class gnu-linux --class gnu --class os --unrestricted"|' "${GRUB_LINUX}"
            GRUB_RECONFIG_PENDING=true
        fi
    fi

    # Task: Verify GRUB user config exists / Display
    if [[ -f "${GRUB_USERS}" ]]; then
        echo "GRUB password protection is enabled"
    else
        echo "GRUB password protection is not configured"
    fi

    # Flush handler: regenerate_grub
    if [[ "${GRUB_RECONFIG_PENDING}" == true ]]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
else
    log "Skipping GRUB password module (grub_password not set)."
fi

# ============================================================================
# Module: disable_interactive_startup.yml
# ============================================================================
phase "Disable interactive startup"

GRUB_RECONFIG_PENDING=false

# Task: Disable systemd debug shell (failed_when: false)
systemctl stop debug-shell.service 2>/dev/null || true
systemctl disable debug-shell.service 2>/dev/null || true
systemctl mask debug-shell.service 2>/dev/null || true

# Task: Read current GRUB_CMDLINE_LINUX
GRUB_DEFAULT="/etc/default/grub"
GRUB_CMDLINE_CUR="$(grep '^GRUB_CMDLINE_LINUX=' "${GRUB_DEFAULT}" || true)"

# Task: Remove interactive boot parameters from GRUB defaults
GRUB_CMDLINE_NEW="$(sed -E \
    -e 's|rd\.break[[:space:]]*||g' \
    -e 's|init=/bin/sh[[:space:]]*||g' \
    -e 's|systemd\.confirm_spawn[[:space:]]*||g' \
    <<<"${GRUB_CMDLINE_CUR}")"
if [[ "${GRUB_CMDLINE_NEW}" != "${GRUB_CMDLINE_CUR}" ]]; then
    # Replace in-place using a delimiter unlikely to appear in the value
    awk -v new="${GRUB_CMDLINE_NEW}" '
        /^GRUB_CMDLINE_LINUX=/ { print new; next }
        { print }
    ' "${GRUB_DEFAULT}" > "${GRUB_DEFAULT}.new"
    mv "${GRUB_DEFAULT}.new" "${GRUB_DEFAULT}"
    chown root:root "${GRUB_DEFAULT}"
    chmod 0644 "${GRUB_DEFAULT}"
    GRUB_RECONFIG_PENDING=true
fi

# Task: Disable Ctrl+Alt+Del reboot
# Masking the target alone is not enough: systemd's CtrlAltDelBurstAction
# (default: reboot-force) still triggers a forced reboot after 7 presses
# within 2s. Set it to none. system.conf is only re-read by PID 1 on
# daemon-reexec (daemon-reload does NOT reload it).
# Note: ctrl-alt-del.target is an alias of reboot.target, so we mask it by
# creating an explicit /dev/null symlink in /etc/systemd/system/ (this is
# what `systemctl mask` does internally and is the most reliable method).
ln -sf /dev/null /etc/systemd/system/ctrl-alt-del.target
SYSTEMD_CONF="/etc/systemd/system.conf"
if grep -qE '^\s*#?\s*CtrlAltDelBurstAction\s*=' "${SYSTEMD_CONF}"; then
    sed -i -E 's|^\s*#?\s*CtrlAltDelBurstAction\s*=.*|CtrlAltDelBurstAction=none|' "${SYSTEMD_CONF}"
else
    echo "CtrlAltDelBurstAction=none" >> "${SYSTEMD_CONF}"
fi
systemctl daemon-reexec

# Task: Disable emergency and rescue mode targets
for unit in emergency.service rescue.service; do
    systemctl mask "${unit}" 2>/dev/null || true
done

# Task: Disable SysRq key (sysctl persistent + reload)
SYSRQ_FILE="/etc/sysctl.d/99-disable-sysrq.conf"
if [[ ! -f "${SYSRQ_FILE}" ]] || ! grep -qE '^kernel\.sysrq\s*=\s*0' "${SYSRQ_FILE}"; then
    echo "kernel.sysrq = 0" > "${SYSRQ_FILE}"
    chown root:root "${SYSRQ_FILE}"
    chmod 0644 "${SYSRQ_FILE}"
fi
sysctl --system >/dev/null

# Task: Verify interactive startup is disabled / Display
DEBUG_SHELL_STATUS="$(systemctl is-enabled debug-shell.service 2>/dev/null || echo masked)"
echo "debug-shell: ${DEBUG_SHELL_STATUS}, SysRq: disabled, Ctrl+Alt+Del: masked"

# Flush handler: regenerate_grub
if [[ "${GRUB_RECONFIG_PENDING}" == true ]]; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
fi

# ============================================================================
# Module: firewall_config.yml   (when: ssh_allowed_ips is defined and length > 0)
# ============================================================================
if [[ ${#SSH_ALLOWED_IPS[@]} -gt 0 ]]; then
    phase "Firewall configuration"

    # Task: Install firewalld
    dnf install -y firewalld

    # Task: Start and enable firewalld
    systemctl enable --now firewalld

    # Task: Remove default SSH service from zone (permanent + immediate)
    firewall-cmd --permanent --zone="${FIREWALL_ZONE}" --remove-service=ssh 2>/dev/null || true
    firewall-cmd --zone="${FIREWALL_ZONE}" --remove-service=ssh 2>/dev/null || true

    # Task: Allow SSH from trusted IPs only (rich_rule loop)
    for ip in "${SSH_ALLOWED_IPS[@]}"; do
        RULE="rule family=\"ipv4\" source address=\"${ip}\" port port=\"22\" protocol=\"tcp\" accept"
        firewall-cmd --permanent --zone="${FIREWALL_ZONE}" --add-rich-rule="${RULE}"
        firewall-cmd --zone="${FIREWALL_ZONE}" --add-rich-rule="${RULE}"
    done

    # Reload to ensure permanent state is active (matches immediate=yes semantics)
    firewall-cmd --reload

    # Task: Verify active firewall rules / Display
    firewall-cmd --zone="${FIREWALL_ZONE}" --list-all
else
    log "Skipping firewall module (ssh_allowed_ips empty)."
fi

# ============================================================================
# Done
# ============================================================================
phase "All modules completed"
log "Hostname:   $(hostname -f)"
log "Kernel:     $(uname -r)"
log "Timezone:   $(timedatectl show -p Timezone --value)"
log "Domain:     $(realm list 2>/dev/null | awk '/domain-name:/{print $2; exit}' || echo none)"
log "Done."
