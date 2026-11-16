branches() {
 local -a names
 names=("${(@f)$(git branch --format='%(refname:short)')}")
 local choice
 choice=$(print -rl -- "${names[@]}" | select_item) || return
 [[ -n "$choice" ]] && git switch -- "$choice"
}
compdef _git branches
