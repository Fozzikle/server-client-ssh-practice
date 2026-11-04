#!/bin/bash

ASSIGNMENT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"

# Temporary files stored inside the container
PAGE_FILE="/tmp/assignment_page.txt"
JSON_FILE="/tmp/assignment.json"


get_ip(){
    ifconfig 2>/dev/null |
    grep -E 'inet (addr:)?[0-9]' |
    # Ignore the localhost address
    grep -v '127\.0\.0\.1' |
    # Prioritise the top address
    head -n 1 |
    awk '{
        sub(/addr:/, "", $2)
        print $2
    }'
}


get_port(){
    IP=$(get_ip)

    ss -lnt 2>/dev/null |
    # Look for an IP match or a wildcard address
    awk -v ip="$IP" '
        $1 == "LISTEN" &&
        ($4 ~ /^\*:/ ||
         $4 ~ /^0\.0\.0\.0:/ ||
         index($4, ip ":") == 1) {
            n = split($4, a, ":")
            print a[n]
            exit
        }
    '
}


IP=$(get_ip)
PORT=$(get_port)

# Check that the required information was found
if [ -z "$IP" ]; then
    echo "Error: Could not determine server IP address."
    exit 1
fi

if [ -z "$PORT" ]; then
    echo "Error: Could not determine server port."
    exit 1
fi

# Landing message
echo "The server is running at $IP, port=$PORT"


while true; do

    # Start Netcat as a coprocess
    #   NC[0] = input received from the client
    #   NC[1] = output sent to the client
    coproc NC { nc -l -p "$PORT" -v; }

    NC_OUT=${NC[0]}
    NC_IN=${NC[1]}

    # Read the client's request
    if ! IFS= read -r -u "$NC_OUT" request; then
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

            printf 'Error: Failed to retrieve assignment information.\n' >&"$NC_IN"
            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        if [ ! -s "$PAGE_FILE" ]; then
            echo "Error: Downloaded webpage is empty."

            printf 'Error: Downloaded webpage is empty.\n' >&"$NC_IN"
            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        # Extract the assignment information and create JSON
        if ! awk -v json_file="$JSON_FILE" '

            # Remove leading and trailing whitespace
            function trim(s) {
                sub(/^[ \t]+/, "", s)
                sub(/[ \t]+$/, "", s)
                return s
            }

            # Extract the date, including when it wraps across lines
            function parse_date(s, n, a, i) {

                n = split(s, a, /[ \t]+/)

                # If the time ended in a colon, get its minutes
                # from the next line
                if (need_minute) {
                    for (i = 1; i <= n; i++) {
                        if (a[i] ~ /^[0-9][0-9]?$/) {
                            minute = a[i]
                            need_minute = 0
                            return
                        }
                    }
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

                    else if (year != "" && a[i] == "at") {
                        after_at = 1
                    }

                    else if (after_at && hour == "") {

                        if (a[i] ~ /^[0-9][0-9]?:[0-9][0-9]$/) {
                            split(a[i], time_parts, ":")
                            hour = time_parts[1]
                            minute = time_parts[2]
                        }

                        else if (a[i] ~ /^[0-9][0-9]?:$/) {
                            sub(/:$/, "", a[i])
                            hour = a[i]
                            need_minute = 1
                            return
                        }
                    }
                }
            }

            {
                lines[NR] = $0

                # Find the starting positions of the two columns
                if (index($0, "Assignment 2") > 0)
                    middle_start = index($0, "Assignment 2")

                if (index($0, "Due date:") > 0)
                    right_start = index($0, "Due date:")
            }

            END {

                if (middle_start == 0 || right_start == 0) {
                    print "Error: Could not locate assignment columns." > "/dev/stderr"
                    exit 1
                }

                print ""
                print "Assignment 2 information:"
                print "-------------------------"

                for (i = 1; i <= NR; i++) {

                    # Extract the middle column
                    middle = trim(substr(lines[i], middle_start, right_start - middle_start))

                    # Extract the right column
                    right = trim(substr(lines[i], right_start))

                    # Display only the Assignment 2 column
                    if (middle != "")
                        print middle

                    # Extract title
                    if (middle == "Assignment 2")
                        title = middle

                    # Extract topic and weighting
                    else if (index(middle, "Programming task") == 1) {

                        topic = middle

                        if (match(middle, /-[ \t]*[0-9]+%/)) {
                            points = substr(middle, RSTART, RLENGTH)
                            gsub(/[^0-9%]/, "", points)

                            sub(/[ \t]*-[ \t]*[0-9]+%.*/, "", topic)
                        }

                        in_topic = 1
                    }

                    # Append topic text from subsequent lines
                    else if (in_topic && middle != "") {
                        topic = topic " " middle

                        if (middle == "Concepts")
                            in_topic = 0
                    }

                    # Extract due date
                    if (index(right, "Due date:") == 1) {
                        in_date = 1
                        sub(/^Due date:[ \t]*/, "", right)
                        parse_date(right)
                    }

                    else if (in_date && index(right, "Closing date:") == 1) {
                        in_date = 0
                    }

                    else if (in_date) {
                        parse_date(right)
                    }
                }

                due_date = day " " month " " year " at " hour ":" minute

                # Validate extracted information
                if (title == "" || topic == "" || points == "" ||
                    day == "" || month == "" || year == "" ||
                    hour == "" || minute == "") {

                    print "Error: Could not extract all assignment information." > "/dev/stderr"
                    exit 1
                }

                # Save JSON file
                printf "{\n" > json_file
                printf "  \"title\": \"%s\",\n", title >> json_file
                printf "  \"topic\": \"%s\",\n", topic >> json_file
                printf "  \"due_date\": \"%s\",\n", due_date >> json_file
                printf "  \"points\": \"%s\"\n", points >> json_file
                printf "}\n" >> json_file

                close(json_file)
            }

        ' "$PAGE_FILE"; then

            echo "Error: Assignment extraction failed."

            printf 'Error: Assignment extraction failed.\n' >&"$NC_IN"
            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        if [ ! -s "$JSON_FILE" ]; then
            echo "Error: Assignment JSON was not created."

            printf 'Error: Assignment JSON was not created.\n' >&"$NC_IN"
            exec {NC_IN}>&-
            exec {NC_OUT}<&-
            wait "$NC_PID" 2>/dev/null
            continue
        fi

        # Send the JSON contents over the existing connection
        cat "$JSON_FILE" >&"$NC_IN"

        # Close the server's output side so the client receives EOF
        exec {NC_IN}>&-

    elif [ -z "$request" ]; then

        echo "Error: Empty request received."
        printf 'Error: Empty request received.\n' >&"$NC_IN"
        exec {NC_IN}>&-

    else

        echo "Error: Invalid request '$request'."
        printf 'Error: Invalid request.\n' >&"$NC_IN"
        exec {NC_IN}>&-

    fi

    # Close the remaining connection descriptor and wait for Netcat
    exec {NC_OUT}<&-
    wait "$NC_PID" 2>/dev/null

done