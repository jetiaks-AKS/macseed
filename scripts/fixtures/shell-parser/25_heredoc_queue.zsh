f() {
 cat <<FIRST <<'SECOND'
} not_end
FIRST
fake() { :; }
SECOND
 print done
}
