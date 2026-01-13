#!/bin/bash

# This script expects the following global variables to be set by main.sh:
# - API_URL
# - ORG_NAME
# - TOKEN_GITHUB_PURGE_BRANCH
# - BACKUP_NAME
# - TMP_HEADERS (for debugging, optional)

backup_old_develop() {
    local repo=$1
    local sha=$2 # The SHA of the *current* develop branch
    local backup_ref="refs/heads/$BACKUP_NAME"

    # Ensure show_logs exists, fallback to echo if running standalone
    if ! command -v show_logs &> /dev/null; then
        echo "INFO:    > Backing up 'develop' to '$BACKUP_NAME'..."
    else
        show_logs "INFO" "    > Backing up 'develop' to '$BACKUP_NAME'..."
    fi
    
    local response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"ref\": \"$backup_ref\", \"sha\": \"$sha\"}" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs")

    # Check Success
    if echo "$response" | jq -r .ref | grep -q "$BACKUP_NAME"; then
        if command -v show_logs &> /dev/null; then
             show_logs "INFO" "      Success: Backup created."
        else
             echo "INFO:      Success: Backup created."
        fi
        return 0
    # Check if Backup Already Exists (Not an error, just skip)
    elif echo "$response" | grep -q "Reference already exists"; then
        if command -v show_logs &> /dev/null; then
             show_logs "WARN" "      ! WARNING: Backup branch '$BACKUP_NAME' already exists. Skipping backup."
        else
             echo "WARN:      ! WARNING: Backup branch '$BACKUP_NAME' already exists. Skipping backup."
        fi
        return 0 
    # Handle Errors
    else
        if command -v show_logs &> /dev/null; then
             show_logs "ERROR" "      ! ERROR: Failed to create backup. Stopping to prevent data loss."
             show_logs "ERROR" "      API Response: $response"
        else
             echo "ERROR:      ! ERROR: Failed to create backup."
             echo "ERROR:      API Response: $response"
        fi
        return 1 # Return Failure (stops the reset process in main.sh)
    fi
}
