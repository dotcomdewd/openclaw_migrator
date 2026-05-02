#!/usr/bin/env bash
set -Eeuo pipefail

# openclaw-merge-archives.sh
#
# Purpose:
#   Merge two or more OpenClaw migration archives into one importable archive.
#
# What it does:
#   - Merges important OpenClaw Markdown files such as SOUL.md, MEMORY.md,
#     USER.md, IDENTITY.md, AGENTS.md, and TOOLS.md.
#   - Preserves skills from each source system.
#   - Avoids destructive overwrites.
#   - Deduplicates exact duplicate files.
#   - Renames conflicting skills and files with source labels.
#   - Collects .env/secrets files into a review-only folder instead of making
#     them active automatically.
#   - Produces a new archive compatible with openclaw-migrate.sh import.
#
# Example:
#   ./openclaw-merge-archives.sh \
#     --source old1=./openclaw-old1.tar.gz \
#     --source old2=./openclaw-old2.tar.gz \
#     --output ./openclaw-merged.tar.gz
#
# Import after merge:
#   ./openclaw-migrate.sh import ./openclaw-merged.tar.gz
#
# Notes:
#   - Run this on the new system or a trusted workstation.
#   - The output archive may contain secrets, API keys, tokens, and personal memory.
#   - Do not commit source archives or merged archives to GitHub.

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_ARCHIVE="openclaw-merged-${TIMESTAMP}.tar.gz"
TARGET_HOME="$HOME"
PREFER_SOURCE=""
KEEP_STAGING="false"

STAGING_BASE="${TMPDIR:-/tmp}/openclaw-merge-${TIMESTAMP}"
SOURCES_DIR="$STAGING_BASE/sources"
MERGED_DIR="$STAGING_BASE/merged"
MERGED_ROOTFS="$MERGED_DIR/rootfs"
MERGED_METADATA="$MERGED_DIR/metadata"
MERGE_INDEX="$MERGED_METADATA/markdown-merge-index.tsv"
REPORT_FILE="$MERGED_METADATA/merge-report.md"

SOURCE_LABELS=()
SOURCE_PATHS=()

IMPORTANT_MARKDOWN_NAMES=(
  "soul.md"
  "memory.md"
  "user.md"
  "identity.md"
  "agents.md"
  "tools.md"
  "tool.md"
  "instructions.md"
  "system.md"
)

OPENCLAW_RELATIVE_ROOTS=(
  ".openclaw"
  ".config/openclaw"
  ".local/share/openclaw"
  ".local/state/openclaw"
)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME --source name=/path/archive.tar.gz --source name2=/path/archive2.tar.gz [options]

Required:
  --source NAME=PATH       Source migration archive. Use once per source system.

Options:
  --output PATH            Output merged archive path.
                           Default: openclaw-merged-YYYYMMDD-HHMMSS.tar.gz

  --target-home PATH       Target home directory inside merged archive.
                           Default: current user's HOME.

  --prefer NAME            Preferred source when a non-mergeable config conflict exists.
                           If omitted, the first source wins and conflicts are preserved
                           with source-specific filenames.

  --keep-staging           Keep temporary staging directory for inspection.

Examples:
  $SCRIPT_NAME \\
    --source system1=./openclaw-system1.tar.gz \\
    --source system2=./openclaw-system2.tar.gz \\
    --output ./openclaw-merged.tar.gz

  $SCRIPT_NAME \\
    --source ai1=./ai1.tar.gz \\
    --source ai2=./ai2.tar.gz \\
    --prefer ai1 \\
    --target-home /home/thomas \\
    --output ./merged.tar.gz
EOF
}

cleanup() {
  if [[ "$KEEP_STAGING" == "true" ]]; then
    log "Keeping staging directory: $STAGING_BASE"
  else
    rm -rf "$STAGING_BASE"
  fi
}

trap cleanup EXIT

safe_label() {
  local label="$1"
  echo "$label" | sed -E 's/[^A-Za-z0-9._-]+/_/g'
}

lowercase() {
  tr '[:upper:]' '[:lower:]'
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        local source_arg="${2:-}"
        [[ -n "$source_arg" ]] || die "--source requires NAME=PATH"
        [[ "$source_arg" == *=* ]] || die "--source must use NAME=PATH format"

        local label="${source_arg%%=*}"
        local path="${source_arg#*=}"

        [[ -n "$label" ]] || die "Source label cannot be empty"
        [[ -n "$path" ]] || die "Source path cannot be empty"
        [[ -f "$path" || -d "$path" ]] || die "Source path not found: $path"

        SOURCE_LABELS+=("$(safe_label "$label")")
        SOURCE_PATHS+=("$path")
        shift 2
        ;;
      --output)
        OUTPUT_ARCHIVE="${2:-}"
        [[ -n "$OUTPUT_ARCHIVE" ]] || die "--output requires a path"
        shift 2
        ;;
      --target-home)
        TARGET_HOME="${2:-}"
        [[ -n "$TARGET_HOME" ]] || die "--target-home requires a path"
        shift 2
        ;;
      --prefer)
        PREFER_SOURCE="$(safe_label "${2:-}")"
        [[ -n "$PREFER_SOURCE" ]] || die "--prefer requires a source name"
        shift 2
        ;;
      --keep-staging)
        KEEP_STAGING="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  if [[ "${#SOURCE_LABELS[@]}" -lt 2 ]]; then
    die "At least two --source NAME=PATH arguments are required."
  fi
}

init_workspace() {
  mkdir -p "$SOURCES_DIR"
  mkdir -p "$MERGED_ROOTFS"
  mkdir -p "$MERGED_METADATA"
  : > "$MERGE_INDEX"

  cat > "$REPORT_FILE" <<EOF
# OpenClaw Merge Report

Generated: $(date)
Target home: \`$TARGET_HOME\`

## Sources

EOF

  for i in "${!SOURCE_LABELS[@]}"; do
    echo "- ${SOURCE_LABELS[$i]}: ${SOURCE_PATHS[$i]}" >> "$REPORT_FILE"
  done

  cat >> "$REPORT_FILE" <<EOF

## Summary

This archive was generated by \`$SCRIPT_NAME\`.

Merge behavior:

- Important Markdown files are combined into one source-labeled file.
- Exact duplicate files are skipped.
- Conflicting non-Markdown files are preserved with source-specific names.
- Conflicting skill directories are preserved with source-specific names.
- Environment and secret files are copied into a review-only folder and are not activated automatically.

EOF
}

extract_sources() {
  log "Extracting source archives..."

  for i in "${!SOURCE_LABELS[@]}"; do
    local label="${SOURCE_LABELS[$i]}"
    local path="${SOURCE_PATHS[$i]}"
    local dest="$SOURCES_DIR/$label"

    mkdir -p "$dest"

    if [[ -d "$path" ]]; then
      log "Copying source directory: $label"
      cp -a "$path/." "$dest/"
    else
      log "Extracting source archive: $label"
      tar -xzf "$path" -C "$dest"
    fi
  done
}

source_rootfs_dir() {
  local source_dir="$1"

  if [[ -d "$source_dir/rootfs" ]]; then
    echo "$source_dir/rootfs"
  else
    echo "$source_dir"
  fi
}

detect_source_home() {
  local rootfs="$1"

  local found=""

  found="$(find "$rootfs" -type d -name ".openclaw" 2>/dev/null | head -n 1 || true)"

  if [[ -n "$found" ]]; then
    dirname "$found"
    return 0
  fi

  found="$(find "$rootfs" -type d -path "*/.config/openclaw" 2>/dev/null | head -n 1 || true)"

  if [[ -n "$found" ]]; then
    echo "$found" | sed 's#/.config/openclaw$##'
    return 0
  fi

  if [[ -d "$rootfs/home" ]]; then
    found="$(find "$rootfs/home" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  fi

  echo ""
}

relative_to_source_home() {
  local source_home="$1"
  local path="$2"

  if [[ "$path" == "$source_home"* ]]; then
    echo "${path#$source_home/}"
  else
    echo ""
  fi
}

is_important_markdown() {
  local path="$1"
  local base
  base="$(basename "$path" | lowercase)"

  for name in "${IMPORTANT_MARKDOWN_NAMES[@]}"; do
    if [[ "$base" == "$name" ]]; then
      return 0
    fi
  done

  # Treat Markdown under memory directories as mergeable too.
  local lower_path
  lower_path="$(echo "$path" | lowercase)"

  if [[ "$lower_path" == */memory/*.md ]]; then
    return 0
  fi

  return 1
}

is_env_or_secret_file() {
  local path="$1"
  local base
  base="$(basename "$path" | lowercase)"

  case "$base" in
    ".env"|"env"|"*.env"|"secrets"|"secrets.env"|"tokens"|"tokens.json")
      return 0
      ;;
  esac

  local lower_path
  lower_path="$(echo "$path" | lowercase)"

  if [[ "$lower_path" == *"/.env" || "$lower_path" == *"/secrets/"* || "$lower_path" == *"/tokens/"* ]]; then
    return 0
  fi

  return 1
}

register_markdown_merge() {
  local dest_path="$1"
  local label="$2"
  local source_file="$3"
  local source_rel="$4"

  printf '%s\t%s\t%s\t%s\n' "$dest_path" "$label" "$source_file" "$source_rel" >> "$MERGE_INDEX"
}

files_identical() {
  local file1="$1"
  local file2="$2"

  if cmp -s "$file1" "$file2"; then
    return 0
  fi

  return 1
}

copy_with_conflict_handling() {
  local source_file="$1"
  local dest_file="$2"
  local label="$3"

  mkdir -p "$(dirname "$dest_file")"

  if [[ ! -e "$dest_file" ]]; then
    cp -a "$source_file" "$dest_file"
    return 0
  fi

  if [[ -f "$dest_file" && -f "$source_file" ]] && files_identical "$source_file" "$dest_file"; then
    return 0
  fi

  local dir
  local base
  local ext
  local stem
  local conflict_file

  dir="$(dirname "$dest_file")"
  base="$(basename "$dest_file")"

  if [[ "$base" == *.* ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  else
    stem="$base"
    ext=""
  fi

  conflict_file="$dir/${stem}__from_${label}${ext}"

  local counter=1
  while [[ -e "$conflict_file" ]]; do
    conflict_file="$dir/${stem}__from_${label}_${counter}${ext}"
    counter=$((counter + 1))
  done

  cp -a "$source_file" "$conflict_file"

  {
    echo "- Conflict preserved:"
    echo "  - Existing: \`$dest_file\`"
    echo "  - Added: \`$conflict_file\`"
  } >> "$REPORT_FILE"
}

dir_checksum() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "missing"
    return 0
  fi

  (
    cd "$dir"
    find . -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 sha256sum 2>/dev/null \
      | sha256sum \
      | awk '{print $1}'
  )
}

copy_skill_dir() {
  local source_skill_dir="$1"
  local dest_skills_dir="$2"
  local label="$3"

  local skill_name
  skill_name="$(basename "$source_skill_dir")"

  local dest_skill_dir="$dest_skills_dir/$skill_name"

  mkdir -p "$dest_skills_dir"

  if [[ ! -e "$dest_skill_dir" ]]; then
    cp -a "$source_skill_dir" "$dest_skill_dir"
    echo "- Skill added from ${label}: \`$dest_skill_dir\`" >> "$REPORT_FILE"
    return 0
  fi

  local src_sum
  local dest_sum

  src_sum="$(dir_checksum "$source_skill_dir")"
  dest_sum="$(dir_checksum "$dest_skill_dir")"

  if [[ "$src_sum" == "$dest_sum" ]]; then
    echo "- Duplicate skill skipped from ${label}: \`$skill_name\`" >> "$REPORT_FILE"
    return 0
  fi

  local renamed="$dest_skills_dir/${skill_name}__from_${label}"
  local counter=1

  while [[ -e "$renamed" ]]; do
    renamed="$dest_skills_dir/${skill_name}__from_${label}_${counter}"
    counter=$((counter + 1))
  done

  cp -a "$source_skill_dir" "$renamed"

  {
    echo "- Skill conflict preserved:"
    echo "  - Existing: \`$dest_skill_dir\`"
    echo "  - Added: \`$renamed\`"
  } >> "$REPORT_FILE"
}

copy_env_for_review() {
  local source_file="$1"
  local label="$2"
  local source_rel="$3"

  local review_dir="$MERGED_ROOTFS${TARGET_HOME}/.config/openclaw/merged-review/env-and-secrets"
  mkdir -p "$review_dir"

  local safe_rel
  safe_rel="$(echo "$source_rel" | sed -E 's#[/ ]+#_#g; s#[^A-Za-z0-9._-]+#_#g')"

  local dest="$review_dir/${label}__${safe_rel}"

  cp -a "$source_file" "$dest"
  chmod 600 "$dest" 2>/dev/null || true

  echo "- Environment/secret file saved for review from ${label}: \`$dest\`" >> "$REPORT_FILE"
}

merge_regular_tree() {
  local source_root="$1"
  local source_base="$2"
  local dest_base="$3"
  local label="$4"

  [[ -d "$source_base" ]] || return 0

  while IFS= read -r -d '' item; do
    [[ -f "$item" ]] || continue

    local rel
    rel="${item#$source_base/}"

    local source_home
    source_home="$source_root"

    local dest_file="$dest_base/$rel"

    # Skip logs and obvious bulky runtime noise.
    local lower_item
    lower_item="$(echo "$item" | lowercase)"

    if [[ "$lower_item" == */logs/* || "$lower_item" == *.log ]]; then
      continue
    fi

    if [[ "$lower_item" == */node_modules/* || "$lower_item" == */.git/* ]]; then
      continue
    fi

    if is_env_or_secret_file "$item"; then
      copy_env_for_review "$item" "$label" "$rel"
      continue
    fi

    if is_important_markdown "$item"; then
      register_markdown_merge "$dest_file" "$label" "$item" "$rel"
      continue
    fi

    copy_with_conflict_handling "$item" "$dest_file" "$label"

  done < <(find "$source_base" -type f -print0 2>/dev/null)
}

merge_skills_from_tree() {
  local source_base="$1"
  local dest_base="$2"
  local label="$3"

  local skill_parent_candidates=(
    "$source_base/skills"
    "$source_base/.openclaw/skills"
    "$source_base/.config/openclaw/skills"
  )

  for skills_dir in "${skill_parent_candidates[@]}"; do
    if [[ -d "$skills_dir" ]]; then
      local rel_skills
      rel_skills="${skills_dir#$source_base/}"

      local dest_skills_dir="$dest_base/$rel_skills"

      while IFS= read -r -d '' skill_dir; do
        copy_skill_dir "$skill_dir" "$dest_skills_dir" "$label"
      done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
  done
}

merge_source() {
  local label="$1"
  local extracted_source_dir="$2"

  local rootfs
  rootfs="$(source_rootfs_dir "$extracted_source_dir")"

  local source_home
  source_home="$(detect_source_home "$rootfs")"

  if [[ -z "$source_home" ]]; then
    log "WARNING: Could not detect source home for $label. Skipping."
    echo "- WARNING: Could not detect source home for \`$label\`; skipped." >> "$REPORT_FILE"
    return 0
  fi

  log "Merging source: $label"
  log "Detected source home: $source_home"

  echo "" >> "$REPORT_FILE"
  echo "## Source: $label" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  echo "- Detected source home: \`$source_home\`" >> "$REPORT_FILE"

  local dest_home="$MERGED_ROOTFS$TARGET_HOME"
  mkdir -p "$dest_home"

  # Merge known OpenClaw trees.
  for rel_root in "${OPENCLAW_RELATIVE_ROOTS[@]}"; do
    local src_tree="$source_home/$rel_root"
    local dest_tree="$dest_home/$rel_root"

    if [[ -d "$src_tree" ]]; then
      log "Merging $rel_root from $label"

      # Skills are copied as whole directories first to avoid half-merged skills.
      merge_skills_from_tree "$src_tree" "$dest_tree" "$label"

      # Everything else is copied/merged with conflict handling.
      merge_regular_tree "$source_home" "$src_tree" "$dest_tree" "$label"
    fi
  done

  # Also catch workspace-level files directly in the source home.
  while IFS= read -r -d '' top_file; do
    if is_important_markdown "$top_file"; then
      local rel
      rel="${top_file#$source_home/}"
      local dest_file="$dest_home/$rel"
      register_markdown_merge "$dest_file" "$label" "$top_file" "$rel"
    fi
  done < <(find "$source_home" -maxdepth 1 -type f -print0 2>/dev/null)
}

generate_merged_markdown_files() {
  log "Generating merged Markdown files..."

  if [[ ! -s "$MERGE_INDEX" ]]; then
    log "No Markdown files registered for merge."
    return 0
  fi

  cut -f1 "$MERGE_INDEX" | sort -u | while IFS= read -r dest_file; do
    [[ -n "$dest_file" ]] || continue

    mkdir -p "$(dirname "$dest_file")"

    local base
    base="$(basename "$dest_file")"

    {
      echo "# Merged $base"
      echo
      echo "Generated by \`$SCRIPT_NAME\` on $(date)."
      echo
      echo "This file combines content from multiple OpenClaw systems."
      echo "Review and edit this file after import so the final agent personality,"
      echo "memory, and operating instructions are coherent."
      echo
      echo "---"
      echo
    } > "$dest_file"

    awk -F '\t' -v target="$dest_file" '$1 == target {print $0}' "$MERGE_INDEX" |
    while IFS=$'\t' read -r _dest label source_file source_rel; do
      {
        echo
        echo "## Source: $label"
        echo
        echo "_Original relative path: \`$source_rel\`_"
        echo
        echo "```text"
        cat "$source_file"
        echo
        echo "```"
        echo
      } >> "$dest_file"
    done

    echo "- Merged Markdown file generated: \`$dest_file\`" >> "$REPORT_FILE"
  done
}

copy_preferred_configs() {
  log "Selecting preferred config files where applicable..."

  local dest_home="$MERGED_ROOTFS$TARGET_HOME"
  local review_dir="$dest_home/.config/openclaw/merged-review/configs"
  mkdir -p "$review_dir"

  local config_names=(
    "openclaw.json"
    "config.json"
    "settings.json"
  )

  for config_name in "${config_names[@]}"; do
    local found_any="false"

    for i in "${!SOURCE_LABELS[@]}"; do
      local label="${SOURCE_LABELS[$i]}"
      local source_dir="$SOURCES_DIR/$label"
      local rootfs
      rootfs="$(source_rootfs_dir "$source_dir")"
      local source_home
      source_home="$(detect_source_home "$rootfs")"

      [[ -n "$source_home" ]] || continue

      while IFS= read -r -d '' config_file; do
        found_any="true"

        local rel
        rel="${config_file#$source_home/}"

        local safe_rel
        safe_rel="$(echo "$rel" | sed -E 's#[/ ]+#_#g; s#[^A-Za-z0-9._-]+#_#g')"

        cp -a "$config_file" "$review_dir/${label}__${safe_rel}"

        local dest_file="$dest_home/$rel"

        if [[ ! -e "$dest_file" ]]; then
          mkdir -p "$(dirname "$dest_file")"
          cp -a "$config_file" "$dest_file"
          echo "- Config selected from ${label}: \`$rel\`" >> "$REPORT_FILE"
        elif [[ -n "$PREFER_SOURCE" && "$label" == "$PREFER_SOURCE" ]]; then
          cp -a "$config_file" "$dest_file"
          echo "- Config overwritten by preferred source ${label}: \`$rel\`" >> "$REPORT_FILE"
        fi

      done < <(find "$source_home" -type f -name "$config_name" -print0 2>/dev/null)
    done

    if [[ "$found_any" == "true" ]]; then
      echo "- All discovered \`$config_name\` files copied to review folder." >> "$REPORT_FILE"
    fi
  done
}

create_import_notes() {
  local notes_dir="$MERGED_ROOTFS$TARGET_HOME/.config/openclaw/merged-review"
  mkdir -p "$notes_dir"

  cat > "$notes_dir/README-MERGE-REVIEW.md" <<EOF
# OpenClaw Merge Review

This folder was created during a merge of multiple OpenClaw systems.

Recommended review order:

1. Review merged persona/context files:
   - SOUL.md
   - MEMORY.md
   - USER.md
   - IDENTITY.md
   - AGENTS.md
   - TOOLS.md

2. Review skills:
   - Duplicate skills were skipped if exactly identical.
   - Conflicting skills were preserved with names like:
     \`skillname__from_source\`

3. Review configuration files:
   - Source configs were copied into:
     \`merged-review/configs/\`

4. Review environment and secret files:
   - Source .env/token/secret files were copied into:
     \`merged-review/env-and-secrets/\`
   - These were NOT activated automatically.

5. After importing, run:
   \`\`\`bash
   openclaw doctor
   openclaw memory index
   openclaw gateway status
   \`\`\`

Important:

This merge script preserves information. It does not attempt to semantically rewrite or delete memories.
You should review the merged Markdown files and clean up contradictions manually.
EOF

  cp -a "$REPORT_FILE" "$notes_dir/MERGE-REPORT.md"
}

create_archive() {
  log "Creating merged archive: $OUTPUT_ARCHIVE"

  mkdir -p "$(dirname "$OUTPUT_ARCHIVE")"

  cp -a "$REPORT_FILE" "$MERGED_METADATA/merge-report.md"

  tar -C "$MERGED_DIR" -czf "$OUTPUT_ARCHIVE" .

  log "Merged archive created: $OUTPUT_ARCHIVE"
}

main() {
  need_cmd tar
  need_cmd find
  need_cmd sort
  need_cmd awk
  need_cmd sed
  need_cmd sha256sum
  need_cmd cmp

  parse_args "$@"
  init_workspace
  extract_sources

  for i in "${!SOURCE_LABELS[@]}"; do
    merge_source "${SOURCE_LABELS[$i]}" "$SOURCES_DIR/${SOURCE_LABELS[$i]}"
  done

  generate_merged_markdown_files
  copy_preferred_configs
  create_import_notes
  create_archive

  cat <<EOF

Merge complete.

Merged archive:
  $OUTPUT_ARCHIVE

Import it on the new OpenClaw system with:
  ./openclaw-migrate.sh import "$OUTPUT_ARCHIVE"

After import, review:
  ~/.config/openclaw/merged-review/README-MERGE-REVIEW.md
  ~/.config/openclaw/merged-review/MERGE-REPORT.md

Recommended validation:
  openclaw doctor
  openclaw memory index
  openclaw gateway status

Security reminder:
  The source archives and merged archive may contain memories, skills, API keys,
  tokens, environment variables, and other sensitive files.
  Do not commit them to GitHub.

EOF
}

main "$@"
