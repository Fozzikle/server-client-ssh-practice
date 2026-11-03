
# get ip address
get_ip(){
  ifconfig 2>/dev/null |
  grep -E 'inet (addr:)?[0-9]' |
  grep -v '127\.0\.0\.1' |
  head -n 1 |
  awk '{
      sub(/addr:/, "", $2)
      print $2
  }'
}

get_port(){
  IP=$(get_ip)

  ss -lnt 2>/dev/null |
  # Looks for IP match or Local Address == *
  awk -v ip="$IP" '$1 == "LISTEN" && ($4 ~ /^\*:/ || index($4, ip ":") == 1){
    n = split($4, a, ":")
    print a[n]
    exit
  }'
}

echo "The server is running at $(get_ip), port=$(get_port)"
