
get_ip(){
  ifconfig 2>/dev/null |
  grep -E 'inet (addr:)?[0-9]' |
  # ignores the localhost address
  grep -v '127\.0\.0\.1' |
  # prioritise top address
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
  awk -v ip="$IP" '$1 == "LISTEN" && ($4 ~ /^\*:/ || $4 ~ /^0\.0\.0\.0:/ || index($4, ip ":") == 1){
    n = split($4, a, ":")
    print a[n]
    exit
  }'
}

IP=$(get_ip)
PORT=$(get_port)
# Landing message
echo "The server is running at $IP, port=$PORT"
echo "Listening on $IP $PORT"

# check for incoming connections
while true; do
  nc -l -p "$PORT" -v
done
