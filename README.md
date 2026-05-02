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
