project() {
 local target=${1:-$HOME/Projects}
 [[ -d "$target" ]] || return 1
 cd -- "$target" || return
 if (( $+commands[git] )); then
  git status --short
 fi
}
