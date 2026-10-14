#!/usr/bin/env bash
# =============================================================================
#  install.sh — one-step setup for premierecinemas, organize and qbt_relink.py
# =============================================================================
#  1. Checks the tools the scripts rely on (VLC, GNU grep/find, ...)
#  2. Asks where your Movies directory is and saves it in the shared config
#     (~/.config/premierecinemas/config): premierecinemas plays from it,
#     organize and qbt_relink.py work on it
#  3. Copies premierecinemas, organize and qbt_relink.py into ~/.local/bin,
#     so they keep working without this git folder
#  4. Keeps the intro art in one place, ~/.local/bin/art (files still in
#     ~/.local/lib/art are moved over)
#  5. Puts ~/.local/bin on your PATH if it isn't there yet
#
#  Safe to re-run: after a git pull it updates the installed copies, and it
#  can switch everything to a different Movies directory. Anything it would
#  replace that it didn't install itself is kept as name.bak, name.bak01, ...
# =============================================================================

# Everything below is bash — stop early if started with sh/dash
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Please run this with bash: ./install.sh" >&2
  exit 1
fi
set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/premierecinemas"
CONFIG_FILE="$CONFIG_DIR/config"

# Scripts that get copied into $BIN_DIR
COMMANDS=(premierecinemas organize qbt_relink.py)

# premierecinemas reads its intro from art/ next to itself. Older setups kept
# that folder in ~/.local/lib; its files get moved over from there.
ART_DIR="$BIN_DIR/art"
OLD_ART_DIR="$HOME/.local/lib/art"

# Checksums of the files install.sh copied into $BIN_DIR. A re-run uses them
# to tell its own unchanged copies (simply updated) from anything else (backed
# up first).
MANIFEST="$CONFIG_DIR/installed.sha256"

# Appended to your shell's rc file when $BIN_DIR is missing from PATH
PATH_MARKER="# Added by premierecinemas install.sh"
# shellcheck disable=SC2016 # written to the rc file as-is, expanded by your shell
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

# ─── Colours ─────────────────────────────────────────────────────────────────
RESET=$'\033[0m'
YELLOW=$'\033[38;5;220m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
RED=$'\033[31m'

# ─── State ────────────────────────────────────────────────────────────────────
ASSUME_YES=false   # -y: never ask, take the defaults
MOVIES_ARG=""      # -m PATH from the command line
MOVIES_DIR=""      # the chosen Movies directory, absolute
PATH_STATE="ready" # ready | new-terminal | manual (set by ensure_path)

# ─── Output helpers ───────────────────────────────────────────────────────────

step() { printf '\n%b%b▸ %s%b\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
ok() { printf '  %b✓%b %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %b!%b %s\n' "$YELLOW" "$RESET" "$1"; }
note() { printf '  %b· %s%b\n' "$DIM" "$1" "$RESET"; }

die() {
  printf '%bError:%b %s\n' "$RED" "$RESET" "$1" >&2
  exit 1
}

# ask "Question?" — succeeds on yes. Enter, -y or no input at all mean yes.
ask() {
  local answer=""
  if $ASSUME_YES; then
    return 0
  fi
  read -r -p "  $1 [Y/n] " answer || true
  [[ ! "$answer" =~ ^[Nn] ]]
}

# ─── Config helpers ───────────────────────────────────────────────────────────
# Same key=value format premierecinemas uses; dir= may repeat.

config_get() {
  grep -m1 "^${1}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

# Is config line $1 a dir= entry for folder $2? Same rule as premierecinemas:
# an absolute entry is tidied up as text first (no symlinks followed), so
# "dir=/x/" and /x are the same folder, but /x is not /x2.
dir_line_is() {
  local entry="${1#dir=}"
  if [[ "$1" != dir=* ]]; then
    return 1
  fi
  if [[ "$entry" == /* ]]; then
    entry="$(realpath -m -s -- "$entry")"
  fi
  [[ "$entry" == "$2" ]]
}

config_has_dir() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if dir_line_is "$line" "$1"; then
      return 0
    fi
  done <"$CONFIG_FILE"
  return 1
}

# Replace the dir= entries for folder $1 with a single "dir=$2" (where the
# first one was), or drop them all when $2 is empty
config_replace_dir() {
  local old="$1" new="$2" line written=false
  local -a lines
  mapfile -t lines <"$CONFIG_FILE"
  for line in "${lines[@]}"; do
    if ! dir_line_is "$line" "$old"; then
      printf '%s\n' "$line"
    elif [[ -n "$new" ]] && ! $written; then
      printf 'dir=%s\n' "$new"
      written=true
    fi
  done >"$CONFIG_FILE"
}

# Append lines, never gluing onto a last line that lacks its newline
config_append() {
  if [[ -s "$CONFIG_FILE" && -n "$(tail -c1 "$CONFIG_FILE")" ]]; then
    printf '\n' >>"$CONFIG_FILE"
  fi
  printf '%s\n' "$@" >>"$CONFIG_FILE"
}

# Replace every line that is exactly $1 with $2, or drop it when $2 is empty.
# Plain string comparison (no sed), so paths like "Movies & TV [4K]" are safe.
config_replace_line() {
  local old="$1" new="$2" line
  local -a lines
  mapfile -t lines <"$CONFIG_FILE"
  for line in "${lines[@]}"; do
    if [[ "$line" != "$old" ]]; then
      printf '%s\n' "$line"
    elif [[ -n "$new" ]]; then
      printf '%s\n' "$new"
    fi
  done >"$CONFIG_FILE"
}

# ─── File helpers ─────────────────────────────────────────────────────────────

# Next backup name for $1: name.bak first, then name.bak01, name.bak02, ...
# Always one past the highest existing number, so the newest backup has the
# highest number even after older ones were deleted.
next_backup() {
  local backup n highest=-1
  if [[ -e "$1.bak" || -L "$1.bak" ]]; then
    highest=0
  fi
  for backup in "$1".bak[0-9]*; do
    n="${backup##*.bak}"
    if [[ "$n" =~ ^[0-9]+$ ]] && ((10#$n > highest)); then
      highest=$((10#$n))
    fi
  done
  if ((highest < 0)); then
    printf '%s\n' "$1.bak"
  else
    printf '%s.bak%02d\n' "$1" "$((highest + 1))"
  fi
}

# Move $1 out of the way under its next backup name
back_up() {
  local backup
  backup="$(next_backup "$1")"
  mv -- "$1" "$backup"
  ok "Backed up the old $(basename -- "$1") as $(basename -- "$backup")"
}

# Did install.sh put $1 there, unchanged since? Either a copy whose checksum
# is in the manifest, or a symlink into this folder (the earlier setup).
is_ours() {
  if [[ -L "$1" ]]; then
    [[ "$(realpath -m -- "$1")" == "$REPO_DIR"/* ]]
  elif [[ -f "$1" && -f "$MANIFEST" ]]; then
    grep -qxF -- "$(sha256sum -- "$1")" "$MANIFEST"
  else
    return 1
  fi
}

# Store $1's current checksum in the manifest, replacing any older entry.
# With "forget" as $2, only drop the entry.
manifest_record() {
  local path="$1" line
  local -a lines=()
  if [[ -f "$MANIFEST" ]]; then
    mapfile -t lines <"$MANIFEST"
  fi
  mkdir -p -- "$CONFIG_DIR"
  {
    for line in "${lines[@]}"; do
      if [[ "${line#*  }" != "$path" ]]; then
        printf '%s\n' "$line"
      fi
    done
    if [[ "${2-}" != forget ]]; then
      sha256sum -- "$path"
    fi
  } >"$MANIFEST"
}

# Copy $1 to $2 with mode $3. Already identical: nothing to do. Our own
# unchanged earlier copy (or old symlink): updated in place. Anything else is
# only replaced after asking, and kept as a backup.
install_file() {
  local src="$1" dst="$2" mode="$3" name="${2#"$BIN_DIR/"}" status
  if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s -- "$src" "$dst"; then
    chmod "$mode" -- "$dst"
    manifest_record "$dst"
    ok "$name (up to date)"
    return
  fi

  if [[ ! -e "$dst" && ! -L "$dst" ]]; then
    status="installed"
  elif [[ -L "$dst" && ! -e "$dst" ]] || is_ours "$dst"; then
    status="updated" # our earlier copy or link, or a dangling link
  elif [[ -d "$dst" && ! -L "$dst" ]]; then
    warn "Skipped $name: $dst is a directory"
    return
  elif ask "$dst already exists. Replace it? (the old one is kept as a backup)"; then
    back_up "$dst"
    status="installed"
  else
    warn "Skipped $name: kept the existing $dst"
    return
  fi

  rm -f -- "$dst"
  cp -- "$src" "$dst"
  chmod "$mode" -- "$dst"
  manifest_record "$dst"
  ok "$name ($status)"
}

# ─── Steps ────────────────────────────────────────────────────────────────────

check_requirements() {
  step "Checking requirements"

  ok "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"

  if grep -qP 'x' <<<"x" 2>/dev/null; then
    ok "GNU grep (with -P)"
  else
    warn "grep can't do -P (Perl regex): premierecinemas and organize need GNU grep"
  fi

  if find "$REPO_DIR" -maxdepth 0 -regextype posix-extended -iregex '.*' >/dev/null 2>&1; then
    ok "GNU find"
  else
    warn "find can't do -regextype: premierecinemas needs GNU find (findutils)"
  fi

  if command -v vlc >/dev/null; then
    ok "VLC"
  else
    warn "VLC not found: premierecinemas plays movies with it, install it with your package manager"
  fi

  if python3 -c 'import qbittorrentapi' >/dev/null 2>&1; then
    ok "python3 + qbittorrent-api (for qbt_relink.py)"
  else
    note "Optional, only for qbt_relink.py: pip install qbittorrent-api --break-system-packages"
  fi
}

choose_movies_dir() {
  step "Movies directory"

  local current default answer interactive=false
  current="$(config_get movies_dir)"
  default="${current:-$HOME/Movies}"

  if [[ -z "$MOVIES_ARG" ]] && ! $ASSUME_YES; then
    interactive=true
    printf '  Where do you keep your movies? premierecinemas plays them from there\n'
    printf '  and organize tidies that folder up. %b(Enter keeps the one in brackets, Tab completes)%b\n' "$DIM" "$RESET"
  fi

  # Interactive: ask again until we get a usable directory (e.g. after a typo
  # and "n" to creating it). Otherwise one attempt, then give up.
  while true; do
    answer="$MOVIES_ARG"
    if $interactive && ! read -r -e -p "  Movies directory [$default]: " answer; then
      interactive=false # input ran out, don't loop on it
    fi
    answer="${answer:-$default}"

    # read doesn't expand ~, so do it here. Then normalise the path the same way
    # premierecinemas --add-directory does (absolute, symlinks resolved).
    case "$answer" in
    \~) answer="$HOME" ;;
    \~/*) answer="$HOME/${answer#\~/}" ;;
    esac
    MOVIES_DIR="$(realpath -m -- "$answer")"

    if [[ -d "$MOVIES_DIR" ]]; then
      ok "$MOVIES_DIR"
      return
    elif [[ -e "$MOVIES_DIR" ]]; then
      warn "$MOVIES_DIR exists but is not a directory"
    elif ask "$MOVIES_DIR doesn't exist yet. Create it?"; then
      mkdir -p -- "$MOVIES_DIR"
      ok "Created $MOVIES_DIR"
      return
    fi

    $interactive || die "No usable Movies directory, nothing was changed"
  done
}

setup_config() {
  step "Config: $CONFIG_FILE"

  local had_config=false
  if [[ -f "$CONFIG_FILE" ]]; then
    had_config=true
  fi

  # premierecinemas writes its default config on first run. Let it, so that
  # template lives in one place (no-op when the config already exists).
  bash "$REPO_DIR/premierecinemas" --config >/dev/null

  # The Movies directory the config pointed at so far. Empty for configs made
  # before movies_dir= existed; then no search directory gets swapped out.
  local previous previous_dir=""
  previous="$(config_get movies_dir)"
  if [[ "$previous" == /* ]]; then
    previous_dir="$(realpath -m -s -- "$previous")" # tidied like dir= entries
  fi

  # dir= is premierecinemas' search list: the new Movies directory takes the
  # previous one's place. Any other search directories stay as they are.
  if config_has_dir "$MOVIES_DIR"; then
    if [[ -n "$previous_dir" && "$previous_dir" != "$MOVIES_DIR" ]]; then
      config_replace_dir "$previous_dir" ""
    fi
  elif [[ -n "$previous_dir" ]] && config_has_dir "$previous_dir"; then
    config_replace_dir "$previous_dir" "$MOVIES_DIR"
  else
    config_append "dir=$MOVIES_DIR"
  fi

  # movies_dir= is what organize and qbt_relink.py read
  if [[ "$previous" == "$MOVIES_DIR" ]]; then
    if $had_config; then
      ok "movies_dir=$MOVIES_DIR (unchanged)"
    else
      ok "movies_dir=$MOVIES_DIR"
    fi
  elif grep -q '^movies_dir=' "$CONFIG_FILE"; then
    config_replace_line "movies_dir=$previous" "movies_dir=$MOVIES_DIR"
    ok "movies_dir=$MOVIES_DIR"
  else
    config_append "" \
      "# Your Movies library — the folder organize tidies up (qbt_relink.py uses it too)." \
      "# Change it by re-running install.sh, which also keeps it in the dir= search list." \
      "movies_dir=$MOVIES_DIR"
    ok "movies_dir=$MOVIES_DIR"
  fi

  local d
  local -a dirs
  mapfile -t dirs < <(grep '^dir=' "$CONFIG_FILE" | cut -d= -f2-)
  ok "premierecinemas searches:"
  for d in "${dirs[@]}"; do
    printf '      %b▸%b %s\n' "$YELLOW" "$RESET" "$d"
  done
}

install_commands() {
  step "Commands: $BIN_DIR"
  mkdir -p -- "$BIN_DIR"

  local name
  for name in "${COMMANDS[@]}"; do
    install_file "$REPO_DIR/$name" "$BIN_DIR/$name" 755
  done
}

install_art() {
  step "Intro art: $ART_DIR"

  # The art belongs in a real folder here. A link that is broken, or points
  # to the old place or into this git folder, is replaced by one (the files
  # are moved/copied in below).
  local target
  if [[ -L "$ART_DIR" ]]; then
    target="$(realpath -m -- "$ART_DIR")"
    if [[ ! -e "$ART_DIR" || "$target" == "$(realpath -m -- "$OLD_ART_DIR")" || "$target" == "$REPO_DIR"/* ]]; then
      rm -- "$ART_DIR"
    fi
  fi
  if [[ -e "$ART_DIR" && ! -d "$ART_DIR" ]]; then
    warn "Skipped: $ART_DIR exists but is not a directory"
    return
  fi
  mkdir -p -- "$ART_DIR"

  # Files still in the old place move over. A different file of the same name
  # already here is kept as a backup. (Both loops read their file list on fd 3,
  # so stdin stays free for the questions install_file may ask.)
  local src dst name
  if [[ -d "$OLD_ART_DIR" && ! -L "$OLD_ART_DIR" ]]; then
    while IFS= read -r -d '' -u 3 src; do
      name="$(basename -- "$src")"
      dst="$ART_DIR/$name"
      if [[ "$src" -ef "$dst" ]]; then
        continue # the very same file (linked folders), nothing to move
      elif [[ -f "$dst" && ! -L "$dst" ]] && cmp -s -- "$src" "$dst"; then
        rm -- "$src"
      else
        if [[ -e "$dst" || -L "$dst" ]]; then
          back_up "$dst"
        fi
        mv -- "$src" "$dst"
      fi
      ok "Moved $name over from $OLD_ART_DIR"
    done 3< <(find "$OLD_ART_DIR" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

    if rmdir -- "$OLD_ART_DIR" 2>/dev/null; then
      ok "Removed the empty $OLD_ART_DIR"
    else
      note "$OLD_ART_DIR still has other things in it, so it stays"
    fi
  fi

  # The art that comes with premierecinemas (art/ in this folder)
  if [[ -d "$REPO_DIR/art" ]]; then
    while IFS= read -r -d '' -u 3 src; do
      install_file "$src" "$ART_DIR/$(basename -- "$src")" 644
    done 3< <(find "$REPO_DIR/art" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  fi

  if [[ ! -f "$ART_DIR/intro.txt" ]]; then
    note "No intro.txt here yet, so premierecinemas skips its intro until you add one"
  fi
}

ensure_path() {
  step "PATH"

  if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
    ok "$BIN_DIR is on your PATH"
    # A same-named command earlier in PATH would win over ours
    local name found
    for name in "${COMMANDS[@]}"; do
      found="$(type -P "$name" || true)"
      if [[ -n "$found" && "$found" != "$BIN_DIR/$name" ]]; then
        warn "\"$name\" runs $found instead: that folder comes before $BIN_DIR in your PATH"
      fi
    done
    return
  fi

  local rc=""
  case "$(basename -- "${SHELL:-}")" in
  bash) rc="$HOME/.bashrc" ;;
  zsh) rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
  esac

  if [[ -n "$rc" ]] && grep -qxF -- "$PATH_MARKER" "$rc" 2>/dev/null; then
    ok "Already added to $rc, open a new terminal to pick it up"
    PATH_STATE="new-terminal"
  elif [[ -n "$rc" ]] && ask "$BIN_DIR is not on your PATH yet. Add it to $rc?"; then
    printf '\n%s\n%s\n' "$PATH_MARKER" "$PATH_LINE" >>"$rc"
    ok "Added to $rc, open a new terminal (or run: source $rc) to pick it up"
    PATH_STATE="new-terminal"
  else
    warn "$BIN_DIR is not on your PATH. Add this line to your shell's startup file:"
    printf '      %s\n' "$PATH_LINE"
    PATH_STATE="manual"
  fi
}

uninstall() {
  step "Removing the commands from $BIN_DIR"

  local name dst backup
  for name in "${COMMANDS[@]}"; do
    dst="$BIN_DIR/$name"
    if is_ours "$dst"; then
      rm -- "$dst"
      manifest_record "$dst" forget
      ok "Removed $dst"
    elif [[ -e "$dst" || -L "$dst" ]]; then
      warn "Left $dst alone: it was changed after install.sh copied it, or isn't ours"
    else
      ok "$name wasn't installed"
    fi
    for backup in "$dst".bak*; do
      if [[ -e "$backup" || -L "$backup" ]]; then
        note "Backup of an earlier $name: $backup"
      fi
    done
  done

  printf '\n  Kept your settings (%s) and the intro art (%s).\n' "$CONFIG_FILE" "$ART_DIR"
}

# ─── Help / summary ───────────────────────────────────────────────────────────

print_help() {
  printf '%b%binstall.sh%b — set up premierecinemas, organize and qbt_relink.py\n\n' "$BOLD" "$YELLOW" "$RESET"
  printf '  Asks for your Movies directory and saves it to the shared config,\n'
  printf '  copies the three commands and the intro art into %s\n' "$BIN_DIR"
  printf '  and makes sure that folder is on your PATH. Safe to re-run any time,\n'
  printf '  e.g. after a git pull to update the installed copies.\n\n'
  printf '%b%bUSAGE%b\n' "$BOLD" "$CYAN" "$RESET"
  printf '  ./install.sh [OPTIONS]\n\n'
  printf '%b%bOPTIONS%b\n' "$BOLD" "$CYAN" "$RESET"
  printf '  %b-m, --movies-dir PATH%b\n' "$GREEN" "$RESET"
  printf '        Use PATH as your Movies directory instead of asking.\n\n'
  printf '  %b-y, --yes%b\n' "$GREEN" "$RESET"
  printf '        Answer every question with its default (no prompts).\n\n'
  printf '  %b--uninstall%b\n' "$GREEN" "$RESET"
  printf '        Remove the commands from %s (config and art are kept).\n\n' "$BIN_DIR"
  printf '  %b-h, --help%b\n' "$GREEN" "$RESET"
  printf '        Show this help and exit.\n\n'
  printf '%b%bCONFIG FILE%b\n' "$BOLD" "$CYAN" "$RESET"
  printf '  %b%s%b\n\n' "$DIM" "$CONFIG_FILE" "$RESET"
}

print_done() {
  printf '\n%b%bAll set!%b ' "$BOLD" "$GREEN" "$RESET"
  case "$PATH_STATE" in
  ready) printf 'Try:\n' ;;
  new-terminal) printf 'Open a new terminal, then try:\n' ;;
  manual) printf 'Once %s is on your PATH, try:\n' "$BIN_DIR" ;;
  esac
  printf '  %bpremierecinemas interstellar%b   find a movie and play it\n' "$CYAN" "$RESET"
  printf '  %borganize --dry-run%b             preview how organize would tidy %s\n' "$CYAN" "$RESET" "$MOVIES_DIR"
  printf '  %borganize%b                       tidy it for real\n' "$CYAN" "$RESET"
  printf '  %bqbt_relink.py%b                  then check qBittorrent (asks for its login once)\n\n' "$CYAN" "$RESET"
  printf '  The commands no longer need this folder. Re-run %s after a\n' "$REPO_DIR/install.sh"
  printf '  git pull to update them, or to switch to a different Movies directory.\n'
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    die "bash 4.4 or newer is needed (this is bash $BASH_VERSION)"
  fi
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    die "Run this without sudo: it sets things up in your own home folder"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -m | --movies-dir)
      [[ -n "${2-}" ]] || die "$1 needs a path"
      MOVIES_ARG="$2"
      shift 2
      ;;
    -y | --yes)
      ASSUME_YES=true
      shift
      ;;
    --uninstall)
      uninstall
      exit 0
      ;;
    -h | --help)
      print_help
      exit 0
      ;;
    *)
      die "Unknown option: $1 (see ./install.sh --help)"
      ;;
    esac
  done

  printf '%b%bpremierecinemas setup%b\n' "$BOLD" "$YELLOW" "$RESET"
  check_requirements
  choose_movies_dir
  setup_config
  install_commands
  install_art
  ensure_path
  print_done
}

main "$@"
