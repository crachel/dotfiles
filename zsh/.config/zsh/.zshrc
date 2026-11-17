# keep only the first copy of each PATH/fpath entry; applies to path=(...) assignments, not PATH="...:$PATH"
typeset -U path fpath

fpath=(~/.config/zsh/functions $fpath)

autoload -Uz compinit
compinit

PROMPT='%(?.%F{green}√.%F{red}?%?)%f %B%F{white}$USER@%m:%~%f%b %# '

autoload -Uz vcs_info
precmd_vcs_info() { vcs_info }
precmd_functions+=( precmd_vcs_info )
setopt prompt_subst
RPROMPT=\$vcs_info_msg_0_
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr '*'
zstyle ':vcs_info:*' stagedstr '+'
zstyle ':vcs_info:git:*' formats '%F{white}(%b%u%c)%r%f'
zstyle ':vcs_info:git:*' actionformats '%F{white}(%b|%a%u%c)%r%f'
zstyle ':vcs_info:*' enable git

HISTFILE=~/.config/zsh/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt append_history
setopt hist_expire_dups_first
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt hist_verify
setopt inc_append_history
setopt share_history

# aliases
[ -f "$HOME/.dotfiles/shell/aliases.sh" ] && source "$HOME/.dotfiles/shell/aliases.sh"

# fd lists files for fzf: faster than find, skips .gitignored paths, includes dotfiles but not .git.
# Debian/Ubuntu ship it as fdfind.
if command -v fd >/dev/null || command -v fdfind >/dev/null; then
  _fd=$(command -v fd || command -v fdfind)
  export FZF_DEFAULT_COMMAND="$_fd --type f --hidden --follow --exclude .git"
  export FZF_CTRL_T_COMMAND="$_fd --hidden --follow --exclude .git"
  export FZF_ALT_C_COMMAND="$_fd --type d --hidden --follow --exclude .git"
  # `vim **<Tab>` and `cd **<Tab>` completion
  _fzf_compgen_path() { "$_fd" --hidden --follow --exclude .git . "$1"; }
  _fzf_compgen_dir()  { "$_fd" --type d --hidden --follow --exclude .git . "$1"; }
fi
# previews: bat for files, an eza tree for directories
if command -v bat >/dev/null && command -v eza >/dev/null; then
  export FZF_CTRL_T_OPTS="--preview '[[ -d {} ]] && eza --tree --level=2 --color=always {} || bat --color=always --style=numbers --line-range=:300 {}'"
  export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --color=always --icons=auto {}'"
fi

# fzf: Ctrl-R history, Ctrl-T files, Alt-C cd (fzf 0.48+ prints its own zsh setup)
command -v fzf >/dev/null && source <(fzf --zsh)

# ~/.local/bin is also in .zshenv, but macOS's path_helper (/etc/zprofile) puts the system dirs ahead of it
path=($HOME/.local/bin /opt/homebrew/opt/libpq/bin $path)

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
command -v pyenv >/dev/null && eval "$(pyenv init -)"

# zellij: over ssh, a bare `zellij` starts its session in the nord theme (gray-blue bar) so you can
# tell you're on another machine. Other invocations (attach, ls, ...) pass through.
if [[ -n $SSH_CONNECTION ]]; then
  zellij() { (( $# )) && command zellij "$@" || command zellij options --theme nord; }
fi
