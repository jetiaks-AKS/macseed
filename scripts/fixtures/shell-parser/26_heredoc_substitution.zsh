f() {
 local v="$(cat <<END
}
END
)"
 print -r -- "$v"
}
