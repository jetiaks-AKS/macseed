walk() {
 local depth=${1:-0}
 (( depth > 0 )) && walk $((depth - 1))
}
