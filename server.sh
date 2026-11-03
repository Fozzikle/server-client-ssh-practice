
# get ip address
get_ip(){
  ifconfig 2>/dev/null \
  | grep -E 'inet (addr:)?[0-9]' \
  | grep -v '127\.0\.0\.1' \
  | head -n 1 \
  | awk '{
      sub(/addr:/, "", $2)
      print $2
  }'
}

get_ip