emulate -L zsh
local -a entries
entries=("$@")
local entry
for entry in "${entries[@]}"; do
 [[ -e "$entry" ]] || continue
 print -r -- "${entry:A}"
done
