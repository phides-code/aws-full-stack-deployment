#!/bin/bash

#####################
# helper functions
set -Eeuo pipefail
IFS=$'\n\t'

on_err() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    echo "" >&2
    echo "ERROR: setup failed at line ${line_no} (exit ${exit_code})." >&2
    echo "Last command: ${BASH_COMMAND}" >&2
    exit "$exit_code"
}
trap on_err ERR

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_nonempty() {
    local label="$1"
    local value="$2"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        die "Expected non-empty value for: ${label}"
    fi
}

require_var() {
    local name="$1"
    local value="${!name:-}"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        die "Missing required variable: ${name} (prepended by setup script)"
    fi
}

gh_repo_create_with_retry() {
    # usage: gh_repo_create_with_retry <repo_name> <visibility> [source_path]
    local repo_name="$1"
    local visibility="$2"
    local source_path="${3:-.}"
    
    local owner
    owner="$(gh api user --jq .login)"
    require_nonempty "GitHub user login" "$owner"
    
    local full_repo="${owner}/${repo_name}"
    
    # If the repo already exists, treat as success and ensure origin exists.
    if gh repo view "$full_repo" >/dev/null 2>&1; then
        echo "GitHub repo already exists: ${full_repo}"
        if ! git remote get-url origin >/dev/null 2>&1; then
            git remote add origin "git@github.com:${full_repo}.git" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    
    local attempts=6
    local delay=2
    local i=1
    while [ "$i" -le "$attempts" ]; do
        # --confirm avoids any prompts in scripts/CI; gh sometimes returns transient API errors.
        if gh repo create "$repo_name" --source="$source_path" --"$visibility" --confirm; then
            return 0
        fi
        
        # If creation errored but the repo exists, continue (GitHub API can be flaky).
        if gh repo view "$full_repo" >/dev/null 2>&1; then
            echo "GitHub repo exists after create error; continuing: ${full_repo}"
            if ! git remote get-url origin >/dev/null 2>&1; then
                git remote add origin "git@github.com:${full_repo}.git" >/dev/null 2>&1 || true
            fi
            return 0
        fi
        
        echo "Retrying GitHub repo creation (${i}/${attempts})..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        i=$((i + 1))
    done
    
    die "Failed to create GitHub repository: ${full_repo}"
}

retry_nonempty() {
    # usage: retry_nonempty <attempts> <sleep_seconds> <command...>
    local attempts="$1"
    local sleep_seconds="$2"
    shift 2
    
    local out=""
    local i=1
    while [ "$i" -le "$attempts" ]; do
        # shellcheck disable=SC2091
        out="$("$@" 2>/dev/null || true)"
        if [ -n "$out" ] && [ "$out" != "null" ]; then
            printf '%s' "$out"
            return 0
        fi
        sleep "$sleep_seconds"
        i=$((i + 1))
    done
    
    return 1
}

get_api_gateway_id() {
    aws apigateway get-rest-apis --output json \
    | jq -r --arg service "$service_name" '.items[]? | select(.name == $service) | .id' \
    | head -n 1
}

get_gh_run_id_for_sha() {
    local sha="$1"
    gh run list --limit 30 --json databaseId,headSha \
    | jq -r --arg sha "$sha" '.[] | select(.headSha == $sha) | .databaseId' \
    | head -n 1
}

get_latest_gh_run_id() {
    gh run list --limit 1 --json databaseId \
    | jq -r '.[0].databaseId'
}

gh_watch_last_run_no_prompt() {
    # usage: gh_watch_last_run_no_prompt [commit_sha]
    local sha="${1:-}"
    local run_id=""
    
    # Prefer the run created for this exact commit, to avoid watching the wrong run.
    if [ -n "$sha" ]; then
        run_id="$(retry_nonempty 60 5 get_gh_run_id_for_sha "$sha" || true)"
    fi
    
    # Fallback to most recent run if we couldn't match by sha.
    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
        run_id="$(retry_nonempty 60 5 get_latest_gh_run_id || true)"
    fi
    
    require_nonempty "GitHub Actions run ID" "$run_id"
    env GH_PAGER="cat" gh run watch "$run_id" --exit-status
}

# --- Main ---

if [ "$#" -ne 1 ]; then
    echo "Usage: add-new-service.sh TABLE_NAME (singular, e.g. banana)"
    exit 1
fi

table_name="$1"
lowercase_table_name=$(echo "$table_name" | tr '[:upper:]' '[:lower:]')
camelcase_table_name=$(echo "$table_name" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' OFS='')

echo ""
echo "=== Add new service: $lowercase_table_name ==="
echo ""

echo "Checking prepended constants (project_name, IAM_ROLE_NAME, etc.)..."
require_var project_name
require_var lowercase_project_name
require_var camel_case_project_name
require_var AWS_REGION
require_var dist_domain
require_var distribution_id
echo "  All required variables present."
echo ""

echo "Checking required commands (aws, gh, git, npx, jq, etc.)..."
require_cmd aws
require_cmd gh
require_cmd git
require_cmd npx
require_cmd jq
require_cmd sed
require_cmd awk
require_cmd tr
require_cmd cut
require_cmd head
require_cmd md5sum
require_cmd mktemp
require_cmd find
echo "  All required commands found."
echo ""

# Prepended by setup.sh: project_name, lowercase_project_name, camel_case_project_name, AWS_REGION, dist_domain, distribution_id
# shellcheck disable=SC2154
service_name="${lowercase_project_name}-${lowercase_table_name}s-service"
# shellcheck disable=SC2154
echo "Project: $project_name  →  service repo: $service_name"
echo ""

echo "=== AWS credentials and region ==="
AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"
AWS_CONFIG_FILE="$HOME/.aws/config"

if [ ! -f "$AWS_CREDENTIALS_FILE" ]; then
    die "AWS credentials file not found: $AWS_CREDENTIALS_FILE"
fi
if [ ! -f "$AWS_CONFIG_FILE" ]; then
    die "AWS config file not found: $AWS_CONFIG_FILE"
fi

echo "Reading AWS credentials and region from config..."
# Extract aws_access_key_id
AWS_ACCESS_KEY_ID="$(grep -m 1 "aws_access_key_id" "$AWS_CREDENTIALS_FILE" | cut -d "=" -f 2 | tr -d '[:space:]' || true)"

# Extract aws_secret_access_key
AWS_SECRET_ACCESS_KEY="$(grep -m 1 "aws_secret_access_key" "$AWS_CREDENTIALS_FILE" | cut -d "=" -f 2 | tr -d '[:space:]' || true)"

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    die "Failed to extract AWS credentials from $AWS_CREDENTIALS_FILE"
fi

echo "  Region: $AWS_REGION (from prepended constants)"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
require_nonempty "AWS account ID" "$AWS_ACCOUNT_ID"
echo "  Account ID: $AWS_ACCOUNT_ID"
echo ""

echo "=== Backend service from template ==="
echo "Cloning backend template into: $service_name"
npx degit phides-code/go-dynamodb-service-template "$service_name"

cd "$service_name" || exit

echo "Replacing template placeholders (Appname, appname, region, table name, FRONTEND_URL)..."
# shellcheck disable=SC2154
find . -type f -exec sed -i "s|Appname|$camel_case_project_name|g" {} +
find . -type f -exec sed -i "s|appname|$lowercase_project_name|g" {} +
find . -type f -exec sed -i "s|us-east-1|$AWS_REGION|g" {} +
find . -type f -exec sed -i "s|banana|$lowercase_table_name|g" {} +
find . -type f -exec sed -i "s|Banana|$camelcase_table_name|g" {} +
find . -type f -exec sed -i "s|bananas|${lowercase_table_name}s|g" {} +
find . -type f -exec sed -i "s|Bananas|${camelcase_table_name}s|g" {} +
# shellcheck disable=SC2154
find . -maxdepth 1 -type f -exec sed -i "s|FRONTEND_URL|$dist_domain|g" {} +

echo "  Done."
echo ""

echo "=== GitHub repository ==="
visibility_options=("public" "private")
echo ""
PS3="Create this GitHub repo as Public (1) or Private (2)? "
select option in "${visibility_options[@]}"; do
    case $option in
        "public")
            selected_visibility="public"
            break
        ;;
        "private")
            selected_visibility="private"
            break
        ;;
        *)
            echo "Invalid option. Please select 1 (public) or 2 (private)."
        ;;
    esac
done

echo "Initializing git and creating repo ($selected_visibility)..."
git init
git branch -M main
gh_repo_create_with_retry "$service_name" "$selected_visibility" "."

echo "Generating AWS_CF_TOKEN and adding secrets to the repo..."
AWS_CF_TOKEN=$(head -c 64 /dev/urandom | md5sum | awk '{print $1}')
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
gh secret set AWS_CF_TOKEN --body "$AWS_CF_TOKEN"

echo "Pushing initial commit to main..."
git add .
git commit -m "initial commit"
git push origin main
echo ""

echo "=== GitHub Actions deployment ==="
echo "Waiting for workflow run (watching by commit SHA)..."
backend_sha="$(git rev-parse HEAD)"
gh_watch_last_run_no_prompt "$backend_sha"
echo "  Workflow completed."
echo ""

echo "=== API Gateway, CloudFront, and IAM policy ==="
echo "Resolving API Gateway ID for: $service_name"
api_gateway_id="$(retry_nonempty 30 10 get_api_gateway_id || true)"
require_nonempty "API Gateway ID (from API named: ${service_name})" "$api_gateway_id"
service_url_host="${api_gateway_id}.execute-api.${AWS_REGION}.amazonaws.com"
service_url="${dist_domain}/Prod/${lowercase_table_name}s"
echo "  API Gateway ID: $api_gateway_id"
echo "  Service URL (via CloudFront): $service_url"
echo ""

echo "Adding API origin and cache behavior to CloudFront distribution..."
export AWS_PAGER=""
cf_config=$(mktemp)
cf_updated=$(mktemp)
cf_fragment=$(mktemp)
trap 'rm -f "$cf_config" "$cf_updated" "$cf_fragment"' EXIT
# shellcheck disable=SC2154
aws cloudfront get-distribution-config --id "$distribution_id" --query 'DistributionConfig' > "$cf_config"
cf_etag=$(aws cloudfront get-distribution-config --id "$distribution_id" --query 'ETag' --output text)
require_nonempty "CloudFront distribution ETag" "$cf_etag"
cp ../api-origin-behavior.json "$cf_fragment"
sed -i "s|ORIGIN_ID|$service_url_host|g" "$cf_fragment"
sed -i "s|CF_TOKEN|$AWS_CF_TOKEN|g" "$cf_fragment"
sed -i "s|PATH_PATTERN|/Prod/${lowercase_table_name}s*|g" "$cf_fragment"
jq -s '.[1] as $frag | .[0] | .Origins.Quantity += 1 | .Origins.Items += [$frag.origin] | .CacheBehaviors.Quantity += ($frag.cacheBehaviors.Quantity) | .CacheBehaviors.Items += ($frag.cacheBehaviors.Items)' "$cf_config" "$cf_fragment" > "$cf_updated"
aws cloudfront update-distribution --id "$distribution_id" --distribution-config "file://${cf_updated}" --if-match "$cf_etag"
echo "  CloudFront distribution update initiated (API origin and /Prod/${lowercase_table_name}s behavior). Deployment may take 5–15 minutes."
echo ""

echo "Done. New service \"$lowercase_table_name\" is wired up."
