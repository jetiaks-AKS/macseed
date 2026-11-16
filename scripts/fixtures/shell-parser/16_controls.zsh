f() {
 local item result=0
 for item in "$@"; do
  if [[ -f "$item" ]]; then
   print -r -- "$item"
  elif [[ -d "$item" ]]; then
   (( result += 1 ))
  else
   continue
  fi
 done
 while (( result > 0 )); do (( result-- )); done
 until (( result == 0 )); do break; done
 return "$result"
}
