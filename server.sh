ASSIGNMENT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"

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

while true; do
  # Wait for a client's request
  request=$(nc -l -p "$PORT" -v)
  nc_status=$?

  if [ "$nc_status" -ne 0 ]; then
    echo "Error: Failed to received client request"
    continue
  fi

  if [ "$request" = "assignment" ]; then
    curl -fsSL "$ASSIGNMENT_URL" | html2text

  elif [ -z "$request" ]; then
    echo "Error: Empty request received"

  else
    echo "Error: Invalid request '$request'."
  fi

done
