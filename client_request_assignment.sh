#!/bin/bash

# assumption of same container IP/port
SERVER_IP="172.17.0.2"
SERVER_PORT="1234"

printf 'assignment\n' | nc -N "$SERVER_IP" "$SERVER_PORT" > assignment.json

if [ -s assignment.json ]; then
    echo "Assignment information received successfully."
    cat assignment.json
else
    echo "Error: Failed to receive assignment information."
fi