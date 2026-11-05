#!/bin/bash

SERVER_IP="localhost"
SERVER_PORT="1234"

OUTPUT_FILE="poi.json"

# Check that netcat is installed.
if ! command -v nc >/dev/null 2>&1; then
    echo "Error: Netcat is not installed."
    exit 1
fi

# Check that jq is installed.
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is not installed."
    exit 1
fi

echo "NSW POI SEARCH"
echo "1. Search by POI name"
echo "2. Search by coordinates"
echo

read -r -p "Select search method (1 or 2): " SEARCH_METHOD

case "$SEARCH_METHOD" in

    1)
        read -r -p "Enter POI name: " POI_NAME

        if [ -z "$POI_NAME" ]; then
            echo "Error: POI name cannot be empty."
            exit 1
        fi

        read -r -p "Enter search distance (metres): " DISTANCE

        REQUEST="poi name=\"$POI_NAME\" distance=$DISTANCE"
        ;;

    2)
        read -r -p "Enter latitude: " LATITUDE
        read -r -p "Enter longitude: " LONGITUDE
        read -r -p "Enter search distance (metres): " DISTANCE

        REQUEST="poi lat=$LATITUDE lon=$LONGITUDE distance=$DISTANCE"
        ;;

    *)
        echo "Error: Invalid search method."
        exit 1
        ;;

esac

echo
echo "Connecting to $SERVER_IP:$SERVER_PORT..."

# Remove any previous response file.
rm -f "$OUTPUT_FILE"

# Send the request and save the server response.
if ! printf '%s\n' "$REQUEST" | nc -w 30 "$SERVER_IP" "$SERVER_PORT" > "$OUTPUT_FILE"; then
    echo "Error: Failed to connect to the server."
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# Check that a response was received.
if [ ! -s "$OUTPUT_FILE" ]; then
    echo "Error: Received an empty response."
    rm -f "$OUTPUT_FILE"
    exit 1
fi

echo "Response received."

# Validate the JSON response.
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo "Error: Server returned invalid JSON."
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# Check whether the server returned an error.
if jq -e '.error' "$OUTPUT_FILE" >/dev/null 2>&1; then
    echo "Server error: $(jq -r '.error' "$OUTPUT_FILE")"
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# Display successful results.
echo
echo "POI search successful!"
echo "POI: $(jq -r '.poi' "$OUTPUT_FILE")"
echo "Distance: $(jq -r '.distance' "$OUTPUT_FILE") metres"
echo "Nearby POIs: $(jq '.neighbours | length' "$OUTPUT_FILE")"
echo "JSON saved to: $OUTPUT_FILE"
