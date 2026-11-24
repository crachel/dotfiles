# dotfiles

Configs for zsh, git, zellij, tmux, Ghostty, Zed, btop and a few other tools, on macOS and Linux.
Each top-level directory is a [GNU Stow](https://www.gnu.org/software/stow/) package laid out like `$HOME`.

## Install

```sh
git clone https://github.com/crachel/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow atuin aws bat btop emacs ghostty git gpg tmux yt-dlp zed zellij zsh
```

Stow only the packages for tools you have. `.stowrc` passes `--no-folding`, so stow links individual
files and leaves directories like `~/.config/zsh` as real directories other files can live in.

`shell/aliases.sh` isn't a stow package; `.zshrc` sources it straight from `~/.dotfiles`.

## Kept out of the repo

- Shell history syncs through a self-hosted atuin server on the mini (`brew install atuin-server`,
  config in `/opt/homebrew/etc/atuin-server/server.toml`, run by `brew services`). It listens only on
  the mini's Tailscale address, stores SQLite in `/opt/homebrew/var/atuin-server/`, and has
  registration closed. History is encrypted on each machine before upload; the key and account
  password live in `pass` as `atuin/key` and `atuin/password`. On a new machine: `stow atuin`, then
  `atuin-login`.
- rclone config (it holds storage credentials) lives in `pass` as `rclone/rclone.conf`.
  `rclone-conf-pull` (from `shell/aliases.sh`) writes it to `~/.config/rclone/rclone.conf`;
  after editing it, `rclone-conf-push` stores it back.
- Per-machine zsh startup: `~/.config/zsh/.zprofile` and `~/.config/zsh/.zlogin`.
