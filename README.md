Absolutely — here is a polished `README.md` you can use for the GitHub repo.

````markdown
# OpenClaw Migration Script

A simple Bash-based migration utility for moving an existing OpenClaw setup from one Linux system to another.

This script is designed to help you export your current OpenClaw configuration, gateway service, and common local data paths from an existing host, then restore them onto a new system while also installing required dependencies and OpenClaw itself.

---

## What This Script Does

The migration script supports two modes:

- `export` — run this on the old/source system
- `import` — run this on the new/destination system

During export, the script collects common OpenClaw files, configuration directories, user service definitions, and basic metadata about the existing installation.

During import, the script installs dependencies, installs OpenClaw, restores the exported files, fixes permissions, reinstalls/restarts the OpenClaw gateway service, and runs validation checks.

---

## Features

- Exports common OpenClaw configuration and data paths
- Captures the OpenClaw systemd user service
- Creates a portable `.tar.gz` migration archive
- Installs common Linux dependencies on the new host
- Installs OpenClaw using either:
  - official installer script
  - npm
- Restores files into their original locations
- Backs up any existing OpenClaw data on the new host before import
- Reinstalls and restarts the OpenClaw gateway service
- Runs post-migration validation checks
- Supports additional custom include paths

---

## Supported Systems

This script is intended for Linux systems that use a standard user home directory layout and, preferably, systemd user services.

Tested/targeted environments include:

- Ubuntu
- Debian
- Fedora
- RHEL/CentOS-style systems
- Arch-based systems
- WSL2 with systemd enabled

The script should be run as the same user that owns and runs OpenClaw.

Do **not** run this script as `root` unless your OpenClaw setup was intentionally installed and operated by root.

---

## Requirements

The script will attempt to install the following dependencies automatically on the destination system:

- `curl`
- `ca-certificates`
- `gnupg`
- `tar`
- `gzip`
- `jq`
- `lsof`
- `procps`
- `coreutils`
- `findutils`

The destination system should also have:

- `sudo` access
- internet access during import
- systemd user services enabled, if using the OpenClaw gateway service

---

## Files and Paths Backed Up

By default, the script attempts to include the following paths if they exist:

```text
~/.openclaw
~/.config/openclaw
~/.local/share/openclaw
~/.local/state/openclaw
~/.cache/openclaw
~/.config/systemd/user/openclaw-gateway.service
~/.config/systemd/user/default.target.wants/openclaw-gateway.service
````

The script skips paths that do not exist.

It also excludes some unnecessary or bulky items during export, such as:

```text
node_modules
.git
*.log
logs
```

---

## Installation

Clone or download this repository on both the old and new systems.

```bash
git clone https://github.com/YOUR-USERNAME/openclaw-migrate.git
cd openclaw-migrate
chmod +x openclaw-migrate.sh
```

Or download the script directly and make it executable:

```bash
chmod +x openclaw-migrate.sh
```

---

## Usage

### Step 1: Export from the Old System

Run the following on the existing OpenClaw host:

```bash
./openclaw-migrate.sh export
```

This will create an archive similar to:

```text
openclaw-migration-20260502-143000.tar.gz
```

The archive contains the exported OpenClaw files and migration metadata.

---

### Step 2: Copy the Archive to the New System

Copy the migration archive and the script to the new system.

Example using `scp`:

```bash
scp openclaw-migration-*.tar.gz youruser@new-system:/home/youruser/
scp openclaw-migrate.sh youruser@new-system:/home/youruser/
```

---

### Step 3: Import on the New System

On the new system, run:

```bash
chmod +x openclaw-migrate.sh
./openclaw-migrate.sh import ./openclaw-migration-20260502-143000.tar.gz
```

The import process will:

1. Install required Linux packages
2. Install OpenClaw
3. Stop any existing OpenClaw gateway service
4. Back up existing OpenClaw files on the new host
5. Restore the migration archive
6. Fix file ownership
7. Reinstall and restart the OpenClaw gateway service
8. Run validation checks

---

## Optional Usage

### Include Additional Paths During Export

If your OpenClaw setup uses custom directories, you can include them during export:

```bash
./openclaw-migrate.sh export --include "/opt/openclaw,/srv/openclaw"
```

Multiple paths should be separated by commas.

---

### Use npm Instead of the Installer

By default, the import process uses the OpenClaw installer script.

To install OpenClaw using npm instead:

```bash
./openclaw-migrate.sh import ./openclaw-migration-20260502-143000.tar.gz --install-method npm
```

Supported install methods:

```text
installer
npm
```

---

## Validation Commands

After import, you can manually verify the installation with:

```bash
openclaw --version
openclaw doctor
openclaw gateway status
systemctl --user status openclaw-gateway.service
```

If the OpenClaw command is not found after install, open a new shell session or verify your `PATH`.

Possible paths to add:

```bash
export PATH="$HOME/.openclaw/bin:$PATH"
export PATH="$(npm prefix -g)/bin:$PATH"
```

---

## Headless Server Note

If this is a headless server and you want the OpenClaw gateway to continue running after you log out, enable lingering for the user:

```bash
sudo loginctl enable-linger "$USER"
```

Then restart the user service:

```bash
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

---

## Security Notes

OpenClaw can control tools and services on the host where it runs. Treat the gateway as a privileged local service.

Recommended precautions:

* Do not expose the OpenClaw gateway directly to the public internet
* Keep it bound to localhost or protected by VPN/firewall rules
* Restrict access to the user account running OpenClaw
* Review any restored configuration files before exposing the new system
* Rotate tokens or secrets if the source system may have been compromised
* Avoid committing migration archives to GitHub

Migration archives may contain sensitive tokens, configuration data, paths, and local system details.

Add this to your `.gitignore`:

```gitignore
openclaw-migration-*.tar.gz
openclaw-preimport-backup-*/
*.log
```

---

## Backup Behavior

Before importing onto the new system, the script checks for existing OpenClaw-related files.

If existing files are found, they are backed up to:

```text
~/openclaw-preimport-backup-YYYYMMDD-HHMMSS
```

This helps prevent accidental loss of an existing setup on the destination host.

---

## Troubleshooting

### `openclaw: command not found`

Open a new terminal session, or add the OpenClaw install path to your shell profile:

```bash
echo 'export PATH="$HOME/.openclaw/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

If installed through npm, check the global npm path:

```bash
npm prefix -g
```

Then add its `bin` directory to your `PATH`.

---

### Gateway Service Does Not Start

Check the service status:

```bash
systemctl --user status openclaw-gateway.service
```

Reload systemd user services:

```bash
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

Run OpenClaw diagnostics:

```bash
openclaw doctor
openclaw gateway status
```

---

### Gateway Stops After Logout

Enable lingering:

```bash
sudo loginctl enable-linger "$USER"
```

Then restart the service:

```bash
systemctl --user restart openclaw-gateway.service
```

---

### Import Fails Due to Permissions

Make sure you are running the script as the intended OpenClaw user.

You can manually fix ownership if needed:

```bash
sudo chown -R "$USER:$USER" \
  "$HOME/.openclaw" \
  "$HOME/.config/openclaw" \
  "$HOME/.local/share/openclaw" \
  "$HOME/.local/state/openclaw" \
  "$HOME/.cache/openclaw"
```

---

## Recommended Migration Flow

```bash
# On old system
chmod +x openclaw-migrate.sh
./openclaw-migrate.sh export

# Copy archive and script to new system
scp openclaw-migration-*.tar.gz youruser@new-system:/home/youruser/
scp openclaw-migrate.sh youruser@new-system:/home/youruser/

# On new system
chmod +x openclaw-migrate.sh
./openclaw-migrate.sh import ./openclaw-migration-YYYYMMDD-HHMMSS.tar.gz

# Validate
openclaw doctor
openclaw gateway status
systemctl --user status openclaw-gateway.service
```

---

## Repository Structure

Suggested repo layout:

```text
openclaw-migrate/
├── openclaw-migrate.sh
├── README.md
├── .gitignore
└── LICENSE
```

Suggested `.gitignore`:

```gitignore
# Migration archives
openclaw-migration-*.tar.gz

# Local backups
openclaw-preimport-backup-*/

# Logs
*.log
logs/

# OS/editor files
.DS_Store
.vscode/
.idea/
```

---

## Disclaimer

This script is provided as a migration helper and should be reviewed before use in production environments.

Always inspect the migration archive contents and confirm that the destination system is trusted before restoring configuration files or service definitions.

Use at your own risk.

---

## License

MIT License

You are free to use, modify, and distribute this script.

```
```
