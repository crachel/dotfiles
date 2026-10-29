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
zstyle ':vcs_info:git:*' formats '%F{white}(%b)%r%f'
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
