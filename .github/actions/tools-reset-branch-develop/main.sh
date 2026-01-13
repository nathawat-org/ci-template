#!/bin/bash

# ============ CONFIG ============
for f in ${GITHUB_ACTION_PATH}/../utils/*.sh; do source "$f"; done

check_and_install_tool "jq"

# Configuration
ORG_NAME="nathawat-org" 
API_URL="https://api.github.com"
EXCLUDE_FILE="$GITHUB_ACTION_PATH/exclude_list.txt"
SLEEP_DURATION=1      
SAFETY_DELAY=3        

# ---------------------------------------------------------
# Step 0: Load Exclusion List from File
# ---------------------------------------------------------
EXCLUDED_REPOS=()
if [ -f "$EXCLUDE_FILE" ]; then
    show_logs "INFO" "Loading exclusion list from '$EXCLUDE_FILE'..."
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | xargs)
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            EXCLUDED_REPOS+=("$line")
        fi
    done < "$EXCLUDE_FILE"
    show_logs "INFO" "Loaded ${#EXCLUDED_REPOS[@]} repositories to exclude."
else
    show_logs "WARN" "Exclusion file not found."
fi

# ---------------------------------------------------------
# Safety Checks & Setup Temp Files
# ---------------------------------------------------------
if [ -z "$TOKEN_GITHUB_PURGE_BRANCH" ]; then
  show_logs "ERROR" "TOKEN_GITHUB_PURGE_BRANCH is not set."
  exit 1
fi

# Create Temp Files for capturing Headers/Body separately
TMP_HEADERS=$(mktemp)
TMP_BODY=$(mktemp)

# Ensure temp files are deleted when script exits (Success or Error)
trap 'rm -f "$TMP_HEADERS" "$TMP_BODY"' EXIT

# ---------------------------------------------------------
# Step 1: Get all repos list (ARRAY METHOD)
# ---------------------------------------------------------
page=1
repos=()

show_logs "INFO" "Fetching repository list..."

while :; do
    response=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
                   "$API_URL/orgs/$ORG_NAME/repos?per_page=100&page=$page")

    if echo "$response" | grep -q "Bad credentials"; then
        show_logs "ERROR" "Invalid GitHub Token."
        exit 1
    fi

    current_batch=$(echo "$response" | jq -r '.[].name')
    if [ -z "$current_batch" ] || [ "$current_batch" == "null" ]; then break; fi

    repos+=($current_batch)
    ((page++))
done

show_logs "INFO" "Found ${#repos[@]} repositories total."
show_logs "INFO" "------------------------------------------------"

# ---------------------------------------------------------
# Loop through Repos
# ---------------------------------------------------------

for repo in "${repos[@]}"; do
    
    # --- 1. CHECK EXCLUSION LIST ---
    skip_repo=false
    for excluded in "${EXCLUDED_REPOS[@]}"; do
        if [[ "$repo" == "$excluded" ]]; then
            skip_repo=true
            break
        fi
    done

    if [ "$skip_repo" = true ]; then
        show_logs "WARN" "Processing: $repo [SKIPPED - Excluded]"
        echo "------------------------------------------------"
        continue
    fi

    # --- 2. GET 'develop' SHA (AND CAPTURE RATE LIMIT) ---
    # We use -D to dump headers to $TMP_HEADERS and output body to $TMP_BODY
    curl -s -D "$TMP_HEADERS" \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/develop" > "$TMP_BODY"

    # Extract Rate Limit from Headers (Case insensitive grep)
    rate_limit=$(grep -i "x-ratelimit-remaining" "$TMP_HEADERS" | awk '{print $2}' | tr -d '\r')
    
    show_logs "INFO" "Processing: $repo [Quota Left: $rate_limit]"

    # Parse Body for SHA
    develop_sha=$(jq -r '.object.sha' "$TMP_BODY")

    if [ "$develop_sha" == "null" ] || [ -z "$develop_sha" ]; then
        show_logs "WARN" "    ! SKIP: Repo does not have a 'develop' branch."
        echo "------------------------------------------------"
        continue
    fi

    # --- 3. GET 'master' OR 'main' SHA ---
    source_branch="master"
    master_sha=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/master" | jq -r '.object.sha')

    if [ "$master_sha" == "null" ] || [ -z "$master_sha" ]; then
        source_branch="main"
        master_sha=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
            "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/main" | jq -r '.object.sha')
    fi

    if [ "$master_sha" == "null" ] || [ -z "$master_sha" ]; then
        show_logs "WARN" "    ! SKIP: Could not find 'master' OR 'main'."
        continue
    fi

    # --- 4. COMPARE SHAs ---
    if [ "$develop_sha" == "$master_sha" ]; then
        show_logs "INFO" "    > 'develop' is already identical to '$source_branch'."
        echo "------------------------------------------------"
        continue
    fi
    
    show_logs "INFO" "    > DETECTED DRIFT: 'develop' != '$source_branch'"

    # --- 5. DELETE 'develop' ---
    show_logs "INFO" "    > Deleting old 'develop'..."
    delete_response=$(curl -s -X DELETE \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/develop")

    if echo "$delete_response" | grep -q "message"; then
        if ! echo "$delete_response" | grep -q "Reference does not exist"; then
             show_logs "WARN" "      ! WARNING: Delete failed: $(echo $delete_response | jq -r .message)"
        fi
    fi

    # SAFETY PAUSE
    show_logs "INFO" "      ... Waiting ${SAFETY_DELAY}s for deletion to propagate ..."
    sleep $SAFETY_DELAY

    # --- 6. CREATE 'develop' ---
    show_logs "INFO" "    > Recreating 'develop' from '$source_branch'..."
    create_response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"ref\": \"refs/heads/develop\", \"sha\": \"$master_sha\"}" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs")

    if echo "$create_response" | jq -r .ref | grep -q "develop"; then
        show_logs "INFO" "      Success: 'develop' reset complete."
    else
        show_logs "ERROR" "      ! ERROR: Failed to create 'develop'."
        show_logs "ERROR" "      API Response: $create_response"
    fi

    echo "------------------------------------------------"
    sleep $SLEEP_DURATION
done

show_logs "INFO" "--- BATCH PROCESS COMPLETE ---"
