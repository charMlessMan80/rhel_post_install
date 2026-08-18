#!/bin/bash
#
set -euo pipefail

# --- Red Hat Subscription Manager (RHSM_config.yml) -------------------------
RHSM_USERNAME=""                                   # leave empty to skip module
RHSM_PASSWORD=""
RHSM_AUTO_ATTACH=true
RHSM_REPOS=("rhel-9-for-x86_64-baseos-rpms" "rhel-9-for-x86_64-appstream-rpms")                                      # e.g. ("rhel-9-for-x86_64-baseos-rpms")
RHSM_PROXY_HOSTNAME=""                             # e.g. "proxy.example.com" - empty = skip
RHSM_PROXY_PORT=""                                 # e.g. "3128" - empty = skip


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
