#!/usr/bin/env bash
#
# Define functions and aliases for various systems

OS_NAME=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')

alias cp="cp -iv"
alias mv="mv -iv"
alias rm="rm -iv"

alias tree="tree -IC \".git*\""

# gdu: interactive disk usage (arrows to browse, d deletes). Homebrew names it gdu-go so it doesn't
# shadow coreutils' GNU du; Linux packages call it gdu.
command -v gdu-go >/dev/null 2>&1 && alias gdu='gdu-go'

# eza (maintained fork of exa) when present, plain ls otherwise.
# The fallbacks pick up the per-OS `ls` color alias defined below.
if command -v eza >/dev/null 2>&1; then
  alias l='eza --icons=auto --group-directories-first'
  alias ll='eza -lh --icons=auto --group-directories-first --git'
  alias la='eza -lha --icons=auto --group-directories-first --git'
  alias lt='eza --tree --level=2 --icons=auto'
  # ls -Farlt: everything, newest last (eza's modified sort is already oldest-first)
  alias lrt='eza -laF --sort=modified --icons=auto --git'
else
  alias l='ls -CF'
  alias ll='ls -alF'
  alias la='ls -A'
  alias lrt='ls -Farlt'
fi

# a scratch buffer in the terminal; the first call starts the emacs daemon, later ones attach in an instant
# and find the buffer as it was left. It lives only as long as the daemon (lost on reboot).
alias scratch='emacsclient -t -a "" -e "(switch-to-buffer \"*scratch*\")"'

alias ssh-keygen='ssh-keygen -C $(whoami)@$(hostname)-$(date +%Y-%m-%d)'

# forward strawn and its backends from the mini, and hold the SOCKS proxy on :1337 that leaves through aws,
# both kept up in the background by launchd; `couch` shows it live, `couch help` lists the rest. See couch.sh.
alias couch="$HOME/.dotfiles/shell/couch.sh"

mountt() { mount | column -t | sort; }

# rclone.conf holds storage credentials, so it lives in pass (rclone/rclone.conf), not in this repo.
# After editing it, rclone-conf-push; then rclone-conf-pull on the other machines.
rclone-conf-push() { pass insert -m -f rclone/rclone.conf < "$HOME/.config/rclone/rclone.conf" && pass git push; }
rclone-conf-pull() {
  local f="$HOME/.config/rclone/rclone.conf"
  # decrypt to a temp file first so a failed pull or decrypt can't clobber the working config
  mkdir -p "${f%/*}" && pass git pull && (umask 077; pass show rclone/rclone.conf > "$f.new") &&
    command mv -f "$f.new" "$f" || { command rm -f "$f.new"; return 1; }
}

# Shell history syncs through our own atuin server on the mini. Its encryption key and the account
# password live in pass (atuin/key, atuin/password). Run atuin-login once per new machine: it imports
# this machine's zsh history, signs in, and syncs both ways. Lines zsh saved without a timestamp (before
# extended_history) are stamped with the import time, so they sort as recent until newer commands pass them.
atuin-login() {
  HISTFILE=${HISTFILE:-$HOME/.config/zsh/.zsh_history} atuin import zsh &&
    pass git pull -q && atuin login -u crachel -p "$(pass show atuin/password)" -k "$(pass show atuin/key)" &&
    atuin sync
}

# `multipass launch` bridges by default on machines with local.bridged-network set. An explicit
# --bridged or --network is left alone; `command multipass launch` skips this.
multipass() {
  if [ "$1" = launch ] && [ "$(command multipass get local.bridged-network)" != "<empty>" ]; then
    case " $* " in
      *" --bridged "* | *" --network"*) ;;
      *) shift; set -- launch --bridged "$@" ;;
    esac
  fi
  command multipass "$@"
}

# Distro-specific aliases and functions
case ${OS_NAME} in
  darwin)
    alias ls="command ls -G"
    # the Tailscale app doesn't put its CLI on PATH
    if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
      alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    fi
    ;;
  linux)
    if [ -x "$(command -v lsblk)" ]; then
      alias lsblk="lsblk --byte -o NAME,FSTYPE,SIZE,MOUNTPOINT,LABEL"
    fi
    alias ls="command ls --color"
    ;;
  *)
    ;;
esac
