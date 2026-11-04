#!/bin/bash

# assumption of same container IP/port
SERVER_IP="LocalHost"
SERVER_PORT="1234"

printf 'assignment\n' | nc "$SERVER_IP" "$SERVER_PORT" > assignment.json

if [ $? -eq 0 ] && [ -s assignment.json ]; then
    echo "Assignment information received successfully."
    cat assignment.json
else
    echo "Error: Failed to receive assignment information."
fi