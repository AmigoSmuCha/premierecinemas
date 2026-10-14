#!/usr/bin/env bash
# =============================================================================
#  install.sh — one-step setup for premierecinemas and organize
# =============================================================================
#  1. Checks the tools the scripts rely on (VLC, GNU grep/find, ...)
#  2. Asks where your Movies directory is and saves it in the shared config
#     (~/.config/premierecinemas/config): premierecinemas plays from it,
#     organize (and qbt_relink.py) work on it
#  3. Links premierecinemas and organize into ~/.local/bin (symlinks, so a
#     git pull in this folder updates the installed commands too)
#  4. Puts ~/.local/bin on your PATH if it isn't there yet
#
#  Safe to re-run, e.g. to switch everything to a different Movies directory.
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
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/premierecinemas/config"

# Scripts that get linked into $BIN_DIR
COMMANDS=(premierecinemas organize)

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

config_has_line() {
  grep -qxF -- "$1" "$CONFIG_FILE"
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

  if [[ ! -f "$REPO_DIR/art/intro.txt" ]]; then
    note "No art/intro.txt here, so premierecinemas skips its intro until you add one"
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
  local previous
  previous="$(config_get movies_dir)"

  # dir= is premierecinemas' search list: the new Movies directory takes the
  # previous one's place. Any other search directories stay as they are.
  if config_has_line "dir=$MOVIES_DIR"; then
    if [[ -n "$previous" && "$previous" != "$MOVIES_DIR" ]]; then
      config_replace_line "dir=$previous" ""
    fi
  elif [[ -n "$previous" ]] && config_has_line "dir=$previous"; then
    config_replace_line "dir=$previous" "dir=$MOVIES_DIR"
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

  local name src dst backup
  for name in "${COMMANDS[@]}"; do
    src="$REPO_DIR/$name"
    dst="$BIN_DIR/$name"
    chmod +x -- "$src"

    if [[ -L "$dst" && "$(realpath -m -- "$dst")" == "$src" ]]; then
      ok "$name (already linked)"
      continue
    elif [[ -d "$dst" && ! -L "$dst" ]]; then
      warn "Skipped $name: $dst is a directory"
      continue
    elif [[ -e "$dst" ]]; then
      # An older copy of the script, or another program with the same name.
      # (A dangling symlink, e.g. into a moved clone, is simply replaced.)
      if ! ask "$dst already exists. Replace it? (the old one is kept as a backup)"; then
        warn "Skipped $name: kept the existing $dst"
        continue
      fi
      backup="$dst.bak"
      if [[ -e "$backup" || -L "$backup" ]]; then
        backup="$dst.bak.$(date +%Y%m%d%H%M%S)"
      fi
      mv -- "$dst" "$backup"
      ok "Moved the old $name to $backup"
    fi

    ln -sfn -- "$src" "$dst"
    ok "$name → $src"
  done
}

ensure_path() {
  step "PATH"

  if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
    ok "$BIN_DIR is on your PATH"
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
  step "Removing commands from $BIN_DIR"

  local name dst
  for name in "${COMMANDS[@]}"; do
    dst="$BIN_DIR/$name"
    if [[ -L "$dst" && "$(realpath -m -- "$dst")" == "$REPO_DIR/$name" ]]; then
      rm -- "$dst"
      ok "Removed $dst"
    elif [[ -e "$dst" || -L "$dst" ]]; then
      warn "Left $dst alone: it isn't a link to this folder"
    else
      ok "$name wasn't installed"
    fi
    if [[ -e "$dst.bak" || -L "$dst.bak" ]]; then
      note "Your previous $name is still at $dst.bak, rename it back if you want it"
    fi
  done

  printf '\n  Your settings are kept in %s (delete it to start fresh).\n' "$CONFIG_FILE"
}

# ─── Help / summary ───────────────────────────────────────────────────────────

print_help() {
  printf '%b%binstall.sh%b — set up premierecinemas and organize\n\n' "$BOLD" "$YELLOW" "$RESET"
  printf '  Asks for your Movies directory and saves it to the shared config,\n'
  printf '  links premierecinemas and organize into %s and makes sure\n' "$BIN_DIR"
  printf '  that folder is on your PATH. Safe to re-run any time.\n\n'
  printf '%b%bUSAGE%b\n' "$BOLD" "$CYAN" "$RESET"
  printf '  ./install.sh [OPTIONS]\n\n'
  printf '%b%bOPTIONS%b\n' "$BOLD" "$CYAN" "$RESET"
  printf '  %b-m, --movies-dir PATH%b\n' "$GREEN" "$RESET"
  printf '        Use PATH as your Movies directory instead of asking.\n\n'
  printf '  %b-y, --yes%b\n' "$GREEN" "$RESET"
  printf '        Answer every question with its default (no prompts).\n\n'
  printf '  %b--uninstall%b\n' "$GREEN" "$RESET"
  printf '        Remove the commands from %s (your config is kept).\n\n' "$BIN_DIR"
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
  printf '  %borganize%b                       tidy it for real\n\n' "$CYAN" "$RESET"
  printf '  Re-run %s any time to switch to a different Movies directory.\n' "$REPO_DIR/install.sh"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  if ((BASH_VERSINFO[0] < 4)); then
    die "bash 4 or newer is needed (this is bash $BASH_VERSION)"
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
  ensure_path
  print_done
}

main "$@"
