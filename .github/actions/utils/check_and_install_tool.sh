#!/usr/bin/bash

check_and_install_tool() {
    for pkg in "$@"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            show_logs "INFO" "$pkg not found. Installing $pkg..."

            if command -v apk >/dev/null 2>&1; then
                apk add --no-cache --upgrade "$pkg"
            elif command -v apt-get >/dev/null 2>&1; then
                if [[ "$pkg" == "github-cli" ]]; then
                    pkg="gh"
                fi
                sudo apt-get update && sudo apt-get install -y "$pkg"
            else
                show_logs "ERROR" "Unsupported package manager. Please install the required tools manually."
            fi
        else
            show_logs "INFO" "$pkg is already installed."
        fi
    done
}
