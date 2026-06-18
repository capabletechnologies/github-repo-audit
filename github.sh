#!/usr/bin/env bash
# =============================================================================
# github_branch_audit.sh — GitHub Branch & Protection Rules Auditor
# =============================================================================
# Requirements: curl, jq
# Auth:         export GITHUB_TOKEN=ghp_yourtoken
# Usage:        ./github_branch_audit.sh [repos.txt] [--debug]
# Compatible:   Linux, macOS, Git Bash (Windows/MINGW64)
# =============================================================================

set -uo pipefail

REPOS_FILE="repos.txt"
DEBUG=0
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=1 ;;
    *)       REPOS_FILE="$arg" ;;
  esac
done

API_BASE="https://api.github.com"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo -e "${RED}Error:${RESET} GITHUB_TOKEN is not set."
  echo "  Run: export GITHUB_TOKEN=ghp_yourtoken"; exit 1
fi
if ! command -v jq &>/dev/null; then
  echo -e "${RED}Error:${RESET} jq is required but not installed."
  echo "  Install: sudo apt install jq  OR  brew install jq  OR  winget install jqlang.jq"; exit 1
fi
if [[ ! -f "$REPOS_FILE" ]]; then
  echo -e "${RED}Error:${RESET} Repos file not found: ${REPOS_FILE}"; exit 1
fi

LAST_HTTP_CODE=""
LAST_BODY=""
gh_api() {
  local endpoint="$1"
  local sep=$'\n__HTTPCODE__:'
  local raw http_code body msg

  raw=$(curl -s -w "${sep}%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_BASE}${endpoint}" 2>/dev/null) || true

  http_code="${raw##*__HTTPCODE__:}"
  http_code="${http_code//[$'\r\n ']/}"
  body="${raw%%$'\n'__HTTPCODE__:*}"

  LAST_HTTP_CODE="$http_code"
  LAST_BODY="$body"

  if [[ "$DEBUG" == "1" ]]; then
    echo -e "      ${DIM}[debug] ${endpoint} -> HTTP ${http_code:-none}, body ${#body} bytes${RESET}" >&2
  fi

  if [[ -z "$http_code" || ! "$http_code" =~ ^[0-9]+$ ]]; then
    LAST_HTTP_CODE="000"
    echo "curl failed / no HTTP code — check network or proxy" >&2
    return 1
  fi
  if [[ "$http_code" -ge 400 ]]; then
    msg=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null || true)
    echo "HTTP ${http_code}${msg:+ — ${msg}}" >&2
    return 1
  fi
  printf '%s' "$body"
}

extract_owner_repo() { local url="${1%.git}"; echo "${url#*github.com/}"; }
separator() { echo -e "${DIM}────────────────────────────────────────────────────────────────────────${RESET}"; }
bool_icon() { [[ "${1:-false}" == "true" ]] && echo -e "${GREEN}yes${RESET}" || echo -e "${DIM}no${RESET}"; }
jq_val() {
  local result; result=$(printf '%s' "$1" | jq -r "${2} // empty" 2>/dev/null) || true
  echo "${result:-—}"
}

echo ""
if me=$(gh_api "/user" 2>/tmp/gh_err); then
  login=$(jq_val "$me" '.login')
  echo -e "${DIM}Authenticated as: ${login}${RESET}"
  scopes=$(curl -sI -H "Authorization: Bearer ${GITHUB_TOKEN}" "${API_BASE}/user" 2>/dev/null \
    | tr -d '\r' | grep -i '^x-oauth-scopes:' | cut -d' ' -f2- || true)
  [[ -n "${scopes:-}" ]] && echo -e "${DIM}Token scopes: ${scopes}${RESET}"
else
  echo -e "${RED}✗ Token check failed — $(cat /tmp/gh_err)${RESET}"
  echo -e "${RED}  Your GITHUB_TOKEN is invalid or expired. Fix this first.${RESET}"
  exit 1
fi

repo_count=0
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  line="${line//$'\r'/}"
  [[ -z "${line// }" || "$line" == \#* ]] && continue
  repo_count=$((repo_count + 1))
done < "$REPOS_FILE"

separator
echo -e "  ${BOLD}GitHub Branch & Protection Rules Audit${RESET}"
echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')   File: ${REPOS_FILE}   Repos: ${repo_count}${RESET}"
separator

total=0; success=0; failed=0

while IFS= read -r url || [[ -n "${url:-}" ]]; do
  url="${url//$'\r'/}"
  [[ -z "${url// }" || "$url" == \#* ]] && continue
  total=$((total + 1))

  owner_repo=$(extract_owner_repo "$url")
  owner="${owner_repo%%/*}"; repo="${owner_repo##*/}"

  echo ""
  echo -e "${BOLD}${CYAN}▶  ${owner} / ${repo}${RESET}"
  echo -e "   ${DIM}${url}${RESET}"

  if ! repo_json=$(gh_api "/repos/${owner_repo}" 2>/tmp/gh_err); then
    err="$(cat /tmp/gh_err)"
    echo -e "   ${RED}✗  Could not fetch repo — ${err}${RESET}"
    if [[ "$LAST_HTTP_CODE" == "403" ]]; then
      echo -e "   ${YELLOW}  → If this is a SAML-protected org, authorize your token for SSO:${RESET}"
      echo -e "   ${YELLOW}    GitHub → Settings → Developer settings → Tokens → Configure SSO → Authorize${RESET}"
    fi
    failed=$((failed + 1)); continue
  fi

  default_branch=$(jq_val "$repo_json" '.default_branch')
  visibility=$(jq_val     "$repo_json" '.visibility')

  if [[ "$default_branch" == "—" ]]; then
    echo -e "   ${RED}Default branch :${RESET}  ${RED}— (empty despite HTTP ${LAST_HTTP_CODE})${RESET}"
    echo -e "   ${YELLOW}  → The API returned a repo object without 'default_branch'.${RESET}"
    echo -e "   ${YELLOW}    Token likely lacks read access. Check: SSO authorization + 'repo'${RESET}"
    echo -e "   ${YELLOW}    (classic) or 'Contents:Read'+'Administration:Read' (fine-grained).${RESET}"
    if [[ "$DEBUG" == "1" ]]; then
      echo -e "   ${DIM}[debug] repo JSON keys:${RESET}"
      printf '%s' "$repo_json" | jq -r 'keys[]?' 2>/dev/null | sed 's/^/        /' | head -20
    fi
  else
    echo -e "   ${GREEN}Default branch :${RESET}  ${BOLD}${default_branch}${RESET}  ${DIM}[${visibility}]${RESET}"
  fi

  if ! branches_json=$(gh_api "/repos/${owner_repo}/branches?per_page=100" 2>/tmp/gh_err); then
    echo -e "   ${YELLOW}⚠  Could not fetch branch list — $(cat /tmp/gh_err)${RESET}"
    failed=$((failed + 1)); continue
  fi

  branch_count=$(printf '%s' "$branches_json" | jq 'length' 2>/dev/null || echo "?")
  echo -e "   ${GREEN}Total branches :${RESET}  ${branch_count}"
  echo -e "   ${GREEN}Protection rules:${RESET}"

  protected_count=0

  while IFS= read -r branch; do
    [[ -z "${branch}" ]] && continue

    if ! prot=$(gh_api "/repos/${owner_repo}/branches/${branch}/protection" 2>/tmp/gh_err); then
      if [[ "$LAST_HTTP_CODE" == "404" ]]; then
        continue
      fi
      echo -e "      ${RED}⚠  ${branch}: $(cat /tmp/gh_err)${RESET}"
      continue
    fi

    protected_count=$((protected_count + 1))
    echo ""
    echo -e "   ${BOLD}${YELLOW}⚑  ${branch}${RESET}"

    if [[ "$(printf '%s' "$prot" | jq -r 'has("required_status_checks")')" == "true" ]]; then
      strict=$(jq_val "$prot" '.required_status_checks.strict')
      contexts=$(printf '%s' "$prot" | jq -r '[.required_status_checks.contexts[]?] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      checks=$(printf '%s' "$prot"   | jq -r '[.required_status_checks.checks[]?.context] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Required status checks${RESET}"
      echo -e "        Strict (up-to-date)      : $(bool_icon "$strict")"
      echo -e "        Contexts                 : ${contexts}"
      echo -e "        Checks                   : ${checks}"
    else
      echo -e "      ${DIM}Required status checks   : —${RESET}"
    fi

    if [[ "$(printf '%s' "$prot" | jq -r 'has("required_pull_request_reviews")')" == "true" ]]; then
      approvals=$(jq_val   "$prot" '.required_pull_request_reviews.required_approving_review_count')
      dismiss=$(jq_val     "$prot" '.required_pull_request_reviews.dismiss_stale_reviews')
      code_owners=$(jq_val "$prot" '.required_pull_request_reviews.require_code_owner_reviews')
      last_push=$(jq_val   "$prot" '.required_pull_request_reviews.require_last_push_approval')
      bypass_teams=$(printf '%s' "$prot" | jq -r '[.required_pull_request_reviews.bypass_pull_request_allowances.teams[]?.slug] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Required PR reviews${RESET}"
      echo -e "        Approvals required       : ${BOLD}${approvals}${RESET}"
      echo -e "        Dismiss stale reviews    : $(bool_icon "$dismiss")"
      echo -e "        Require code owners      : $(bool_icon "$code_owners")"
      echo -e "        Require last-push approv : $(bool_icon "$last_push")"
      echo -e "        Bypass teams             : ${bypass_teams}"
    else
      echo -e "      ${DIM}Required PR reviews      : —${RESET}"
    fi

    enforce_admins=$(jq_val "$prot" '.enforce_admins.enabled')
    force_pushes=$(jq_val   "$prot" '.allow_force_pushes.enabled')
    allow_delete=$(jq_val   "$prot" '.allow_deletions.enabled')
    linear=$(jq_val         "$prot" '.required_linear_history.enabled')
    conv_res=$(jq_val       "$prot" '.required_conversation_resolution.enabled')
    signed=$(jq_val         "$prot" '.required_signatures.enabled')
    if [[ "$signed" == "—" ]]; then
      sig_json=$(gh_api "/repos/${owner_repo}/branches/${branch}/protection/required_signatures" 2>/dev/null) || sig_json=""
      signed=$(jq_val "$sig_json" '.enabled')
    fi

    echo -e "      ${DIM}Other settings${RESET}"
    echo -e "        Enforce for admins       : $(bool_icon "$enforce_admins")"
    echo -e "        Allow force pushes       : $(bool_icon "$force_pushes")"
    echo -e "        Allow deletions          : $(bool_icon "$allow_delete")"
    echo -e "        Require linear history   : $(bool_icon "$linear")"
    echo -e "        Require signed commits   : $(bool_icon "$signed")"
    echo -e "        Resolve conversations    : $(bool_icon "$conv_res")"

    if [[ "$(printf '%s' "$prot" | jq -r 'has("restrictions")')" == "true" ]]; then
      r_users=$(printf '%s' "$prot" | jq -r '[.restrictions.users[]?.login] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      r_teams=$(printf '%s' "$prot" | jq -r '[.restrictions.teams[]?.slug]  | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      r_apps=$(printf '%s'  "$prot" | jq -r '[.restrictions.apps[]?.slug]   | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
      echo -e "      ${DIM}Push restrictions${RESET}"
      echo -e "        Users                    : ${r_users}"
      echo -e "        Teams                    : ${r_teams}"
      echo -e "        Apps                     : ${r_apps}"
    else
      echo -e "      ${DIM}Push restrictions        : — (unrestricted)${RESET}"
    fi

  done < <(printf '%s' "$branches_json" | jq -r '.[].name' 2>/dev/null)

  if [[ $protected_count -eq 0 ]]; then
    echo -e "     ${DIM}No branches have protection rules${RESET}"
  else
    echo ""
    echo -e "   ${DIM}${protected_count} of ${branch_count} branch(es) protected${RESET}"
  fi

  success=$((success + 1))
done < "$REPOS_FILE"

echo ""
separator
echo -e "  ${BOLD}Audit complete${RESET}"
echo -e "  Total: ${total}   ${GREEN}✓ Success: ${success}${RESET}   ${RED}✗ Failed: ${failed}${RESET}"
separator
echo ""