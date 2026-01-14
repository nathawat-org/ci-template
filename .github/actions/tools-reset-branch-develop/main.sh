#!/bin/bash

# ============ CONFIG & SETUP ============
# 1. Load Utils
if [ -d "${GITHUB_ACTION_PATH}/../utils" ]; then
    for f in ${GITHUB_ACTION_PATH}/../utils/*.sh; do [ -e "$f" ] && . "$f"; done
fi

# 2. Load Backup Logic
if [ -f "${GITHUB_ACTION_PATH}/backup_branch.sh" ]; then
    . "${GITHUB_ACTION_PATH}/backup_branch.sh"
else
    echo "ERROR: backup_branch.sh not found!"
    exit 1
fi

# Configuration
ORG_NAME="nathawat-org" 
API_URL="https://api.github.com"
EXCLUDE_FILE="$GITHUB_ACTION_PATH/exclude_list.txt"
SLEEP_DURATION=1      
SAFETY_DELAY=3        

# Global Variables
BACKUP_NAME="$(date +%d-%m-%Y)"
EXCLUDED_REPOS=()
TMP_HEADERS=$(mktemp)
TMP_BODY=$(mktemp)

# ============ ERROR HANDLING & CLEANUP ============

cleanup() {
    rm -f "$TMP_HEADERS" "$TMP_BODY"
}
trap cleanup EXIT

throw() {
    show_logs "ERROR" "$1"
    return 1
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: 'jq' is not installed."
    exit 1
fi

# ============ LOCAL FUNCTIONS ============

load_exclusion_list() {
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
}

validate_token() {
    if [ -z "$TOKEN_GITHUB_PURGE_BRANCH" ]; then
        throw "TOKEN_GITHUB_PURGE_BRANCH is not set."
        exit 1
    fi
}

get_all_repos() {
    local page=1
    local repos=()
    show_logs "INFO" "Fetching repository list..." >&2
    while :; do
        response=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
                       "$API_URL/orgs/$ORG_NAME/repos?per_page=100&page=$page")
        if echo "$response" | grep -q "Bad credentials"; then
            throw "Invalid GitHub Token." >&2
            exit 1
        fi
        current_batch=$(echo "$response" | jq -r '.[].name')
        if [ -z "$current_batch" ] || [ "$current_batch" == "null" ]; then break; fi
        repos+=($current_batch)
        ((page++))
    done
    echo "${repos[@]}"
}

is_excluded() {
    local repo_name=$1
    for excluded in "${EXCLUDED_REPOS[@]}"; do
        if [[ "$repo_name" == "$excluded" ]]; then return 0; fi
    done
    return 1
}

get_branch_sha() {
    local repo=$1
    local branch=$2
    local capture_headers=$3 
    local url="$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/$branch"
    
    if [ "$capture_headers" == "true" ]; then
        curl -s -D "$TMP_HEADERS" -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" "$url" > "$TMP_BODY"
        jq -r '.object.sha' "$TMP_BODY"
    else
        curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" "$url" | jq -r '.object.sha'
    fi
}

get_rate_limit() {
    if [ -f "$TMP_HEADERS" ]; then
        grep -i "^x-ratelimit-remaining:" "$TMP_HEADERS" | awk '{print $2}' | tr -d '\r' || echo "N/A"
    else
        echo "N/A"
    fi
}

# --- UPDATED: Now acts as the Decision Maker ---
check_divergence_and_log() {
    local repo=$1
    local base=$2 # master/main
    local head=$3 # develop

    local url="$API_URL/repos/$ORG_NAME/$repo/compare/$base...$head"
    local response=$(curl -s -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" "$url")
    
    local status=$(echo "$response" | jq -r '.status')
    local ahead_by=$(echo "$response" | jq -r '.ahead_by')
    local behind_by=$(echo "$response" | jq -r '.behind_by')

    show_logs "INFO" "    > DIFF CHECK: Status='$status' (Ahead: $ahead_by, Behind: $behind_by)"

    # LOGIC: If identical, return 1 (Stop). Else return 0 (Proceed).
    if [ "$status" == "identical" ]; then
        return 1
    fi
    return 0
}

delete_branch() {
    local repo=$1
    local branch=$2
    show_logs "INFO" "    > Deleting '$branch'..."
    local response=$(curl -s -X DELETE \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs/heads/$branch")
    if echo "$response" | grep -q "message"; then
        if ! echo "$response" | grep -q "Reference does not exist"; then
             local msg=$(echo "$response" | jq -r .message)
             show_logs "WARN" "      ! WARNING: Delete failed: $msg"
             return 1
        fi
    fi
    return 0
}

create_branch() {
    local repo=$1
    local branch=$2
    local sha=$3
    show_logs "INFO" "    > Resetting '$branch' to match SHA ${sha:0:7}..."
    local response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB_PURGE_BRANCH" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"ref\": \"refs/heads/$branch\", \"sha\": \"$sha\"}" \
        "$API_URL/repos/$ORG_NAME/$repo/git/refs")
    if echo "$response" | jq -r .ref | grep -q "$branch"; then
        show_logs "INFO" "      Success: '$branch' reset complete."
        return 0
    else
        show_logs "ERROR" "      ! ERROR: Failed to create '$branch'."
        show_logs "ERROR" "      API Response: $response"
        return 1
    fi
}

# ============ MAIN CONTROLLER ============

process_repo() {
    local repo=$1
    local current_idx=$2
    local total_count=$3

    # DEBUG: Confirm function entry
    show_logs "DEBUG" "Starting $repo ($current_idx/$total_count)"

    # 1. Check Exclusion (Wrapped in if to handle return 1 gracefully)
    if is_excluded "$repo"; then
        show_logs "WARN" "Processing: $repo ($current_idx/$total_count) [SKIPPED - Excluded]"
        echo "------------------------------------------------"
        return 0
    fi

    # 2. Get Develop SHA
    local develop_sha
    develop_sha=$(get_branch_sha "$repo" "develop" "true")
    
    # 3. Get Rate Limit (Safe)
    local rate_limit
    rate_limit=$(get_rate_limit)

    show_logs "INFO" "Processing: $repo ($current_idx/$total_count) [Quota Left: $rate_limit]"

    # 4. Validation Checks
    if [ "$develop_sha" == "null" ] || [ -z "$develop_sha" ]; then
        show_logs "WARN" "    ! SKIP: Repo does not have a 'develop' branch."
        echo "------------------------------------------------"
        return 0
    fi

    local source_branch="master"
    local source_sha
    source_sha=$(get_branch_sha "$repo" "master" "false")

    if [ "$source_sha" == "null" ] || [ -z "$source_sha" ]; then
        source_branch="main"
        source_sha=$(get_branch_sha "$repo" "main" "false")
    fi

    if [ "$source_sha" == "null" ] || [ -z "$source_sha" ]; then
        show_logs "WARN" "    ! SKIP: Could not find 'master' OR 'main'."
        echo "------------------------------------------------"
        return 0
    fi

    # 5. Divergence Check
    if ! check_divergence_and_log "$repo" "$source_branch" "develop"; then
        show_logs "INFO" "    > Branches are identical. No action needed."
        echo "------------------------------------------------"
        return 0
    fi

    # 6. Execution
    backup_old_develop "$repo" "$develop_sha" || return
    delete_branch "$repo" "develop" || return
    
    show_logs "INFO" "      ... Waiting ${SAFETY_DELAY}s for consistency ..."
    sleep $SAFETY_DELAY
    
    create_branch "$repo" "develop" "$source_sha"
    
    echo "------------------------------------------------"
}

# ============ EXECUTION ============

validate_token
load_exclusion_list

repo_list_string=$(get_all_repos)
IFS=' ' read -r -a repo_array <<< "$repo_list_string"

# Get Total Count
total_repos=${#repo_array[@]}
current_count=0

show_logs "INFO" "Found $total_repos repositories total."
show_logs "INFO" "------------------------------------------------"

for repo in "${repo_array[@]}"; do
    # Increment counter
    # ((current_count++))
    
    # Pass repo, current_count, and total_repos to the function
    process_repo "$repo" "$current_count" "$total_repos"
    
    sleep $SLEEP_DURATION
done

show_logs "INFO" "--- BATCH PROCESS COMPLETE ---"
