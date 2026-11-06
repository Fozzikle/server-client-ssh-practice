#!/bin/bash

SERVER_IP="localhost"
SERVER_PORT="1234"

echo "SERVER CONNECTION TESTS"

echo "TEST A: Server is not running"

# Attempt to connect to the server.
nc -z -w 3 "$SERVER_IP" "$SERVER_PORT" >/dev/null 2>&1

NC_STATUS=$?

if [ "$NC_STATUS" -ne 0 ]; then
    echo "PASS: Connection failed because the server is not running."
else
    echo "FAIL: A connection was established. Is the server running?"
fi
