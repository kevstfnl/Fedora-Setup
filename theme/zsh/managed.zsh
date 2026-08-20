# FEDORA_POST_INSTALL_MANAGED
# Ce fichier est copié dans ~/.config/fedora-post-install/zsh/ par le script.

export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
[[ -d "$BUN_INSTALL/bin" ]] && path=("$BUN_INSTALL/bin" $path)

if (( ! $+functions[nvm] )); then
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    export NVM_DIR="$XDG_CONFIG_HOME/nvm"
  else
    export NVM_DIR="$HOME/.nvm"
  fi
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
  [[ -s "$NVM_DIR/bash_completion" ]] && source "$NVM_DIR/bash_completion"
fi

ZSH_THEME="clean"
plugins=(git dnf sudo systemd)
(( $+commands[docker] )) && plugins+=(docker docker-compose)
(( $+commands[npm] )) && plugins+=(npm node)
(( $+commands[bun] )) && plugins+=(bun)

[[ -r "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

(( $+commands[fzf] )) && source <(fzf --zsh)
(( $+commands[zoxide] )) && source <(zoxide init zsh)
[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] &&
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# La coloration syntaxique doit rester le dernier plugin chargé.
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] &&
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Une dépendance facultative absente ne doit pas faire échouer le chargement.
true
