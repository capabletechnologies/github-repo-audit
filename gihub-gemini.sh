#!/usr/bin/env bash
# =============================================================================
# github_branch_audit.sh — GitHub Branch & Protection / Rulesets Auditor
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

# ── API helper ────────────────────────────────────────────────────────────────
LAST_HTTP_CODE=""
gh_api() {
  local endpoint="$1"
  local tmp_file=".gh_resp_$$.json"
  local code body

  # Safely decouple HTTP code and JSON body using a local file to avoid stream corruption
  # Using -k (insecure) to bypass corporate proxy SSL verification
  # Using -sS to silence progress meter but show underlying curl errors
  code=$(curl -sS -k -L -w "%{http_code}" -o "$tmp_file" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_BASE}${endpoint}")

  LAST_HTTP_CODE="$code"
  body=$(cat "$tmp_file" 2>/dev/null || echo "")
  rm -f "$tmp_file"

  if [[ "$DEBUG" == "1" ]]; then
    echo -e "      ${DIM}[debug] ${endpoint} -> HTTP ${code:-none}, body ${#body} bytes${RESET}" >&2
  fi

  if [[ -z "$code" || ! "$code" =~ ^[0-9]+$ ]]; then
    LAST_HTTP_CODE="000"
    echo "curl failed / no HTTP code — check network or proxy" >&2
    return 1
  fi

  if [[ "$code" -ge 400 ]]; then
    local msg; msg=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null || true)
    echo "HTTP ${code}${msg:+ — ${msg}}" >&2
    return 1
  fi
  
  # Strict Failsafe: Ensure response is valid JSON (prevents silent failures on proxy block pages)
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    echo "HTTP ${code} — Invalid JSON received (Corporate proxy intercept?)" >&2
    [[ "$DEBUG" == "1" ]] && echo -e "${DIM}RAW BODY: ${body}${RESET}" >&2
    return 1
  fi

  printf '%s' "$body"
}

extract_owner_repo() { local url="${1%.git}"; echo "${url#*github.com/}"; }
separator() { echo -e "${DIM}────────────────────────────────────────────────────────────────────────${RESET}"; }
bool_icon() { [[ "${1:-false}" == "true" ]] && echo -e "${GREEN}yes${RESET}" || echo -e "${DIM}no${RESET}"; }

jq_val() {
  local result
  result=$(printf '%s' "$1" | jq -r "${2} // empty" 2>/dev/null) || true
  if [[ -z "$result" || "$result" == "null" ]]; then echo "-"; else echo "$result"; fi
}

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

  # ── Repo info ───────────────────────────────────────────────────────────────
  if ! repo_json=$(gh_api "/repos/${owner_repo}" 2>/tmp/gh_err_$$); then
    echo -e "   ${RED}✗  Could not fetch repo — $(cat /tmp/gh_err_$$ 2>/dev/null || echo "Unknown error")${RESET}"
    rm -f /tmp/gh_err_$$
    failed=$((failed + 1)); continue
  fi
  rm -f /tmp/gh_err_$$

  default_branch=$(jq_val "$repo_json" '.default_branch')
  visibility=$(jq_val     "$repo_json" '.visibility')
  echo -e "   ${GREEN}Default branch :${RESET}  ${BOLD}${default_branch}${RESET}  ${DIM}[${visibility}]${RESET}"

  # ── Branch list ─────────────────────────────────────────────────────────────
  if ! branches_json=$(gh_api "/repos/${owner_repo}/branches?per_page=100" 2>/tmp/gh_err_$$); then
    echo -e "   ${YELLOW}⚠  Could not fetch branch list — $(cat /tmp/gh_err_$$ 2>/dev/null || echo "Unknown error")${RESET}"
    rm -f /tmp/gh_err_$$
    failed=$((failed + 1)); continue
  fi
  rm -f /tmp/gh_err_$$
  
  branch_count=$(printf '%s' "$branches_json" | jq 'length' 2>/dev/null)
  [[ -z "$branch_count" || "$branch_count" == "null" ]] && branch_count="0"
  echo -e "   ${GREEN}Total branches :${RESET}  ${branch_count}"

  # ── Repository rulesets (modern protection) ──────────────────────────────────
  echo -e "   ${GREEN}Repository rulesets:${RESET}"
  ruleset_count=0
  if rulesets_json=$(gh_api "/repos/${owner_repo}/rulesets?includes_parents=true" 2>/tmp/gh_err_$$); then
    rm -f /tmp/gh_err_$$
    ruleset_count=$(printf '%s' "$rulesets_json" | jq 'length' 2>/dev/null)
    [[ -z "$ruleset_count" || "$ruleset_count" == "null" ]] && ruleset_count="0"
    
    if [[ "$ruleset_count" -gt 0 ]]; then
      while IFS="|" read -r rs_id rs_type rs_source; do
        [[ -z "$rs_id" || "$rs_id" == "null" ]] && continue
        
        # Route logic specifically added to account for Organization vs Repository rulesets
        local rs_endpoint="/repos/${owner_repo}/rulesets/${rs_id}"
        [[ "$rs_type" == "Organization" ]] && rs_endpoint="/orgs/${rs_source}/rulesets/${rs_id}"

        rs_detail=$(gh_api "$rs_endpoint" 2>/dev/null) || continue
        rs_name=$(jq_val   "$rs_detail" '.name')
        rs_enf=$(jq_val    "$rs_detail" '.enforcement')
        rs_target=$(jq_val "$rs_detail" '.target')
        rs_incl=$(printf '%s' "$rs_detail" | jq -r '[.conditions.ref_name.include[]?] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
        rs_rules=$(printf '%s' "$rs_detail" | jq -r '[.rules[]?.type] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
        echo ""
        echo -e "   ${BOLD}${YELLOW}⚑  ${rs_name}${RESET}  ${DIM}[${rs_enf}, target: ${rs_target}, source: ${rs_type}]${RESET}"
        echo -e "        Applies to refs          : ${rs_incl}"
        echo -e "        Rules                    : ${rs_rules}"

        pr_rule=$(printf '%s' "$rs_detail" | jq -c '.rules[]? | select(.type=="pull_request")' 2>/dev/null || true)
        if [[ -n "$pr_rule" ]]; then
          approvals=$(printf '%s' "$pr_rule" | jq -r '.parameters.required_approving_review_count // "—"' 2>/dev/null)
          dismiss=$(printf '%s'   "$pr_rule" | jq -r '.parameters.dismiss_stale_reviews_on_push // false' 2>/dev/null)
          codeowners=$(printf '%s' "$pr_rule" | jq -r '.parameters.require_code_owner_review // false' 2>/dev/null)
          lastpush=$(printf '%s'  "$pr_rule" | jq -r '.parameters.require_last_push_approval // false' 2>/dev/null)
          echo -e "        ${DIM}PR reviews${RESET}"
          echo -e "          Approvals required     : ${BOLD}${approvals}${RESET}"
          echo -e "          Dismiss stale reviews  : $(bool_icon "$dismiss")"
          echo -e "          Require code owners    : $(bool_icon "$codeowners")"
          echo -e "          Require last-push appr : $(bool_icon "$lastpush")"
        fi

        sc_rule=$(printf '%s' "$rs_detail" | jq -c '.rules[]? | select(.type=="required_status_checks")' 2>/dev/null || true)
        if [[ -n "$sc_rule" ]]; then
          checks=$(printf '%s' "$sc_rule" | jq -r '[.parameters.required_status_checks[]?.context] | if length>0 then join(", ") else "—" end' 2>/dev/null || echo "—")
          strict=$(printf '%s' "$sc_rule" | jq -r '.parameters.strict_required_status_checks_policy // false' 2>/dev/null)
          echo -e "        ${DIM}Status checks${RESET}"
          echo -e "          Strict (up-to-date)    : $(bool_icon "$strict")"
          echo -e "          Checks                 : ${checks}"
        fi
      done < <(printf '%s' "$rulesets_json" | jq -r '.[] | "\(.id)|\(.source_type)|\(.source)"' 2>/dev/null)
    else
      echo -e "     ${DIM}No repository rulesets${RESET}"
    fi
  else
    echo -e "     ${YELLOW}⚠  Could not fetch rulesets — $(cat /tmp/gh_err_$$ 2>/dev/null || echo "Unknown error")${RESET}"
    rm -f /tmp/gh_err_$$
  fi

  # ── Classic branch protection ────────────────────────────────────────────────
  echo -e "   ${GREEN}Classic branch protection:${RESET}"
  protected_count=0
  while IFS= read -r branch; do
    [[ -z "${branch}" || "$branch" == "null" ]] && continue
    if ! prot=$(gh_api "/repos/${owner_repo}/branches/${branch}/protection" 2>/tmp/gh_err_$$); then
      [[ "$LAST_HTTP_CODE" == "404" ]] && { rm -f /tmp/gh_err_$$; continue; }
      echo -e "      ${RED}⚠  ${branch}: $(cat /tmp/gh_err_$$ 2>/dev/null || echo "Unknown error")${RESET}"
      rm -f /tmp/gh_err_$$
      continue
    fi
    rm -f /tmp/gh_err_$$
    protected_count=$((protected_count + 1))
    echo ""
    echo -e "   ${BOLD}${YELLOW}⚑  ${branch}${RESET}"

    if [[ "$(printf '%s' "$prot" | jq -r 'has("required_pull_request_reviews")')" == "true" ]]; then
      approvals=$(jq_val "$prot" '.required_pull_request_reviews.required_approving_review_count')
      echo -e "        Approvals required       : ${BOLD}${approvals}${RESET}"
    fi
    enforce_admins=$(jq_val "$prot" '.enforce_admins.enabled')
    force_pushes=$(jq_val   "$prot" '.allow_force_pushes.enabled')
    allow_delete=$(jq_val   "$prot" '.allow_deletions.enabled')
    echo -e "        Enforce for admins       : $(bool_icon "$enforce_admins")"
    echo -e "        Allow force pushes       : $(bool_icon "$force_pushes")"
    echo -e "        Allow deletions          : $(bool_icon "$allow_delete")"
  done < <(printf '%s' "$branches_json" | jq -r '.[].name' 2>/dev/null)
  [[ $protected_count -eq 0 ]] && echo -e "     ${DIM}No branches use classic protection${RESET}"

  # ── Per-repo summary ─────────────────────────────────────────────────────────
  echo ""
  echo -e "   ${DIM}${ruleset_count:-0} ruleset(s), ${protected_count} classic-protected branch(es) of ${branch_count:-0}${RESET}"

  success=$((success + 1))
done < "$REPOS_FILE"

echo ""
separator
echo -e "  ${BOLD}Audit complete${RESET}"
echo -e "  Total: ${total}   ${GREEN}✓ Success: ${success}${RESET}   ${RED}✗ Failed: ${failed}${RESET}"
separator
echo ""