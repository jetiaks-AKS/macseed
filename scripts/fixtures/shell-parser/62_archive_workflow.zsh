unpack() {
 emulate -L zsh
 setopt localoptions noclobber
 if (( $# == 0 )); then
  cat <<'USAGE'
usage: unpack archive ...
This is text: fake() { }
USAGE
  return 2
 fi
 local archive
 for archive in "$@"; do
  [[ -f "$archive" ]] || continue
  case "$archive" in
   (*.tar.gz|*.tgz) tar -xzf "$archive" ;;
   (*.zip) unzip "$archive" ;;
   (*) print -u2 -r -- "unsupported: $archive"; return 2 ;;
  esac
 done
}
