emulate -L zsh
local arg
for arg in "$@"; do print -r -- "$arg"; done
