#!/usr/bin/env bash
# =============================================================================
# github_branch_audit.sh — GitHub Branch & Protection Rules Auditor
# =============================================================================
# Reads a list of GitHub repo URLs from repos.txt (or a custom file), then
# prints the default branch and all branch protection rules for each repo.
#
# Requirements: curl, jq
# Auth:         export GITHUB_TOKEN=ghp_yourtoken
# Usage:        ./github_branch_audit.sh [repos.txt]
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPOS_FILE="${1:-repos.txt}"
API_BASE="https://api.github.com"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Preflight checks ──────────────────────────────────────────────────────────
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo -e "${RED}Error:${RESET} GITHUB_TOKEN is not set."
  echo "  Run: export GITHUB_TOKEN=ghp_yourtoken"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}Error:${RESET} jq is required but not installed."
  echo "  Install: sudo apt install jq   OR   brew install jq"
  exit 1
fi

if [[ ! -f "$REPOS_FILE" ]]; then
  echo -e "${RED}Error:${RESET} Repos file not found: ${REPOS_FILE}"
  echo "  Create repos.txt with one GitHub URL per line, e.g.:"
  echo "    https://github.com/myorg/repo-one"
  echo "    https://github.com/myorg/repo-two"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Authenticated GitHub API call — returns raw JSON on stdout
# Usage: gh_api "/repos/owner/repo"
gh_api() {
  local endpoint="$1"
  curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_BASE}${endpoint}"
}

# Extract "owner/repo" from a full GitHub URL
# Handles trailing .git and any path depth
extract_owner_repo() {
  local url="${1%.git}"        # strip optional .git suffix
  echo "${url#*github.com/}"  # strip everything up to and including github.com/
}

separator() {
  echo -e "${DIM}$(printf '─%.0s' {1..72})${RESET}"
}

bool_icon() {
  # Prints ✓ (green) for true, ✗ (dim) for false
  [[ "$1" == "true" ]] && echo -e "${GREEN}✓${RESET}" || echo -e "${DIM}✗${RESET}"
}

# ── Count valid lines for the header ─────────────────────────────────────────
repo_count=$(grep -cE '^[^#[:space:]]' "$REPOS_FILE" || true)

# ── Header ────────────────────────────────────────────────────────────────────
separator
echo -e "  ${BOLD}GitHub Branch & Protection Rules Audit${RESET}"
echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')   File: ${REPOS_FILE}   Repos: ${repo_count}${RESET}"
separator

total=0; success=0; failed=0

# ── Main loop ─────────────────────────────────────────────────────────────────
while IFS= read -r url || [[ -n "${url:-}" ]]; do

  # Skip blank lines and comment lines
  [[ -z "${url// }" || "$url" == \#* ]] && continue
  ((total++))

  owner_repo=$(extract_owner_repo "$url")
  owner="${owner_repo%%/*}"
  repo="${owner_repo##*/}"

  echo ""
  echo -e "${BOLD}${CYAN}▶  ${owner} / ${repo}${RESET}"
  echo -e "   ${DIM}${url}${RESET}"

  # ── Repo info (default branch, visibility) ──────────────────────────────────
  if ! repo_json=$(gh_api "/repos/${owner_repo}" 2>/dev/null); then
    echo -e "   ${RED}✗  Failed to fetch repo — check token scope or repo name${RESET}"
    ((failed++)); continue
  fi

  default_branch=$(echo "$repo_json" | jq -r '.default_branch')
  visibility=$(echo "$repo_json"     | jq -r '.visibility')

  echo -e "   ${GREEN}Default branch:${RESET}  ${BOLD}${default_branch}${RESET}  ${DIM}[${visibility}]${RESET}"

  # ── Branch list ─────────────────────────────────────────────────────────────
  if ! branches_json=$(gh_api "/repos/${owner_repo}/branches?per_page=100" 2>/dev/null); then
    echo -e "   ${YELLOW}⚠  Could not fetch branch list${RESET}"
    ((failed++)); continue
  fi

  branch_count=$(echo "$branches_json" | jq 'length')
  branch_names=$(echo "$branches_json" | jq -r '.[].name')
  echo -e "   ${GREEN}Total branches:${RESET}   ${branch_count}"

  # ── Protection rules ────────────────────────────────────────────────────────
  echo -e "   ${GREEN}Protection rules:${RESET}"

  protected_count=0

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue

    # A 404 means no protection — curl -f will fail silently; we just skip
    prot=$(gh_api "/repos/${owner_repo}/branches/${branch}/protection" 2>/dev/null) || continue

    ((protected_count++))

    echo ""
    echo -e "   ${BOLD}${YELLOW}⚑  ${branch}${RESET}"

    # ── Required status checks ────────────────────────────────────────────────
    has_status=$(echo "$prot" | jq -r 'if .required_status_checks then "true" else "false" end')
    if [[ "$has_status" == "true" ]]; then
      strict=$(echo "$prot"   | jq -r '.required_status_checks.strict')
      contexts=$(echo "$prot" | jq -r '.required_status_checks.contexts | join(", ")' 2>/dev/null || echo "—")
      checks=$(echo "$prot"   | jq -r '
        if (.required_status_checks.checks | length) > 0
        then [ .required_status_checks.checks[] | .context ] | join(", ")
        else "—" end
      ' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Required status checks${RESET}"
      echo -e "        Strict up-to-date branch : $(bool_icon "$strict")"
      echo -e "        Contexts                 : ${contexts:-—}"
      echo -e "        Checks                   : ${checks:-—}"
    else
      echo -e "      ${DIM}Required status checks   : —${RESET}"
    fi

    # ── Required pull-request reviews ─────────────────────────────────────────
    has_pr=$(echo "$prot" | jq -r 'if .required_pull_request_reviews then "true" else "false" end')
    if [[ "$has_pr" == "true" ]]; then
      approvals=$(echo "$prot"     | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')
      dismiss=$(echo "$prot"       | jq -r '.required_pull_request_reviews.dismiss_stale_reviews // false')
      code_owners=$(echo "$prot"   | jq -r '.required_pull_request_reviews.require_code_owner_reviews // false')
      last_push=$(echo "$prot"     | jq -r '.required_pull_request_reviews.require_last_push_approval // false')
      bypass_teams=$(echo "$prot"  | jq -r '
        if (.required_pull_request_reviews.bypass_pull_request_allowances.teams | length) > 0
        then [ .required_pull_request_reviews.bypass_pull_request_allowances.teams[].slug ] | join(", ")
        else "—" end
      ' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Required PR reviews${RESET}"
      echo -e "        Approvals required       : ${BOLD}${approvals}${RESET}"
      echo -e "        Dismiss stale reviews    : $(bool_icon "$dismiss")"
      echo -e "        Require code owners      : $(bool_icon "$code_owners")"
      echo -e "        Require last-push approx : $(bool_icon "$last_push")"
      echo -e "        Bypass teams             : ${bypass_teams}"
    else
      echo -e "      ${DIM}Required PR reviews      : —${RESET}"
    fi

    # ── Misc flags ────────────────────────────────────────────────────────────
    enforce_admins=$(echo "$prot"  | jq -r '.enforce_admins.enabled // false')
    force_pushes=$(echo "$prot"    | jq -r '.allow_force_pushes.enabled // false')
    allow_delete=$(echo "$prot"    | jq -r '.allow_deletions.enabled // false')
    linear=$(echo "$prot"          | jq -r '.required_linear_history.enabled // false')
    conv_res=$(echo "$prot"        | jq -r '.required_conversation_resolution.enabled // false')
    signed=$(echo "$prot"          | jq -r '.required_signatures.enabled // false')

    echo -e "      ${DIM}Other settings${RESET}"
    echo -e "        Enforce for admins       : $(bool_icon "$enforce_admins")"
    echo -e "        Allow force pushes       : $(bool_icon "$force_pushes")"
    echo -e "        Allow deletions          : $(bool_icon "$allow_delete")"
    echo -e "        Require linear history   : $(bool_icon "$linear")"
    echo -e "        Require signed commits   : $(bool_icon "$signed")"
    echo -e "        Resolve all conversations: $(bool_icon "$conv_res")"

    # ── Push restrictions ─────────────────────────────────────────────────────
    has_restrictions=$(echo "$prot" | jq -r 'if .restrictions then "true" else "false" end')
    if [[ "$has_restrictions" == "true" ]]; then
      r_users=$(echo "$prot"  | jq -r '[ .restrictions.users[].login ] | join(", ")' 2>/dev/null || echo "—")
      r_teams=$(echo "$prot"  | jq -r '[ .restrictions.teams[].slug  ] | join(", ")' 2>/dev/null || echo "—")
      r_apps=$(echo "$prot"   | jq -r '[ .restrictions.apps[].slug   ] | join(", ")' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Push restrictions${RESET}"
      echo -e "        Users                    : ${r_users:-—}"
      echo -e "        Teams                    : ${r_teams:-—}"
      echo -e "        Apps                     : ${r_apps:-—}"
    else
      echo -e "      ${DIM}Push restrictions        : — (unrestricted)${RESET}"
    fi

  done <<< "$branch_names"

  if [[ $protected_count -eq 0 ]]; then
    echo -e "     ${DIM}No branches have protection rules${RESET}"
  else
    echo -e ""
    echo -e "   ${DIM}${protected_count} of ${branch_count} branch(es) protected${RESET}"
  fi

  ((success++))

done < "$REPOS_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
separator
echo -e "  ${BOLD}Audit complete${RESET}"
echo -e "  Total: ${total}   ${GREEN}✓ Success: ${success}${RESET}   ${RED}✗ Failed: ${failed}${RESET}"
separator
echo ""