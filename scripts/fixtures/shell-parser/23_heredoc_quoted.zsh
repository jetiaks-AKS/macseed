f() {
 cat <<'END'
fake() { }
}
$(not_a_command)
END
 print done
}
