#!/bin/bash

# ============ CONFIG ============
for f in ${GITHUB_ACTION_PATH}/../utils/*.sh; do source "$f"; done

check_and_install_tool "jq"

# Configuration
ORG_NAME="myorder-intelligence" 
API_URL="https://api.github.com"
# Name of the file containing repos to skip
EXCLUDE_FILE="$GITHUB_ACTION_PATH/exclude_list.txt"

# ---------------------------------------------------------
# Step 0: Load Exclusion List from File
# ---------------------------------------------------------
EXCLUDED_REPOS=()

if [ -f "$EXCLUDE_FILE" ]; then
    show_logs "INFO" "Loading exclusion list from '$EXCLUDE_FILE'..."
    
    # Read file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim whitespace
        line=$(echo "$line" | xargs)
        
        # Skip empty lines and lines starting with #
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            EXCLUDED_REPOS+=("$line")
        fi
    done < "$EXCLUDE_FILE"
    
    show_logs "INFO" "Loaded ${#EXCLUDED_REPOS[@]} repositories to exclude."
else
    show_logs "WARN" "Exclusion file '$EXCLUDE_FILE' not found. No repos will be skipped."
fi

# ---------------------------------------------------------
# Safety Checks
# ---------------------------------------------------------

if [ -z "$TOKEN_GITHUB_PURGE_BRANCH" ]; then
  show_logs "ERROR" "TOKEN_GITHUB_PURGE_BRANCH is not set."
  exit 1
fi

# ---------------------------------------------------------
# Step 1: Get all repos list
# ---------------------------------------------------------
page=1
repos=""

show_logs "INFO" "Fetching repository list..."

while :; do
    response=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
                   "$API_URL/orgs/$ORG_NAME/repos?per_page=100&page=$page")

    if echo "$response" | grep -q "Bad credentials"; then
        show_logs "ERROR" "Invalid GitHub Token."
        exit 1
    fi

    current_batch=$(echo "$response" | jq -r '.[].name')

    if [ -z "$current_batch" ] || [ "$current_batch" == "null" ]; then
        break
    fi

    repos="$repos $current_batch"
    ((page++))
done

repo_list=($repos)
show_logs "INFO" "Found ${#repo_list[@]} repositories total."
show_logs "INFO" "------------------------------------------------"

# ---------------------------------------------------------
# Loop through Repos
# ---------------------------------------------------------

for repo in "${repo_list[@]}"; do
    show_logs "INFO" "Processing: $repo"

    # -----------------------------------------------------
    # CHECK EXCLUSION LIST (Loaded from .txt)
    # -----------------------------------------------------
    skip_repo=false
    for excluded in "${EXCLUDED_REPOS[@]}"; do
        if [[ "$repo" == "$excluded" ]]; then
            skip_repo=true
            break
        fi
    done

    if [ "$skip_repo" = true ]; then
        show_logs "WARN" "    ! SKIPPING: '$repo' is in the exclusion list."
        show_logs "INFO" "------------------------------------------------"
        continue
    fi

    # -----------------------------------------------------
    # Step 2: Delete branch 'develop'
    # -----------------------------------------------------
    show_logs "INFO" "    > Deleting 'develop'..."
    delete_response=$(curl -s -X DELETE \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/develop")

    if echo "$delete_response" | grep -q "Reference does not exist"; then
        show_logs "WARN" "      (Note: 'develop' did not exist, proceeding to create)"
    elif echo "$delete_response" | grep -q "message"; then
        show_logs "WARN" "      ! WARNING: Could not delete 'develop'. Message: $(echo $delete_response | jq -r .message)"
    else
        show_logs "INFO" "      Success: 'develop' deleted."
    fi

    # -----------------------------------------------------
    # Step 3: Create branch 'develop' from 'master' or 'main'
    # -----------------------------------------------------
    
    source_branch="master"
    master_sha=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/master" | jq -r '.object.sha')

    if [ "$master_sha" == "null" ] || [ -z "$master_sha" ]; then
        source_branch="main"
        master_sha=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
            "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/main" | jq -r '.object.sha')
    fi

    if [ "$master_sha" == "null" ] || [ -z "$master_sha" ]; then
        show_logs "WARN" "      ! SKIP: Could not find 'master' OR 'main'. Skipping."
        continue
    fi

    show_logs "INFO" "      > Retrieved '$source_branch' SHA: ${master_sha:0:7}"

    create_response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"ref\": \"refs/heads/develop\", \"sha\": \"$master_sha\"}" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs")

    if echo "$create_response" | jq -r .ref | grep -q "develop"; then
        show_logs "INFO" "      Success: 'develop' created/reset from '$source_branch'."
    else
        show_logs "ERROR" "      ! ERROR: Failed to create 'develop'."
        show_logs "ERROR" "      API Response: $create_response"
    fi

    show_logs "INFO" "------------------------------------------------"
done

show_logs "INFO" "--- BATCH PROCESS COMPLETE ---"
