export EDITOR=nano

# brew
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

# zsh
ZDOTDIR="$HOME/.config/zsh"

# gpg-agent
export GPG_TTY=${TTY}

# prepends dir to PATH if dir exists and is not already in PATH
pupdate() { [ -d "$1" ] && case ":${PATH:=$1}:" in *:"$1":*) ;; *) PATH="$1:$PATH" ;; esac; }

# set PATH so it includes user's private bin
pupdate ${HOME}/bin
pupdate ${HOME}/.local/bin

# golang
pupdate /usr/local/go/bin
pupdate ${HOME}/Developer/bin
[ -d "$HOME/Developer" ] && export GOPATH="$HOME/Developer"

# aws-cli
[ -f "$HOME/.config/aws/config" ] && export AWS_CONFIG_FILE="$HOME/.config/aws/config"

# elastic beanstalk
pupdate ${HOME}/.ebcli-virtual-env/executables

# tell rclone to use pass if it exists
[ -d "$HOME/.password-store" ] && export RCLONE_PASSWORD_COMMAND="pass rclone/config"

# completions that CLIs install for themselves (sentry, copilot)
fpath=("${HOME}/.local/share/zsh/site-functions" $fpath)
