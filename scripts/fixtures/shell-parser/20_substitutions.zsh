f() {
 local now="$(print -r -- "$(print inner)")"
 local old=`print old`
 print -r -- "${now:-${old}}" "$((2 + (3 * 4)))"
}
