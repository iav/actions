#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Hold pull requests until what they depend on is merged.
#
# Every open pull request gets a commit status (DEPENDS_ON_CONTEXT) on its
# head commit: success when all its "Depends-on:" lines are met or a
# maintainer has set the override label, pending while one is not met yet,
# failure when one can never be met or cannot be read. Make the status a
# required check to block the merge.
#
# Dependency lines in the pull request body, one per line:
#   Depends-on: #123                              pull request in this repository is merged
#   Depends-on: owner/repo#123                    pull request on GitHub is merged
#   Depends-on: https://github.com/owner/repo/pull/123
#   Depends-on: owner/repo#123 released           ... and its merge commit is in the latest release
#   Depends-on: owner/repo#123 in <branch|tag>    ... and its merge commit is in that branch or tag
#   Depends-on: git <url> <branch|tag>            the ref exists in any git repository
#   Depends-on: git <url> <ref|sha> in <ref>      that commit is reachable from <ref>
#
set -euo pipefail

repo="${DEPENDS_ON_REPOSITORY:?}"
context="${DEPENDS_ON_CONTEXT:-depends-on}"
override_label="${DEPENDS_ON_OVERRIDE_LABEL:-depends-on: override}"
override_role="${DEPENDS_ON_OVERRIDE_ROLE:-maintain}"
git_max_depth="${DEPENDS_ON_GIT_MAX_DEPTH:-100000}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Result of check_dependency: ok, wait or bad, and a short reason.
dep_state="" dep_reason=""

# The body is anyone's text and the token can write: words from it reach git
# and the API only in these shapes, never as an option.
ref_pattern='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
url_pattern='^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_./~%+-]*$'

# git that speaks https only and runs nothing from the remote side.
function safe_git() {
	git -c protocol.allow=never -c protocol.https.allow=always -c core.sshCommand=false "$@"
}

function role_rank() {
	case "${1}" in
		admin) echo 5 ;;
		maintain) echo 4 ;;
		write) echo 3 ;;
		triage) echo 2 ;;
		read) echo 1 ;;
		*) echo 0 ;;
	esac
}

# Print the "Depends-on:" values of a pull request body, one per line.
# Lines inside fenced code blocks are skipped, so examples do not count.
function parse_dependencies() {
	tr -d '\r' | awk '
		/^[[:space:]]*```/ { fenced = !fenced; next }
		fenced { next }
		tolower($0) ~ /^[[:space:]]*depends-on:/ {
			sub(/^[^:]*:[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			if (length($0)) print
		}'
}

# Is commit $3 contained in ref $4 of GitHub repository $1/$2?
function github_contains() {
	declare status
	status="$(gh api "repos/${1}/${2}/compare/${3}...${4}" --jq '.status' 2> /dev/null)" || return 2
	[[ "${status}" == "ahead" || "${status}" == "identical" ]]
}

# <owner/repo#N | #N | https://github.com/owner/repo/pull/N> [released | in <ref>]
function check_github_pull_request() {
	declare spec="${1}" modifier="${2:-}" in_ref="${3:-}"
	declare owner name number
	if [[ "${spec}" =~ ^#([0-9]+)$ ]]; then
		owner="${repo%%/*}" name="${repo#*/}" number="${BASH_REMATCH[1]}"
	elif [[ "${spec}" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
		owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
	elif [[ "${spec}" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)/?$ ]]; then
		owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
	else
		dep_state=bad dep_reason="cannot parse '${spec}'"
		return
	fi
	declare ref="${owner}/${name}#${number}" info merged merge_sha state
	if ! info="$(gh api "repos/${owner}/${name}/pulls/${number}" --jq '[.merged, .merge_commit_sha, .state] | @tsv' 2> /dev/null)"; then
		dep_state=bad dep_reason="${ref}: cannot read"
		return
	fi
	IFS=$'\t' read -r merged merge_sha state <<< "${info}"
	if [[ "${merged}" != "true" ]]; then
		if [[ "${state}" == "closed" ]]; then
			dep_state=bad dep_reason="${ref}: closed without merge"
		else
			dep_state=wait dep_reason="${ref}: not merged"
		fi
		return
	fi
	case "${modifier}" in
		"")
			dep_state=ok dep_reason="${ref}: merged"
			;;
		released)
			declare tag
			if ! tag="$(gh api "repos/${owner}/${name}/releases/latest" --jq '.tag_name' 2> /dev/null)"; then
				dep_state=wait dep_reason="${ref}: merged, no release yet"
				return
			fi
			if github_contains "${owner}" "${name}" "${merge_sha}" "${tag}"; then
				dep_state=ok dep_reason="${ref}: released in ${tag}"
			elif [[ $? -eq 2 ]]; then
				dep_state=bad dep_reason="${ref}: cannot compare with ${tag}"
			else
				dep_state=wait dep_reason="${ref}: merged, not in ${tag} yet"
			fi
			;;
		in)
			if [[ ! "${in_ref}" =~ ${ref_pattern} ]]; then
				dep_state=bad dep_reason="${ref}: bad ref name"
				return
			fi
			if github_contains "${owner}" "${name}" "${merge_sha}" "${in_ref}"; then
				dep_state=ok dep_reason="${ref}: in ${in_ref}"
			elif [[ $? -eq 2 ]]; then
				dep_state=bad dep_reason="${ref}: cannot compare with ${in_ref}"
			else
				dep_state=wait dep_reason="${ref}: merged, not in ${in_ref} yet"
			fi
			;;
		*)
			dep_state=bad dep_reason="${ref}: unknown '${modifier}'"
			;;
	esac
}

# git <url> <ref|sha> [in <ref>]
function check_git() {
	declare url="${1:-}" ref="${2:-}" keyword="${3:-}" container="${4:-}"
	if [[ -z "${url}" || -z "${ref}" || (-n "${keyword}" && ("${keyword}" != "in" || -z "${container}")) ]]; then
		dep_state=bad dep_reason="git: expected 'git <url> <ref> [in <ref>]'"
		return
	fi
	if [[ ! "${url}" =~ ${url_pattern} || ! "${ref}" =~ ${ref_pattern} || (-n "${container}" && ! "${container}" =~ ${ref_pattern}) ]]; then
		dep_state=bad dep_reason="git: only https:// URLs and plain ref names"
		return
	fi
	declare sha="" listed
	if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
		sha="${ref}"
	else
		if ! listed="$(safe_git ls-remote "${url}" "${ref}" "${ref}^{}" 2> /dev/null)"; then
			dep_state=bad dep_reason="${url}: cannot read"
			return
		fi
		# A peeled tag names the commit; prefer it over the tag object.
		sha="$(awk -v r="${ref}" '$2 ~ "\\^\\{\\}$" { print $1; exit } { first = first ? first : $1 } END { if (first) print first }' <<< "${listed}" | head -n1)"
		if [[ -z "${sha}" ]]; then
			dep_state=wait dep_reason="${url}: no ${ref} yet"
			return
		fi
	fi
	if [[ -z "${container}" ]]; then
		if [[ "${ref}" == "${sha}" ]]; then
			dep_state=bad dep_reason="${url}: a commit needs 'in <ref>'"
		else
			dep_state=ok dep_reason="${url}: ${ref} exists"
		fi
		return
	fi
	# GitHub answers through its API, without fetching any history.
	if [[ "${url}" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$ ]]; then
		declare owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]%.git}"
		if github_contains "${owner}" "${name}" "${sha}" "${container}"; then
			dep_state=ok dep_reason="${owner}/${name}: ${ref} in ${container}"
		elif [[ $? -eq 2 ]]; then
			dep_state=wait dep_reason="${owner}/${name}: cannot compare ${ref} with ${container}"
		else
			dep_state=wait dep_reason="${owner}/${name}: ${ref} not in ${container}"
		fi
		return
	fi
	declare tmp depth fetched
	tmp="$(mktemp -d)"
	git init -q --bare "${tmp}"
	dep_state=wait dep_reason="${url}: ${ref} not in ${container} within ${git_max_depth} commits"
	for depth in 100 1000 10000 "${git_max_depth}"; do
		if ! safe_git -C "${tmp}" fetch -q --filter=tree:0 --depth="${depth}" "${url}" "${container}" 2> /dev/null; then
			dep_state=bad dep_reason="${url}: cannot fetch ${container}"
			break
		fi
		if git -C "${tmp}" cat-file -e "${sha}^{commit}" 2> /dev/null; then
			dep_state=ok dep_reason="${url}: ${ref} in ${container}"
			break
		fi
		fetched="$(git -C "${tmp}" rev-list --count FETCH_HEAD)"
		if [[ "${fetched}" -lt "${depth}" ]]; then
			dep_state=wait dep_reason="${url}: ${ref} not in ${container}"
			break
		fi
		[[ "${depth}" -ge "${git_max_depth}" ]] && break
	done
	rm -rf "${tmp}"
}

function check_dependency() {
	declare -a words
	read -r -a words <<< "${1}"
	dep_state="" dep_reason=""
	if [[ "${words[0],,}" == "git" ]]; then
		check_git "${words[@]:1}"
	else
		check_github_pull_request "${words[0]}" "${words[1]:-}" "${words[2]:-}"
	fi
}

# Print the login that last added the override label, if any.
function override_actor() {
	gh api --paginate "repos/${repo}/issues/${1}/events?per_page=100" 2> /dev/null |
		jq -rs --arg l "${override_label}" '[.[][] | select(.event == "labeled" and .label.name == $l)] | last | .actor.login // empty'
}

# Print the comment that announces to pull request $1 that all of its
# dependencies are met, or nothing if it was already posted for this set of
# dependencies: the hidden marker carries a hash of the set.
# <number> <reason>...
function met_comment() {
	declare number="${1}" && shift
	declare hash marker one
	hash="$(printf '%s\n' "${deps[@]}" | sort | sha1sum | cut -c1-12)"
	marker="<!-- depends-on: met ${hash} -->"
	if gh api --paginate "repos/${repo}/issues/${number}/comments?per_page=100" --jq '.[].body' 2> /dev/null | grep -qF "${marker}"; then
		return 0
	fi
	echo "All dependencies are met:"
	for one in "$@"; do
		echo "- ${one}"
	done
	echo
	echo "${marker}"
}

# Print one JSON object with the decision for pull request $1. Needs read access only.
function evaluate_pull_request() {
	declare number="${1}" pr sha body labels
	pr="$(gh api "repos/${repo}/pulls/${number}")"
	sha="$(jq -r '.head.sha' <<< "${pr}")"
	body="$(jq -r '.body // ""' <<< "${pr}")"
	labels="$(jq -r '.labels[].name' <<< "${pr}")"

	declare -a deps
	mapfile -t deps < <(parse_dependencies <<< "${body}")

	declare state=success description="no dependencies" comment="" one
	declare -a waiting=() broken=() met=()
	for one in "${deps[@]}"; do
		check_dependency "${one}"
		case "${dep_state}" in
			ok) met+=("${dep_reason}") ;;
			wait) waiting+=("${dep_reason}") ;;
			*) broken+=("${dep_reason}") ;;
		esac
	done
	if [[ ${#broken[@]} -gt 0 ]]; then
		state=failure description="$(IFS=';' && echo "${broken[*]}")"
	elif [[ ${#waiting[@]} -gt 0 ]]; then
		state=pending description="waiting: $(IFS=';' && echo "${waiting[*]}")"
	elif [[ ${#met[@]} -gt 0 ]]; then
		description="met: $(IFS=';' && echo "${met[*]}")"
		comment="$(met_comment "${number}" "${met[@]}")"
	fi

	if [[ "${state}" != "success" ]] && grep -qxF "${override_label}" <<< "${labels}"; then
		declare actor role
		actor="$(override_actor "${number}")"
		role="$(gh api "repos/${repo}/collaborators/${actor:-none}/permission" --jq '.role_name' 2> /dev/null || true)"
		if [[ -n "${actor}" && "$(role_rank "${role}")" -ge "$(role_rank "${override_role}")" ]]; then
			state=success description="overridden by @${actor} (${role})"
		else
			description="override label ignored: @${actor:-unknown} is ${role:-not a collaborator}; ${description}"
		fi
	fi

	echo "#${number} ${sha:0:12} ${state}: ${description}" >&2
	echo "| #${number} | ${state} | ${description//|/\\|} |" >> "${summary}"
	jq -nc --argjson number "${number}" --arg sha "${sha}" --arg state "${state}" \
		--arg description "${description:0:140}" --arg comment "${comment}" \
		'{number: $number, sha: $sha, state: $state, description: $description, comment: $comment}'
}

# Set the statuses and post the comments of a JSON array of decisions. Needs
# write access, reads no pull request body: every field is checked for shape.
function apply_decisions() {
	declare item number sha state description comment
	while IFS= read -r item; do
		number="$(jq -r '.number' <<< "${item}")"
		sha="$(jq -r '.sha' <<< "${item}")"
		state="$(jq -r '.state' <<< "${item}")"
		description="$(jq -r '.description' <<< "${item}")"
		comment="$(jq -r '.comment' <<< "${item}")"
		if [[ ! "${number}" =~ ^[0-9]+$ || ! "${sha}" =~ ^[0-9a-f]{40}$ || ! "${state}" =~ ^(success|pending|failure)$ ]]; then
			echo "Skipping a malformed decision: ${item:0:200}" >&2
			continue
		fi
		gh api -X POST "repos/${repo}/statuses/${sha}" -f state="${state}" -f context="${context}" \
			-f description="${description:0:140}" -f target_url="${run_url}" > /dev/null
		if [[ -n "${comment}" ]]; then
			gh api -X POST "repos/${repo}/issues/${number}/comments" -f body="${comment}" > /dev/null
		fi
		echo "#${number} ${sha:0:12} ${state}"
	done < <(jq -c '.[]' <<< "${1}")
}

function pull_requests_to_check() {
	if [[ -n "${DEPENDS_ON_PULL_REQUESTS:-}" && "${DEPENDS_ON_PULL_REQUESTS}" != "all" ]]; then
		tr ' ,' '\n\n' <<< "${DEPENDS_ON_PULL_REQUESTS}" | awk 'NF'
		return
	fi
	# A closed pull request may be what others wait for: check them all.
	if [[ -z "${DEPENDS_ON_PULL_REQUESTS:-}" && -r "${GITHUB_EVENT_PATH:-}" ]]; then
		declare number action
		number="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}")"
		action="$(jq -r '.action // empty' "${GITHUB_EVENT_PATH}")"
		if [[ -n "${number}" && "${action}" != "closed" ]]; then
			echo "${number}"
			return
		fi
	fi
	gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" --jq '.[].number'
}

# Print the decisions for the pull requests to check as a JSON array.
function evaluate() {
	{
		echo "| Pull request | State | Details |"
		echo "|---|---|---|"
	} >> "${summary}"
	declare one_pr
	while read -r one_pr; do
		evaluate_pull_request "${one_pr}"
	done < <(pull_requests_to_check) | jq -sc '.'
}

# evaluate: read-only, writes the decisions to the step output 'result'.
# apply: sets statuses and comments from DEPENDS_ON_RESULT.
# all: both in one step, with one token.
function main() {
	declare result
	case "${DEPENDS_ON_MODE:-all}" in
		evaluate)
			result="$(evaluate)"
			echo "result=${result}" >> "${GITHUB_OUTPUT:-/dev/null}"
			;;
		apply)
			apply_decisions "${DEPENDS_ON_RESULT:?}"
			;;
		all)
			result="$(evaluate)"
			apply_decisions "${result}"
			;;
		*)
			echo "Unknown mode '${DEPENDS_ON_MODE}'" >&2
			return 1
			;;
	esac
}

# Sourcing defines the functions only, for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main
fi
