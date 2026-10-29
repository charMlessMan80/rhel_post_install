# RHEL 9 Post-Installation Configuration

Automated post-installation hardening and configuration for Red Hat Enterprise
Linux 9 hosts, implemented as an idempotent Ansible playbook (`main.yml` + `tasks/`).

## Features

Each module can be enabled or skipped through inventory / group variables.

| Module | File | Purpose |
| --- | --- | --- |
| Hostname | `tasks/set_hostname.yml` | Set the lower-case FQDN as hostname and update `/etc/hosts`. |
| DNS | `tasks/DNS_config.yml` | Configure DNS servers / search domains via NetworkManager. |
| Subscription Manager | `tasks/RHSM_config.yml` | Register with RHSM, enable repos, optional proxy. |
| Kernel hot patching | `tasks/kernel_hotpatch.yml` | Install and load `kpatch` live patches. |
| Package updates | `tasks/packages_update.yml` | Full `dnf update`, reboot if the kernel changed. |
| NTP | `tasks/NTP_config.yml` | Configure chrony time sources and timezone. |
| Active Directory join | `tasks/AD_join.yml` | Join AD via `realmd`/SSSD, restrict logins to allowed groups. |
| Identity checks | `tasks/verify_identity.yml` | Fail unless hostname, `/etc/hosts`, DNS A/PTR and the AD join are consistent. |
| PKI enrollment | `tasks/PKI_enrolment.yml` | Enroll a machine certificate from AD CS via certmonger + **cepces (CES/CEP)**. |
| Local admin | `tasks/local_admin.yml` | Create a local sudo admin with optional SSH key. |
| SSH hardening | `tasks/ssh_hardening.yml` | Disable root SSH login. |
| Secure root | `tasks/secure_root.yml` | Lock root, restrict `su`, disable TTY root login. |
| GRUB password | `tasks/secure_grub.yml` | Protect the bootloader with a PBKDF2 password. |
| Audit logging | `tasks/audit_config.yml` | Configure `auditd` for full "who did what" logging (commands, identity, privilege, file changes). |
| Disable interactive startup | `tasks/disable_interactive_startup.yml` | Remove single-user/rescue/SysRq/Ctrl+Alt+Del escapes. |
| Firewall | `tasks/firewall_config.yml` | Stop and disable firewalld (default), or restrict SSH to trusted source networks. |

## Repository layout

```
main.yml                     # Playbook entry point (includes all task files)
group_vars/
  rhel9_hosts.yml            # Variables for the rhel9_hosts group
inventory/
  hosts.ini                  # Hosts (group variables live in group_vars/)
tasks/                       # One task file per module
templates/                   # Jinja2 templates (sssd, auditd rules)
```

## Requirements

- Control node with Ansible (for the playbook path).
- Target hosts running **RHEL 9**, reachable over SSH as a privileged user.
- The `community.general` collection (used by the PKI module for `ini_file`):

  ```bash
  ansible-galaxy collection install community.general
  ```

## Usage — Ansible

1. Edit `inventory/hosts.ini`: set the target hosts and variables (see below).
2. Store secrets with `ansible-vault` rather than plaintext in the inventory.
3. Run the playbook:

   ```bash
   ansible-playbook -i inventory/hosts.ini main.yml
   ```

   Include vault credentials when secrets are encrypted:

   ```bash
   ansible-playbook -i inventory/hosts.ini main.yml --ask-vault-pass
   ```

### Key variables

| Variable | Description |
| --- | --- |
| `ad_domain`, `ad_join_user`, `ad_join_password` | AD domain join credentials. |
| `ad_allowed_groups`, `ad_ou` | Login allow-list and computer OU. |
| `dns_servers`, `dns_search_domains` | DNS configuration. |
| `ntp_servers`, `ntp_timezone` | Time synchronization. |
| `rhsm_username`, `rhsm_password`, `rhsm_repos` | RHSM registration (module skipped if unset). |
| `adcs_server`, `adcs_cert_template`, `adcs_root_ca_cert` | AD CS enrollment (module skipped if `adcs_server` is empty). |
| `local_admin_user`, `local_admin_password`, `local_admin_ssh_key` | Local admin account. |
| `grub_superuser`, `grub_password` | GRUB protection (module skipped if `grub_password` unset). |
| `firewalld_enabled` | Default `false`: firewalld is stopped and disabled, filtering is left to the network firewall. `true`: firewalld restricts SSH to `ssh_allowed_ips` (mandatory then, checked by preflight). |
| `ssh_allowed_ips`, `firewall_zone` | Firewall SSH allow-list, used only when `firewalld_enabled: true`; preflight fails if it is set while `firewalld_enabled` is not `true`. |
| `verify_ptr_strict` | Default `true`: fail when the PTR record of the host IP does not match its FQDN. `false`: warn only. |
| `verify_dns_timeout` | Default `180`: maximum time in seconds to wait for each of the DNS A and PTR records (checked every 10 s). |
| `audit_buffer_size`, `audit_failure_mode`, `audit_rate_limit`, `audit_immutable` | auditd tuning (buffer, failure action, rate limit, lock rules with `-e 2`). |

> Modules guarded by `when:` conditions are skipped automatically when their
> required variables are undefined or empty.

## Hostname and `/etc/hosts`

`tasks/set_hostname.yml` computes the canonical FQDN, exposed as the
`host_fqdn` fact (and `host_short` for the short name):

- `inventory_hostname` if it already contains a dot, otherwise
  `inventory_hostname.ad_domain`, always converted to **lower case**
  (`satellite-installer` rejects upper-case hostnames);
- the hostname is set to that FQDN, so `hostname -f` returns it.

`/etc/hosts` is managed as follows:

- any `127.0.0.1` / `127.0.1.1` line carrying the FQDN or the short name is
  removed (earlier versions replaced the localhost line with one, making the
  FQDN resolve to loopback);
- `127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4`
  is restored if missing;
- a dedicated `<default IPv4>  <fqdn> <short>` line is maintained.

Facts are refreshed after the rename, and the PKI module uses `host_fqdn` for
the certificate CN/SAN, key/certificate paths and Kerberos principal.

## Identity checks

`tasks/verify_identity.yml` runs right after the AD join, once handlers are
flushed (SSSD restarted, dynamic DNS update sent). It fails with an explicit
message unless:

- `hostname -f` equals `host_fqdn`;
- `getent hosts <fqdn>` returns the host IP, never a `127.*` address;
- `getent ahostsv4 localhost` returns `127.0.0.1`;
- the DNS A record of the FQDN points to the host IP;
- the DNS PTR record of the host IP is the FQDN (required by Satellite);
  failure or warning depending on `verify_ptr_strict`;
- `realm list` shows `ad_domain`.

DNS records are created by SSSD (`dyndns`, GSS-TSIG) and each DNS check retries
for up to `verify_dns_timeout` seconds (default 180, to cover AD replication
between domain controllers). They use `getent -s dns`, which queries DNS only (bypassing
`/etc/hosts` and SSSD), so no extra package such as `bind-utils` is required.
The PTR update needs the reverse zone to exist on the AD DNS servers.

## Satellite / AAP servers

- Do **not** define `ssh_allowed_ips` and keep `firewalld_enabled: false`:
  the SSH-only firewalld policy would block the Satellite and AAP ports.
- `tasks/secure_root.yml` sets root's shell to `/sbin/nologin`: run
  administrative commands with `sudo <command>`; `sudo -i` and `sudo su -`
  no longer give a root shell.
- The AAP installation user must remain a **local** account (rootless podman
  relies on local `/etc/subuid` / `/etc/subgid` entries), never an AD account.

## PKI enrollment (AD CS via CES/CEP)

Machine certificate enrollment uses **certmonger** with the **cepces** helper, which
talks to Active Directory Certificate Services over the CES/CEP SOAP endpoints
(MS-XCEP / MS-WSTEP) instead of SCEP.

- **Authentication** is **Kerberos (GSSAPI)** using the host's machine keytab
  (`/etc/krb5.keytab`) created during the AD join. No credentials are stored in
  `cepces.conf`.
- The CEP endpoint defaults to
  `https://<adcs_server>/ADPolicyProvider_CEP_Kerberos/service.svc/CEP` — adjust if
  your AD CS uses a different service path.
- The `cepces` package registers a certmonger CA named `cepces`; the certificate is
  requested with that CA and the configured template (`adcs_cert_template`).

### Renewal

Renewal is fully automatic and requires no additional configuration:

- certmonger tracks the certificate (state `MONITORING`) and renews it before expiry
  (typically at ~80% of its lifetime) through the same `cepces` CES/CEP path.
- Renewal reuses the Kerberos machine keytab, so it works unattended as long as the
  host stays domain-joined, certmonger is running, and the AD CS endpoints are reachable.
- The post-save hook (`-C "systemctl reload httpd || true"`) is run after each renewal —
  change it to reload/restart whichever service consumes the certificate.

Useful commands:

```bash
getcert list -f /etc/pki/tls/certs/<fqdn>.crt   # status, expiry, auto-renew
getcert resubmit -f /etc/pki/tls/certs/<fqdn>.crt  # force an immediate renewal
```

> Ensure the AD CS certificate template auto-issues (no manual CA approval) for the
> enrollment and renewals to remain hands-off.

## Audit logging (who did what)

The `tasks/audit_config.yml` module configures the Linux Audit daemon (`auditd`) for
comprehensive accountability, rendering its rules from `templates/audit.rules.j2` into
`/etc/audit/rules.d/99-who-did-what.rules`.

What is captured:

- **Every command** run by real users and by root (`execve`), attributed to the login
  user (`auid`) even after `sudo`/`su`.
- **Full typed command lines** via `pam_tty_audit` (system-auth / password-auth).
- **Identity & account changes** (`/etc/passwd`, `/etc/shadow`, `/etc/group`, sudoers).
- **Logins and sessions** (`utmp`/`wtmp`/`btmp`, faillog, lastlog, PAM).
- **Privilege escalation** (`su`, `sudo`), file access/deletion, permission and
  ownership changes, network/time configuration, and kernel module operations.
- **Tampering with the audit configuration** itself.

Notes:

- auditd is restarted with `service auditd restart` (systemd cannot restart it directly);
  rules are (re)loaded with `augenrules --load`.
- The kernel is booted with `audit=1 audit_backlog_limit=8192` so events are captured
  from early boot.
- Set `audit_immutable: true` to make the rule set immutable (`-e 2`); changes then
  require a reboot.

Useful commands:

```bash
auditctl -l                       # list loaded rules
ausearch -k user_commands         # commands run by users
ausearch -k priv_esc              # privilege escalation events
aureport -au                      # authentication report
```

## Security notes

- Never commit plaintext passwords. Use `ansible-vault` for `ad_join_password`,
  `grub_password`, `local_admin_password`, and RHSM credentials.
- The SSH hardening and secure-root modules only run when a `local_admin_password`
  is set, to avoid locking yourself out of the host.
