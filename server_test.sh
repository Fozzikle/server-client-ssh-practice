#!/bin/bash
set -o pipefail

ASSIGNMENT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
POPULATION_URL="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
POI_URL="https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0/query"

# Shared plotting script (read-only while requests are processed).
PLOT_SCRIPT="/tmp/plot_population.py"

get_ip() {
    ifconfig 2>/dev/null |
    grep -E 'inet (addr:)?[0-9]' |
    grep -v '127.0.0.1' |
    head -n 1 |
    awk '{
        sub(/addr:/, "", $2)
        print $2
    }'
}

get_port() {

    local port="${1:-1234}"

    # Validate the port number.
    if ! [[ "$port" =~ ^[0-9]+$ ]] ||
       (( port < 1 || port > 65535 )); then
        echo "Error: Invalid port number." >&2
        return 1
    fi

    # Check whether the port is already occupied.
    if ss -ltnH | awk -v port="$port" '
        {
            address = $4
            if (address ~ (":" port "$"))
                found = 1
        }
        END { exit !found }
    '; then
        echo "Error: Port $port is already in use." >&2
        return 1
    fi

    echo "$port"
}


handle_client() {

    local client_ip="$SOCAT_PEERADDR"
    local lock_dir="/tmp/active_clients"
    local lock_file
    local request_dir
    local request

    # Create the directory used to track active client IPs.
    mkdir -p "$lock_dir"

    # Create a unique lock filename for this client's IP.
    lock_file="$lock_dir/${client_ip//[^a-zA-Z0-9._-]/_}.lock"

    # Reject another simultaneous request from the same IP.
    if ! mkdir "$lock_file" 2>/dev/null; then
        printf 'ERROR: Another request from your IP is already being processed.\n'
        return 1
    fi

    # Create a unique temporary directory for this connection.
    request_dir=$(mktemp -d /tmp/server_request.XXXXXX)

    if [ -z "$request_dir" ]; then
        printf 'ERROR: Could not create temporary directory.\n'
        rmdir "$lock_file" 2>/dev/null
        return 1
    fi

    # Assign temporary files to this connection.
    local PAGE_FILE="$request_dir/assignment_page.txt"
    local JSON_FILE="$request_dir/assignment.json"
    local POPULATION_FILE="$request_dir/nsw_population.csv"
    local POPULATION_DATA="$request_dir/population_data.txt"
    local PLOT_FILE="$request_dir/population.png"

    local POI_NAMES_FILE="$request_dir/poi_names.json"
    local POI_LOOKUP_FILE="$request_dir/poi_lookup.json"
    local POI_RESULTS_FILE="$request_dir/poi_results.json"
    local POI_RESPONSE_FILE="$request_dir/poi_response.json"

    # Release the lock and remove temporary files when finished.
    trap "rm -rf '$request_dir'; rmdir '$lock_file' 2>/dev/null" EXIT

    # Preserve the socket output on file descriptor 3.
    exec 3>&1

    # Send server diagnostics to standard error instead of the client.
    exec 1>&2

    # Read the client's request.
    if ! IFS= read -r -t 30 request; then
        printf 'ERROR: Failed to receive client request.\n' >&3
        return 1
    fi

    # Remove a possible carriage return.
    request=${request%$'\r'}

    echo "Connection received from $client_ip" >&2

    if [ "$request" = "assignment" ]; then

        # Download webpage and convert HTML to text.
        if ! curl -fsSL "$ASSIGNMENT_URL" | html2text > "$PAGE_FILE"; then
            echo "Error: Failed to download or convert webpage."
            printf 'Error: Failed to retrieve assignment information.\n' >&3
            return 1
        fi

        if [ ! -s "$PAGE_FILE" ]; then
            echo "Error: Downloaded webpage is empty."
            printf 'Error: Downloaded webpage is empty.\n' >&3
            return 1
        fi

        rm -f "$JSON_FILE"

        if ! awk -v json_file="$JSON_FILE" '

            function trim(s) {
                sub(/^[ \t]+/, "", s)
                sub(/[ \t]+$/, "", s)
                return s
            }

            function parse_date(s, n, a, i, time_parts) {

                n = split(s, a, /[ \t]+/)

                if (need_minute) {
                    for (i = 1; i <= n; i++) {
                        if (a[i] ~ /^[0-9][0-9]?$/) {
                            minute = a[i]
                            need_minute = 0
                            return
                        }
                    }
                    return
                }

                if (day == "") {
                    for (i = 1; i <= n; i++) {
                        if (a[i] ~ /^[0-9][0-9]?$/) {
                            day = a[i]
                            break
                        }
                    }
                }

                for (i = 1; i <= n; i++) {

                    if (a[i] ~ /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/) {
                        month = a[i]
                    }

                    else if (month != "" && a[i] ~ /^[0-9][0-9][0-9][0-9]$/) {
                        year = a[i]
                    }

                    if (a[i] == "at") {
                        after_at = 1
                    }

                    else if (after_at && hour == "") {

                        if (a[i] ~ /^[0-9][0-9]?:$/) {
                            sub(/:$/, "", a[i])
                            hour = a[i]
                            need_minute = 1
                            return
                        }

                        else if (a[i] ~ /^[0-9][0-9]?:[0-9][0-9]$/) {
                            split(a[i], time_parts, ":")
                            hour = time_parts[1]
                            minute = time_parts[2]
                        }
                    }
                }
            }

            {
                line = $0

                if (!found && line ~ /Assignment 2/)
                    found = 1

                if (found) {

                    if (line ~ /^Outcomes assessed:/) {
                        finished = 1
                        next
                    }

                    if (finished)
                        next

                    print line

                    if (line ~ /Programming task/) {
                        topic = "Programming task"
                        in_topic = 1
                    }

                    else if (in_topic && line ~ /^[ \t]+Networking[ \t]+59/) {
                        topic = topic " Networking"
                    }

                    else if (in_topic && line ~ /^[ \t]+Concepts[ \t]+Closing date:/) {
                        topic = topic " Concepts"
                        in_topic = 0
                    }

                    if (match(line, /[0-9]+%/)) {
                        points = substr(line, RSTART, RLENGTH)
                        sub(/%$/, "", points)
                    }

                    if (line ~ /Due date:/) {
                        in_date = 1
                        sub(/^.*Due date:[ \t]*/, "", line)
                        parse_date(line)
                    }

                    else if (in_date) {
                        if (line ~ /Closing date:/) {
                            in_date = 0
                        }
                        else {
                            parse_date(line)
                        }
                    }
                }
            }

            END {

                if (!found || topic == "" || points == "" ||
                    day == "" || month == "" || year == "" ||
                    hour == "" || minute == "") {

                    print "Error: Could not extract all assignment information." > "/dev/stderr"
                    exit 1
                }

                due_date = day " " month " " year " at " hour ":" minute

                printf "{\n" > json_file
                printf "  \"title\": \"Assignment 2\",\n" >> json_file
                printf "  \"topic\": \"%s\",\n", topic >> json_file
                printf "  \"due_date\": \"%s\",\n", due_date >> json_file
                printf "  \"points\": \"%s\"\n", points >> json_file
                printf "}\n" >> json_file

                close(json_file)
            }

        ' "$PAGE_FILE"; then

            echo "Error: Assignment extraction failed."
            printf 'Error: Assignment extraction failed.\n' >&3
            return 1
        fi

        if [ ! -s "$JSON_FILE" ]; then
            echo "Error: Assignment JSON was not created."
            printf 'Error: Assignment JSON was not created.\n' >&3
            return 1
        fi

        if cat "$JSON_FILE" >&3; then
            echo "JSON sent successfully."
        else
            echo "Error: Failed to send JSON."
        fi

    elif [ "$request" = "population" ]; then

        echo "Downloading NSW population data..."

        if ! curl -fsSL "$POPULATION_URL" -o "$POPULATION_FILE"; then
            echo "Error: Failed to download population data."
            printf 'Error: Failed to download population data.\n' >&3

        elif [ ! -s "$POPULATION_FILE" ]; then
            echo "Error: Population CSV is empty."
            printf 'Error: Population CSV is empty.\n' >&3

        else

            echo "Extracting NSW population data..."

            : > "$POPULATION_DATA"

            declare -a headers=()
            declare -a fields=()
            declare -a year_indices=()
            declare -a years=()

            IFS=, read -r -a headers < "$POPULATION_FILE"

            for ((i=0; i<${#headers[@]}; i++)); do
                header=${headers[i]//$'\r'/}

                if [[ "$header" =~ ^[0-9]{4}$ ]]; then
                    year_indices+=("$i")
                    years+=("$header")
                fi
            done

            found=0
            latest_population=""

            while IFS=, read -r -a fields; do

                measure=${fields[0]//$'\r'/}

                if [ "$measure" = "ERP_P_20" ]; then

                    found=1

                    for ((i=0; i<${#year_indices[@]}; i++)); do

                        index=${year_indices[i]}
                        year=${years[i]}
                        value=${fields[index]//$'\r'/}

                        case "$value" in
                            ''|*[!0-9]*)
                                continue
                                ;;
                        esac

                        printf '%s %s\n' "$year" "$value" >> "$POPULATION_DATA"

                        if [ "$year" = "2025" ]; then
                            latest_population="$value"
                        fi

                    done

                    break
                fi

            done < <(tail -n +2 "$POPULATION_FILE")

            if [ "$found" -ne 1 ] || [ -z "$latest_population" ]; then

                echo "Error: Could not extract NSW population data."
                printf 'Error: Could not extract NSW population data.\n' >&3

            elif [ ! -s "$POPULATION_DATA" ]; then

                echo "Error: No valid population data was extracted."
                printf 'Error: No valid population data was extracted.\n' >&3

            else

                echo "NSW population in 2025: $latest_population"
                echo "Generating population plot..."

                if ! command -v python3 >/dev/null 2>&1; then

                    echo "Error: Python 3 is not installed."
                    printf 'Error: Python 3 is not installed.\n' >&3

                elif ! python3 -c "import matplotlib" 2>/dev/null; then

                    echo "Error: Matplotlib is not installed."
                    printf 'Error: Matplotlib is not installed.\n' >&3

                elif ! python3 "$PLOT_SCRIPT" "$POPULATION_DATA" "$PLOT_FILE"; then

                    echo "Error: Failed to generate population plot."
                    printf 'Error: Failed to generate population plot.\n' >&3

                elif [ ! -s "$PLOT_FILE" ]; then

                    echo "Error: Population plot was not created."
                    printf 'Error: Population plot was not created.\n' >&3

                else

                    echo "Population plot generated successfully."
                    echo "Sending population data and plot to client..."

                    printf 'NSW_POPULATION=%s\n' "$latest_population" >&3

                    if cat "$PLOT_FILE" >&3; then
                        echo "Population plot sent successfully."
                    else
                        echo "Error: Failed to send population plot."
                    fi

                fi
            fi
        fi

    elif [[ "$request" == poi\ * ]]; then

        echo "Received POI request: $request"

        process_poi_request "$request" || true

        if [ -s "$POI_RESPONSE_FILE" ]; then

            if cat "$POI_RESPONSE_FILE" >&3; then
                echo "POI JSON response sent successfully."
            else
                echo "Error: Failed to send POI JSON response."
            fi

        else
            echo "Error: POI response file was not created."
            printf '{"error":"Failed to create POI response."}\n' >&3
        fi

    elif [ -z "$request" ]; then

        echo "Error: Empty request received."
        printf 'Error: Empty request received.\n' >&3

    else

        echo "Error: Invalid request '$request'."
        printf 'Error: Invalid request.\n' >&3

    fi
}

IP=$(get_ip)

if [ -z "$IP" ]; then
    echo "Error: Could not determine server IP address."
    exit 1
fi

PORT=$(get_port "$IP")
PORT=1234

if [ -z "$PORT" ]; then
    echo "Error: Could not determine listening port."
    exit 1
fi


# Create Python plotting script.
# Only create the plotting script when starting the server.
if [ "${1:-}" != "--handle" ]; then

    # Create Python plotting script.
    cat > "$PLOT_SCRIPT" <<'PY'
import sys
import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt

# AI acknowledgement:
# This plotting script was generated with assistance from
# ChatGPT (GPT-6). It reads the year/population data extracted
# by the Bash server and generates a line plot.

data_file = sys.argv[1]
output_file = sys.argv[2]

years = []
populations = []

try:
    with open(data_file, "r") as file:
        for line in file:
            year, population = line.strip().split()
            years.append(int(year))
            populations.append(int(population))

    if not years:
        raise ValueError("No population data available.")

    plt.figure(figsize=(10, 6))
    plt.plot(years, populations, marker="o")

    plt.title("Estimated Resident Population of NSW")
    plt.xlabel("Year")
    plt.ylabel("Population")

    plt.grid(True)
    plt.xticks(years, rotation=45)
    plt.tight_layout()

    plt.savefig(output_file)
    plt.close()

except Exception as error:
    print("Plotting error:", error, file=sys.stderr)
    sys.exit(1)
PY
fi


# Find the coordinates of a POI using its name.
lookup_poi_coordinates() {

    local poi_name="$1"
    local search_name
    local escaped_name
    local where_clause

    search_name=${poi_name^^}

    # Escape apostrophes for the SQL query.
    escaped_name=$(printf '%s' "$search_name" | sed "s/'/''/g")

    where_clause="poiname LIKE '%${escaped_name}%'"

    echo "Looking up POI: $poi_name"

    if ! curl -fsSG "$POI_URL" \
        -o "$POI_LOOKUP_FILE" \
        --data-urlencode "where=$where_clause" \
        --data-urlencode "outFields=poiname" \
        --data-urlencode "returnGeometry=true" \
        --data-urlencode "f=pjson"; then

        echo "Error: Failed to contact the NSW POI API."
        return 1
    fi

    # Check for an API error.
    if jq -e '.error' "$POI_LOOKUP_FILE" >/dev/null 2>&1; then
        echo "Error: The POI API returned an error."
        return 1
    fi

    # Select an exact name match, ignoring capitalisation.
    latitude=$(jq -r --arg name "$search_name" '
        [.features[] |
        select((.attributes.poiname // "" | ascii_upcase) == $name)][0]
        .geometry.y // empty
    ' "$POI_LOOKUP_FILE")

    longitude=$(jq -r --arg name "$search_name" '
        [.features[] |
        select((.attributes.poiname // "" | ascii_upcase) == $name)][0]
        .geometry.x // empty
    ' "$POI_LOOKUP_FILE")

    if [ -z "$latitude" ] || [ -z "$longitude" ]; then
        echo "Error: Could not find an exact matching POI."
        return 1
    fi

    echo "POI coordinates found: $latitude, $longitude"

    return 0
}


# Retrieve nearby POIs and construct the final JSON response.
get_nearby_pois() {

    local poi_name="$1"
    local latitude="$2"
    local longitude="$3"
    local distance="$4"

    local where_clause
    local escaped_name
    local geometry

    # Exclude the original POI when the request uses a name.
    if [ "$poi_name" != "Coordinates" ]; then

        escaped_name=$(printf '%s' "${poi_name^^}" | sed "s/'/''/g")

        where_clause="poiname IS NOT NULL AND poiname <> '$escaped_name'"

    else
        where_clause="poiname IS NOT NULL"
    fi

    # Construct the point geometry.
    geometry=$(jq -cn \
        --argjson lon "$longitude" \
        --argjson lat "$latitude" \
        '{x: $lon, y: $lat, spatialReference: {wkid: 4283}}')

    echo "Searching within $distance metres..."

    # Query the NSW POI API using the supplied coordinates and distance.
    if ! curl -fsSG "$POI_URL" \
        -o "$POI_RESULTS_FILE" \
        --data-urlencode "where=$where_clause" \
        --data-urlencode "geometry=$geometry" \
        --data-urlencode "geometryType=esriGeometryPoint" \
        --data-urlencode "inSR=4283" \
        --data-urlencode "spatialRel=esriSpatialRelIntersects" \
        --data-urlencode "distance=$distance" \
        --data-urlencode "units=esriSRUnit_Meter" \
        --data-urlencode "outFields=poiname" \
        --data-urlencode "returnGeometry=false" \
        --data-urlencode "f=pjson"; then

        echo "Error: Failed to retrieve nearby POIs."
        return 1
    fi

    # Check for API errors or an invalid response.
    if ! jq -e '.features | type == "array"' "$POI_RESULTS_FILE" >/dev/null 2>&1; then
        echo "Error: Invalid response received from the POI API."
        return 1
    fi

    if jq -e '.error' "$POI_RESULTS_FILE" >/dev/null 2>&1; then
        echo "Error: The POI API returned an error."
        return 1
    fi

    # Extract names, remove null values and duplicates.
    if ! jq --arg original "${poi_name^^}" '
        [.features[].attributes.poiname |
        select(. != null and . != "" and
        (ascii_upcase != $original))]
        | unique
    ' "$POI_RESULTS_FILE" > "$POI_NAMES_FILE"; then

        echo "Error: Failed to extract nearby POI names."
        return 1
    fi

    # Construct the final JSON response.
    if ! jq -n \
        --arg poi "$poi_name" \
        --argjson latitude "$latitude" \
        --argjson longitude "$longitude" \
        --argjson distance "$distance" \
        --slurpfile neighbours "$POI_NAMES_FILE" \
        '{
            poi: $poi,
            coordinates: {
                latitude: $latitude,
                longitude: $longitude
            },
            distance: $distance,
            neighbours: $neighbours[0]
        }' > "$POI_RESPONSE_FILE"; then

        echo "Error: Failed to construct POI JSON response."
        return 1
    fi

    echo "Found $(jq '.neighbours | length' "$POI_RESPONSE_FILE") nearby POIs."

    return 0
}
# Process POI requests.
process_poi_request() {

    local request="$1"
    local poi_name=""
    local latitude=""
    local longitude=""
    local distance=""
    local sql_name=""
    local geometry=""
    local where_clause=""
    local lookup_count=""

    # Clear any response from a previous request.
    rm -f "$POI_RESPONSE_FILE"

    # Identify whether the request uses a POI name or coordinates.
    if [[ "$request" =~ ^poi[[:space:]]+name=\"([^\"]+)\"[[:space:]]+distance=([0-9]+)$ ]]; then

        poi_name="${BASH_REMATCH[1]}"
        distance="${BASH_REMATCH[2]}"

        echo "POI search by name: $poi_name"

        # Convert the name to uppercase, matching the API's stored names.
        # Escape apostrophes for the ArcGIS SQL query.
        sql_name="${poi_name^^}"
        sql_name="${sql_name//\'/\'\'}"

        # Look up the POI and retrieve its coordinates.
        if ! curl -fsSG "$POI_URL" \
            --data-urlencode "where=poiname LIKE '%$sql_name%'" \
            --data-urlencode "outFields=poiname" \
            --data-urlencode "returnGeometry=true" \
            --data-urlencode "outSR=4283" \
            --data-urlencode "f=json" \
            -o "$POI_LOOKUP_FILE"; then

            echo "Error: Failed to connect to the NSW POI API."
            jq -n '{error: "Failed to connect to the NSW POI API."}' > "$POI_RESPONSE_FILE"
            return 1
        fi

        # Check whether the API returned a valid response.
        if ! jq -e 'has("error") == false and (.features | type == "array")' \
            "$POI_LOOKUP_FILE" >/dev/null 2>&1; then

            echo "Error: Invalid response from POI API."
            jq -n '{error: "Invalid response from POI API."}' > "$POI_RESPONSE_FILE"
            return 1
        fi

        lookup_count=$(jq '.features | length' "$POI_LOOKUP_FILE")

        if [ "$lookup_count" -eq 0 ]; then
            echo "Error: POI not found."
            jq -n --arg name "$poi_name" \
                '{error: ("POI not found: " + $name)}' > "$POI_RESPONSE_FILE"
            return 1
        fi

        # Use the first matching POI.
        poi_name=$(jq -r '.features[0].attributes.poiname // empty' "$POI_LOOKUP_FILE")
        longitude=$(jq -r '.features[0].geometry.x // empty' "$POI_LOOKUP_FILE")
        latitude=$(jq -r '.features[0].geometry.y // empty' "$POI_LOOKUP_FILE")

        if [ -z "$latitude" ] || [ -z "$longitude" ] || [ -z "$poi_name" ]; then
            echo "Error: Could not retrieve POI coordinates."
            jq -n '{error: "Could not retrieve POI coordinates."}' > "$POI_RESPONSE_FILE"
            return 1
        fi

        # Exclude the original POI from the nearby results.
        sql_name="${poi_name//\'/\'\'}"
        where_clause="poiname IS NOT NULL AND poiname <> '$sql_name'"

    elif [[ "$request" =~ ^poi[[:space:]]+lat=(-?[0-9]+([.][0-9]+)?)[[:space:]]+lon=(-?[0-9]+([.][0-9]+)?)[[:space:]]+distance=([0-9]+)$ ]]; then

        latitude="${BASH_REMATCH[1]}"
        longitude="${BASH_REMATCH[3]}"
        distance="${BASH_REMATCH[5]}"

        poi_name="Coordinate search"

        echo "POI search by coordinates: $latitude, $longitude"

        # Coordinates must be within valid geographic ranges.
        if ! awk -v lat="$latitude" -v lon="$longitude" \
            'BEGIN { exit !(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) }'; then

            echo "Error: Invalid coordinates."
            jq -n '{error: "Latitude must be between -90 and 90 and longitude between -180 and 180."}' > "$POI_RESPONSE_FILE"
            return 1
        fi

        where_clause="poiname IS NOT NULL"

    else

        echo "Error: Invalid POI request format."
        jq -n '{error: "Invalid POI request format."}' > "$POI_RESPONSE_FILE"
        return 1

    fi

    # Validate that the requested distance is positive.
    if ! awk -v distance="$distance" \
        'BEGIN { exit !(distance > 0) }'; then

        echo "Error: Invalid search distance."
        jq -n '{error: "Search distance must be greater than zero."}' > "$POI_RESPONSE_FILE"
        return 1
    fi

    # Construct the geographic point used by the spatial query.
    geometry=$(printf \
        '{"x":%s,"y":%s,"spatialReference":{"wkid":4283}}' \
        "$longitude" "$latitude")

    echo "Searching within ${distance} metres..."

    # Retrieve neighbouring POIs from the NSW API.
    if ! curl -fsSG "$POI_URL" \
        --data-urlencode "where=$where_clause" \
        --data-urlencode "geometry=$geometry" \
        --data-urlencode "geometryType=esriGeometryPoint" \
        --data-urlencode "inSR=4283" \
        --data-urlencode "spatialRel=esriSpatialRelIntersects" \
        --data-urlencode "distance=$distance" \
        --data-urlencode "units=esriSRUnit_Meter" \
        --data-urlencode "outFields=poiname" \
        --data-urlencode "returnGeometry=false" \
        --data-urlencode "f=json" \
        -o "$POI_RESULTS_FILE"; then

        echo "Error: Failed to retrieve neighbouring POIs."
        jq -n '{error: "Failed to retrieve neighbouring POIs."}' > "$POI_RESPONSE_FILE"
        return 1
    fi

    # Validate the spatial query response.
    if ! jq -e 'has("error") == false and (.features | type == "array")' \
        "$POI_RESULTS_FILE" >/dev/null 2>&1; then

        echo "Error: Invalid response from POI API."
        jq -n '{error: "Invalid response from POI API."}' > "$POI_RESPONSE_FILE"
        return 1
    fi

    # Generate the final JSON response.
    if ! jq \
        --arg poi "$poi_name" \
        --argjson latitude "$latitude" \
        --argjson longitude "$longitude" \
        --argjson distance "$distance" \
        '{
            poi: $poi,
            coordinates: {
                latitude: $latitude,
                longitude: $longitude
            },
            distance: $distance,
            neighbours: (
                [
                    .features[]?.attributes.poiname
                    | select(type == "string" and length > 0 and . != $poi)
                ]
                | unique
            )
        }' "$POI_RESULTS_FILE" > "$POI_RESPONSE_FILE"; then

        echo "Error: Failed to generate POI JSON response."
        jq -n '{error: "Failed to generate POI JSON response."}' > "$POI_RESPONSE_FILE"
        return 1
    fi

    echo "POI search completed successfully."
    echo "Found $(jq '.neighbours | length' "$POI_RESPONSE_FILE") neighbouring POIs."

    return 0
}

if [ "${1:-}" = "--handle" ]; then
    handle_client
    exit $?
fi

IP=$(get_ip)

if [ -z "$IP" ]; then
    echo "Error: Could not determine server IP address."
    exit 1
fi
PORT=$(get_port)

if [ -z "$PORT" ]; then
    exit 1
fi

echo "The server is running at $IP, port=$PORT"

exec socat "TCP-LISTEN:${PORT},reuseaddr,fork" "EXEC:/bin/bash $0 --handle"
