#!/bin/bash
set -o pipefail

ASSIGNMENT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
POPULATION_URL="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"


# Temporary files stored inside the container
PAGE_FILE="/tmp/assignment_page.txt"
JSON_FILE="/tmp/assignment.json"
POPULATION_FILE="/tmp/nsw_population.csv"

POPULATION_DATA="/tmp/population_data.txt"
PLOT_FILE="/tmp/population.png"
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
    IP="$1"

    ss -ltn 2>/dev/null |
    awk -v ip="$IP" '
        NR > 1 && $1 == "LISTEN" {
            address = $4

            if (address ~ /^\*:/ ||
                address ~ /^0\.0\.0\.0:/ ||
                index(address, ip ":") == 1) {

                sub(/^.*:/, "", address)

                if (address ~ /^[0-9]+$/) {
                    print address
                    exit
                }
            }
        }
    '
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

echo "The server is running at $IP, port=$PORT"

while true; do

    # Start Netcat as a coprocess
    coproc NC { nc -l -p "$PORT" -v; }

    NC_OUT=${NC[0]}
    NC_IN=${NC[1]}

    # Read the client's request
    if ! IFS= read -r -t 30 -u "$NC_OUT" request; then
        echo "Error: Failed to receive client request."

        exec {NC_IN}>&-
        exec {NC_OUT}<&-
        wait "$NC_PID" 2>/dev/null
        continue
    fi

    # Remove a possible carriage return
    request=${request%$'\r'}

    if [ "$request" = "assignment" ]; then

        # Download webpage and convert HTML to text
        if ! curl -fsSL "$ASSIGNMENT_URL" | html2text > "$PAGE_FILE"; then
            echo "Error: Failed to download or convert webpage."
            printf 'Error: Failed to retrieve assignment information.\n' >&"$NC_IN" 2>/dev/null || true

            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        if [ ! -s "$PAGE_FILE" ]; then
            echo "Error: Downloaded webpage is empty."
            printf 'Error: Downloaded webpage is empty.\n' >&"$NC_IN" 2>/dev/null || true

            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        # Remove any JSON left over from a previous request
        rm -f "$JSON_FILE"

        if ! awk -v json_file="$JSON_FILE" '

            # Remove leading and trailing whitespace
            function trim(s) {
                sub(/^[ \t]+/, "", s)
                sub(/[ \t]+$/, "", s)
                return s
            }

            # Extract date, including when the time wraps across lines
            function parse_date(s, n, a, i, time_parts) {

                n = split(s, a, /[ \t]+/)

                # If the previous line ended with HH:,
                # the first number on this line is the minute
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

                # Extract the day
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

                            # Do not mistake the assignment duration
                            # on this line for the minute
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

                # Find Assignment 2
                if (!found && line ~ /Assignment 2/)
                    found = 1

                if (found) {

                    # Stop at the end of this assessment row
                    if (line ~ /^Outcomes assessed:/) {
                        finished = 1
                        next
                    }

                    if (finished)
                        next

                    # Display relevant webpage content in the terminal
                    print line

                    # Extract the task description
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

                    # Extract weighting
                    if (match(line, /[0-9]+%/)) {
                        points = substr(line, RSTART, RLENGTH)
                        sub(/%$/, "", points)
                    }

                    # Extract due date
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

                # Validate extracted information
                if (!found || topic == "" || points == "" ||
                    day == "" || month == "" || year == "" ||
                    hour == "" || minute == "") {

                    print "Error: Could not extract all assignment information." > "/dev/stderr"
                    exit 1
                }

                due_date = day " " month " " year " at " hour ":" minute

                # Generate JSON
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
            printf 'Error: Assignment extraction failed.\n' >&"$NC_IN" 2>/dev/null || true

            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        # Confirm JSON was created
        if [ ! -s "$JSON_FILE" ]; then
            echo "Error: Assignment JSON was not created."
            printf 'Error: Assignment JSON was not created.\n' >&"$NC_IN" 2>/dev/null || true

            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        if kill -0 "$NC_PID" 2>/dev/null; then
            echo "Netcat process is still running."
        else
            echo "ERROR: Netcat process has exited."
        fi

        if ! : >&"$NC_IN" 2>/dev/null; then
            echo "ERROR: Server input descriptor $NC_IN is closed."
        else
            echo "Server input descriptor is open."

            if cat "$JSON_FILE" >&"$NC_IN"; then
                echo "JSON sent successfully."
            else
                echo "Error: Failed to send JSON."
            fi
        fi

        # Close the server's input descriptor
        exec {NC_IN}>&-

    elif [ "$request" = "population" ]; then

        echo "Downloading NSW population data..."

        # Download CSV.
        if ! curl -fsSL "$POPULATION_URL" -o "$POPULATION_FILE"; then
            echo "Error: Failed to download population data."
            printf 'Error: Failed to download population data.\n' >&"$NC_IN" 2>/dev/null || true

        elif [ ! -s "$POPULATION_FILE" ]; then
            echo "Error: Population CSV is empty."
            printf 'Error: Population CSV is empty.\n' >&"$NC_IN" 2>/dev/null || true

        else

            echo "Extracting NSW population data..."

            # Extract years and population values using Bash.
            : > "$POPULATION_DATA"

            declare -a headers=()
            declare -a fields=()
            declare -a year_indices=()
            declare -a years=()

            # Read the CSV header.
            IFS=, read -r -a headers < "$POPULATION_FILE"

            # Find the columns containing years.
            for ((i=0; i<${#headers[@]}; i++)); do
                header=${headers[i]//$'\r'/}

                if [[ "$header" =~ ^[0-9]{4}$ ]]; then
                    year_indices+=("$i")
                    years+=("$header")
                fi
            done

            found=0
            latest_population=""

            # Find the estimated resident population row.
            while IFS=, read -r -a fields; do

                measure=${fields[0]//$'\r'/}

                if [ "$measure" = "ERP_P_20" ]; then

                    found=1

                    # Extract each year and its corresponding population.
                    for ((i=0; i<${#year_indices[@]}; i++)); do

                        index=${year_indices[i]}
                        year=${years[i]}
                        value=${fields[index]//$'\r'/}

                        # Accept only non-empty values containing digits.
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

            # Check that the expected data was found.
            if [ "$found" -ne 1 ] || [ -z "$latest_population" ]; then

                echo "Error: Could not extract NSW population data."
                printf 'Error: Could not extract NSW population data.\n' >&"$NC_IN" 2>/dev/null || true

            elif [ ! -s "$POPULATION_DATA" ]; then

                echo "Error: No valid population data was extracted."
                printf 'Error: No valid population data was extracted.\n' >&"$NC_IN" 2>/dev/null || true

            else

                echo "NSW population in 2025: $latest_population"

                echo "Generating population plot..."

                # Check Python and Matplotlib availability.
                if ! command -v python3 >/dev/null 2>&1; then

                    echo "Error: Python 3 is not installed."
                    printf 'Error: Python 3 is not installed.\n' >&"$NC_IN" 2>/dev/null || true

                elif ! python3 -c "import matplotlib" 2>/dev/null; then

                    echo "Error: Matplotlib is not installed."
                    printf 'Error: Matplotlib is not installed.\n' >&"$NC_IN" 2>/dev/null || true

                # Generate the PNG.
                elif ! python3 "$PLOT_SCRIPT" "$POPULATION_DATA" "$PLOT_FILE"; then

                    echo "Error: Failed to generate population plot."
                    printf 'Error: Failed to generate population plot.\n' >&"$NC_IN" 2>/dev/null || true

                elif [ ! -s "$PLOT_FILE" ]; then

                    echo "Error: Population plot was not created."
                    printf 'Error: Population plot was not created.\n' >&"$NC_IN" 2>/dev/null || true

                else

                    echo "Population plot generated successfully."
                    echo "Sending population data and plot to client..."

                    # Send the population value first.
                    printf 'NSW_POPULATION=%s\n' "$latest_population" >&"$NC_IN"

                    # Send the PNG as binary data.
                    if cat "$PLOT_FILE" >&"$NC_IN"; then
                        echo "Population plot sent successfully."
                    else
                        echo "Error: Failed to send population plot."
                    fi

                fi
            fi
        fi

        # Close the server's input descriptor.
        exec {NC_IN}>&-

    elif [ -z "$request" ]; then

        echo "Error: Empty request received."
        printf 'Error: Empty request received.\n' >&"$NC_IN" 2>/dev/null || true
        exec {NC_IN}>&-



    else

        echo "Error: Invalid request '$request'."
        printf 'Error: Invalid request.\n' >&"$NC_IN" 2>/dev/null || true
        exec {NC_IN}>&-

    fi


    # Close remaining descriptor and wait for Netcat
    exec {NC_OUT}<&-
    wait "$NC_PID" 2>/dev/null

done
