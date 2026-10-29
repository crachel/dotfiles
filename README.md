# dotfiles

Configs for zsh, git, zellij, tmux, Ghostty, Zed, btop and a few other tools, on macOS and Linux.
Each top-level directory is a [GNU Stow](https://www.gnu.org/software/stow/) package laid out like `$HOME`.

## Install

```sh
git clone https://github.com/crachel/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow aws bat btop ghostty git gpg tmux yt-dlp zed zellij zsh
```

Stow only the packages for tools you have. `.stowrc` passes `--no-folding`, so stow links individual
files and leaves directories like `~/.config/zsh` as real directories other files can live in.

`shell/aliases.sh` isn't a stow package; `.zshrc` sources it straight from `~/.dotfiles`.

## Kept out of the repo

- rclone config (it holds storage credentials) lives in `pass` as `rclone/rclone.conf`.
  `rclone-conf-pull` (from `shell/aliases.sh`) writes it to `~/.config/rclone/rclone.conf`;
  after editing it, `rclone-conf-push` stores it back.
- Per-machine zsh startup: `~/.config/zsh/.zprofile` and `~/.config/zsh/.zlogin`.
