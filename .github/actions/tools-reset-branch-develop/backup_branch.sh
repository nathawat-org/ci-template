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
    local short_sha=${sha:0:7}
    local full_backup_name="$BACKUP_NAME-$short_sha"
    local backup_ref="refs/heads/$full_backup_name"
    

    # Ensure show_logs exists, fallback to echo if running standalone
    if ! command -v show_logs &> /dev/null; then
        echo "INFO:    > Backing up 'develop' to '$full_backup_name'..."
    else
        show_logs "INFO" "    > Backing up 'develop' to '$full_backup_name'..."
    fi
    
    local response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"ref\": \"$backup_ref\", \"sha\": \"$sha\"}" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs")

    # Check Success
    if echo "$response" | jq -r .ref | grep -q "$full_backup_name"; then
        if command -v show_logs &> /dev/null; then
             show_logs "INFO" "      Success: Backup created."
        else
             echo "INFO:      Success: Backup created."
        fi
        return 0
    # Check if Backup Already Exists (Not an error, just skip)
    elif echo "$response" | grep -q "Reference already exists"; then
        if command -v show_logs &> /dev/null; then
             show_logs "WARN" "      ! WARNING: Backup branch '$full_backup_name' already exists. Skipping backup."
        else
             echo "WARN:      ! WARNING: Backup branch '$full_backup_name' already exists. Skipping backup."
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
