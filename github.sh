#!/usr/bin/env bash
# =============================================================================
# github_branch_audit.sh — GitHub Branch & Protection Rules Auditor
# =============================================================================
# Requirements: curl, jq
# Auth:         export GITHUB_TOKEN=ghp_yourtoken
# Usage:        ./github_branch_audit.sh [repos.txt]
# Compatible:   Linux, macOS, Git Bash (Windows/MINGW64)
# =============================================================================

# No set -e: we handle errors explicitly so Git Bash / MINGW doesn't bail out
# silently on non-zero sub-expressions or jq edge cases.
set -uo pipefail

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
  echo "  Install: sudo apt install jq  OR  brew install jq  OR  winget install jqlang.jq"
  exit 1
fi

if [[ ! -f "$REPOS_FILE" ]]; then
  echo -e "${RED}Error:${RESET} Repos file not found: ${REPOS_FILE}"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

gh_api() {
  # Returns JSON on stdout; returns non-zero on HTTP 4xx/5xx (curl -f)
  local endpoint="$1"
  curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_BASE}${endpoint}"
}

extract_owner_repo() {
  local url="${1%.git}"
  echo "${url#*github.com/}"
}

separator() {
  echo -e "${DIM}────────────────────────────────────────────────────────────────────────${RESET}"
}

bool_icon() {
  if [[ "${1:-false}" == "true" ]]; then
    echo -e "${GREEN}yes${RESET}"
  else
    echo -e "${DIM}no${RESET}"
  fi
}

jq_val() {
  # Safe jq wrapper — returns "—" if field is null/missing/empty
  local json="$1" filter="$2"
  local result
  result=$(echo "$json" | jq -r "${filter} // empty" 2>/dev/null) || true
  echo "${result:-—}"
}

# ── Count repos (strip comments/blanks) ───────────────────────────────────────
repo_count=0
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  line="${line//$'\r'/}"                      # strip Windows CR
  [[ -z "${line// }" || "$line" == \#* ]] && continue
  repo_count=$((repo_count + 1))
done < "$REPOS_FILE"

# ── Header ────────────────────────────────────────────────────────────────────
separator
echo -e "  ${BOLD}GitHub Branch & Protection Rules Audit${RESET}"
echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')   File: ${REPOS_FILE}   Repos: ${repo_count}${RESET}"
separator

total=0
success=0
failed=0

# ── Main loop ─────────────────────────────────────────────────────────────────
while IFS= read -r url || [[ -n "${url:-}" ]]; do

  # Strip Windows carriage return and skip blanks / comments
  url="${url//$'\r'/}"
  [[ -z "${url// }" || "$url" == \#* ]] && continue

  total=$((total + 1))

  owner_repo=$(extract_owner_repo "$url")
  owner="${owner_repo%%/*}"
  repo="${owner_repo##*/}"

  echo ""
  echo -e "${BOLD}${CYAN}▶  ${owner} / ${repo}${RESET}"
  echo -e "   ${DIM}${url}${RESET}"

  # ── Repo info ────────────────────────────────────────────────────────────────
  repo_json=""
  if ! repo_json=$(gh_api "/repos/${owner_repo}" 2>/dev/null); then
    echo -e "   ${RED}✗  Could not fetch repo — verify token scope (repo) and repo name${RESET}"
    failed=$((failed + 1))
    continue
  fi

  default_branch=$(jq_val "$repo_json" '.default_branch')
  visibility=$(jq_val     "$repo_json" '.visibility')

  echo -e "   ${GREEN}Default branch :${RESET}  ${BOLD}${default_branch}${RESET}  ${DIM}[${visibility}]${RESET}"

  # ── Branch list ──────────────────────────────────────────────────────────────
  branches_json=""
  if ! branches_json=$(gh_api "/repos/${owner_repo}/branches?per_page=100" 2>/dev/null); then
    echo -e "   ${YELLOW}⚠  Could not fetch branch list${RESET}"
    failed=$((failed + 1))
    continue
  fi

  branch_count=$(echo "$branches_json" | jq 'length' 2>/dev/null || echo "?")
  echo -e "   ${GREEN}Total branches :${RESET}  ${branch_count}"

  # ── Protection rules ─────────────────────────────────────────────────────────
  echo -e "   ${GREEN}Protection rules:${RESET}"

  protected_count=0

  while IFS= read -r branch; do
    [[ -z "${branch}" ]] && continue

    prot=""
    prot=$(gh_api "/repos/${owner_repo}/branches/${branch}/protection" 2>/dev/null) || continue
    # If we reach here the branch has a protection rule
    protected_count=$((protected_count + 1))

    echo ""
    echo -e "   ${BOLD}${YELLOW}⚑  ${branch}${RESET}"

    # Required status checks
    has_checks=$(echo "$prot" | jq -r 'if .required_status_checks then "true" else "false" end' 2>/dev/null || echo "false")
    if [[ "$has_checks" == "true" ]]; then
      strict=$(jq_val    "$prot" '.required_status_checks.strict')
      contexts=$(echo "$prot" | jq -r '[.required_status_checks.contexts[]? ] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      checks=$(echo   "$prot" | jq -r '[.required_status_checks.checks[]?.context] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Required status checks${RESET}"
      echo -e "        Strict (up-to-date)      : $(bool_icon "$strict")"
      echo -e "        Contexts                 : ${contexts}"
      echo -e "        Checks                   : ${checks}"
    else
      echo -e "      ${DIM}Required status checks   : —${RESET}"
    fi

    # Required PR reviews
    has_pr=$(echo "$prot" | jq -r 'if .required_pull_request_reviews then "true" else "false" end' 2>/dev/null || echo "false")
    if [[ "$has_pr" == "true" ]]; then
      approvals=$(jq_val    "$prot" '.required_pull_request_reviews.required_approving_review_count')
      dismiss=$(jq_val      "$prot" '.required_pull_request_reviews.dismiss_stale_reviews')
      code_owners=$(jq_val  "$prot" '.required_pull_request_reviews.require_code_owner_reviews')
      last_push=$(jq_val    "$prot" '.required_pull_request_reviews.require_last_push_approval')
      bypass_teams=$(echo "$prot" | jq -r '[.required_pull_request_reviews.bypass_pull_request_allowances.teams[]?.slug] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Required PR reviews${RESET}"
      echo -e "        Approvals required       : ${BOLD}${approvals}${RESET}"
      echo -e "        Dismiss stale reviews    : $(bool_icon "$dismiss")"
      echo -e "        Require code owners      : $(bool_icon "$code_owners")"
      echo -e "        Require last-push approv : $(bool_icon "$last_push")"
      echo -e "        Bypass teams             : ${bypass_teams}"
    else
      echo -e "      ${DIM}Required PR reviews      : —${RESET}"
    fi

    # General flags
    enforce_admins=$(jq_val "$prot" '.enforce_admins.enabled')
    force_pushes=$(jq_val   "$prot" '.allow_force_pushes.enabled')
    allow_delete=$(jq_val   "$prot" '.allow_deletions.enabled')
    linear=$(jq_val         "$prot" '.required_linear_history.enabled')
    conv_res=$(jq_val       "$prot" '.required_conversation_resolution.enabled')
    signed=$(jq_val         "$prot" '.required_signatures.enabled')

    echo -e "      ${DIM}Other settings${RESET}"
    echo -e "        Enforce for admins       : $(bool_icon "$enforce_admins")"
    echo -e "        Allow force pushes       : $(bool_icon "$force_pushes")"
    echo -e "        Allow deletions          : $(bool_icon "$allow_delete")"
    echo -e "        Require linear history   : $(bool_icon "$linear")"
    echo -e "        Require signed commits   : $(bool_icon "$signed")"
    echo -e "        Resolve conversations    : $(bool_icon "$conv_res")"

    # Push restrictions
    has_restrictions=$(echo "$prot" | jq -r 'if .restrictions then "true" else "false" end' 2>/dev/null || echo "false")
    if [[ "$has_restrictions" == "true" ]]; then
      r_users=$(echo "$prot" | jq -r '[.restrictions.users[]?.login] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      r_teams=$(echo "$prot" | jq -r '[.restrictions.teams[]?.slug]  | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      r_apps=$(echo  "$prot" | jq -r '[.restrictions.apps[]?.slug]   | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Push restrictions${RESET}"
      echo -e "        Users                    : ${r_users}"
      echo -e "        Teams                    : ${r_teams}"
      echo -e "        Apps                     : ${r_apps}"
    else
      echo -e "      ${DIM}Push restrictions        : — (unrestricted)${RESET}"
    fi

  done < <(echo "$branches_json" | jq -r '.[].name' 2>/dev/null)

  if [[ $protected_count -eq 0 ]]; then
    echo -e "     ${DIM}No branches have protection rules${RESET}"
  else
    echo -e ""
    echo -e "   ${DIM}${protected_count} of ${branch_count} branch(es) protected${RESET}"
  fi

  success=$((success + 1))

done < "$REPOS_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
separator
echo -e "  ${BOLD}Audit complete${RESET}"
echo -e "  Total: ${total}   ${GREEN}✓ Success: ${success}${RESET}   ${RED}✗ Failed: ${failed}${RESET}"
separator
echo ""