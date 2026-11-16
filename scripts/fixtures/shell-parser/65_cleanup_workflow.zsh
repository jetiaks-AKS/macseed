with_state() {
 local state=ready
 {
  while (( $# )); do
   case "$1" in
    (--stop) return 0 ;;
    (*) consume "$1"; shift ;;
   esac
  done
 } always {
  state=finished
 }
}
