#!/usr/bin/env bash
#
# Define functions and aliases for various systems

OS_NAME=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')

alias cp="cp -iv"
alias mv="mv -iv"
alias rm="rm -iv"

alias tree="tree -IC \".git*\""

alias ssh-keygen='ssh-keygen -C $(whoami)@$(hostname)-$(date +%Y-%m-%d)'

# forward strawn (:3004 on the mini, over tailscale) to localhost:3004 here; no shell, ctrl-c to stop,
# exits on its own if the connection dies (laptop sleep, wifi change)
alias couch="ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 3004:localhost:3004 mini"

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
