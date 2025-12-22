#!/usr/bin/bash

show_logs() {
    local TYPE=$1
    local MSG=$2

    if [ "$TYPE" == "INFO" ]; then
        echo -e "\033[1;38;5;33m[INFO]\033[0m \033[1;38;5;39m$MSG\033[0m"
    elif [ "$TYPE" == "ERROR" ]; then
        echo -e "\033[1;91m[ERROR]\033[0m \033[1;31m$MSG\033[0m"
    elif [ "$TYPE" == "DEBUG" ]; then
        echo -e "\033[1;38;5;135m[DEBUG] $MSG\033[0m"
    elif [ "$TYPE" == "WARN" ]; then
        echo -e "\033[1;38;5;214m[WARN] $MSG\033[0m"
    else
        echo "Unknown log type: $TYPE"
        echo "[$TYPE] $MSG"
    fi
}
