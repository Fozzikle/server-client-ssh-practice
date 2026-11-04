#!/bin/bash
#test
SERVER_IP="LocalHost"
SERVER_PORT="1234"

echo "Connecting to $SERVER_IP:$SERVER_PORT..."

(printf 'assignment\n'; sleep 5) | nc localhost 1234 > assignment.json

NC_STATUS=$?

echo "Netcat exit status: $NC_STATUS"
echo "Received file size: $(wc -c < assignment.json) bytes"

if [ -s assignment.json ]; then
    echo "Assignment information received:"
    cat assignment.json
else
    echo "Error: Received an empty response."
fi