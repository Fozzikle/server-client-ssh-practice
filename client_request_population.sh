#!/bin/bash

SERVER_IP="localhost"
SERVER_PORT="1234"
RESPONSE_FILE="/tmp/population_response"
OUTPUT_FILE="population.png"

if ! command -v nc >/dev/null 2>&1; then
    echo "ERROR: Netcat is not installed."
    exit 1
fi

echo "Connecting to $SERVER_IP:$SERVER_PORT..."
echo "Request: population"

# Send request and save the response as a file.
if ! (printf 'population\n'; sleep 5) |
     nc -w 30 "$SERVER_IP" "$SERVER_PORT" > "$RESPONSE_FILE"; then

    echo "ERROR: Netcat connection failed."
    exit 1
fi

if [ ! -s "$RESPONSE_FILE" ]; then
    echo "ERROR: Server returned an empty response."
    exit 1
fi

# Check whether the received file has a PNG signature.
# Read the population value from the first line.
IFS= read -r population_header < "$RESPONSE_FILE"

# Extract the population number.
population=${population_header#NSW_POPULATION=}

# Display the population in the client terminal.
echo "NSW population in 2025: $population"

# Calculate the length of the text header.
header_length=$((${#population_header} + 1))

# Extract the PNG data, excluding the text header.
tail -c +$((header_length + 1)) "$RESPONSE_FILE" > "$OUTPUT_FILE"

# Check whether the extracted file has a PNG signature.
PNG_SIGNATURE=$(od -An -tx1 -N8 "$OUTPUT_FILE" | tr -d ' \n')

if [ "$PNG_SIGNATURE" != "89504e470d0a1a0a" ]; then
    echo "ERROR: Server did not return a valid PNG image."
    rm -f "$RESPONSE_FILE" "$OUTPUT_FILE"
    exit 1
fi

echo "Population plot received successfully."
echo "Saved as: $OUTPUT_FILE"

rm -f "$RESPONSE_FILE"
exit 0