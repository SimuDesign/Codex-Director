#!/bin/zsh
set -euo pipefail

audit_mode="tracked"
audit_report=""
large_file_limit_bytes=$((5 * 1024 * 1024))

usage() {
    print "Usage: $0 [--tracked|--history|--all] [--report PATH]"
}

while (( $# > 0 )); do
    case "$1" in
        --tracked)
            audit_mode="tracked"
            ;;
        --history)
            audit_mode="history"
            ;;
        --all)
            audit_mode="all"
            ;;
        --report)
            shift
            if (( $# == 0 )); then
                usage >&2
                exit 2
            fi
            audit_report="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
    shift
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

audit_temp="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-public-audit.XXXXXX")"
issues_file="$audit_temp/issues.tsv"
touch "$issues_file"
trap 'rm -rf "$audit_temp"' EXIT INT TERM

record_issue() {
    local reason="$1"
    local location="$2"
    printf '%s\t%s\n' "$reason" "$location" >> "$issues_file"
}

is_large_file_allowed() {
    local entry_path="$1"
    [[ -f .public-release-large-files ]] && grep -Fqx -- "$entry_path" .public-release-large-files
}

file_size_bytes() {
    local entry_path="$1"
    if stat -f '%z' "$entry_path" >/dev/null 2>&1; then
        stat -f '%z' "$entry_path"
    else
        stat -c '%s' "$entry_path"
    fi
}

normalize_safe_examples() {
    sed -E \
        -e 's#/Users/(example|runner|test|Shared)#{{HOME}}#g' \
        -e 's#github_pat_EXAMPLE[A-Za-z0-9_]*#REDACTED_EXAMPLE#g' \
        -e 's#gh[pousr]_EXAMPLE[A-Za-z0-9]*#REDACTED_EXAMPLE#g'
}

scan_content_stream() {
    local location="$1"
    local normalized="$audit_temp/normalized"
    normalize_safe_examples > "$normalized"

    if LC_ALL=C grep -Eq '/Users/[A-Za-z0-9._-]+' "$normalized"; then
        record_issue "personal-home-path" "$location"
    fi

    local private_temp_prefix="/private"'/tmp'
    if LC_ALL=C grep -Fq "$private_temp_prefix" "$normalized"; then
        record_issue "private-temporary-path" "$location"
    fi

    if LC_ALL=C grep -Eiq \
        'github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|Bearer[[:space:]]+[A-Za-z0-9._=-]{20,}|(session|auth)[_-]?(token|cookie)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._=-]{16,}' \
        "$normalized"; then
        record_issue "credential-pattern" "$location"
    fi
}

scan_tracked_file() {
    local entry_path="$1"
    local lower_path="${entry_path:l}"

    case "$lower_path" in
        *.sqlite|*.sqlite3|*.db|*.db-wal|*.db-shm|*.db-journal|*.log|*.codexpack.zip|*.pem|*.key|*.p12|*.mobileprovision|*.xcuserstate)
            record_issue "sensitive-file-type" "$entry_path"
            ;;
        */.env|*/.env.*|.env|.env.*)
            if [[ "$lower_path" != ".env.example" && "$lower_path" != */.env.example ]]; then
                record_issue "environment-file" "$entry_path"
            fi
            ;;
    esac

    local size
    size="$(file_size_bytes "$entry_path")"
    if (( size > large_file_limit_bytes )) && ! is_large_file_allowed "$entry_path"; then
        record_issue "unregistered-large-file" "$entry_path"
    fi

    if LC_ALL=C grep -Iq . "$entry_path" || [[ ! -s "$entry_path" ]]; then
        scan_content_stream "$entry_path" < "$entry_path"
    else
        strings -a "$entry_path" 2>/dev/null | scan_content_stream "$entry_path"
    fi
}

scan_tracked_tree() {
    local entry_path
    while IFS= read -r -d $'\0' entry_path; do
        [[ -f "$entry_path" ]] || continue
        scan_tracked_file "$entry_path"
    done < <(git ls-files -z)
}

scan_history() {
    local history_patch="$audit_temp/history.patch"
    git log --all --no-ext-diff --binary --format=fuller -p > "$history_patch"
    scan_content_stream "git-history" < "$history_patch"

    local object_path
    while IFS= read -r object_path; do
        object_path="${object_path#* }"
        [[ -n "$object_path" ]] || continue
        local lower_path="${object_path:l}"
        case "$lower_path" in
            *.sqlite|*.sqlite3|*.db|*.db-wal|*.db-shm|*.db-journal|*.log|*.codexpack.zip|*.pem|*.key|*.p12|*.mobileprovision|*.xcuserstate|*/.env|*/.env.*|.env|.env.*)
                if [[ "$lower_path" != ".env.example" && "$lower_path" != */.env.example ]]; then
                    record_issue "sensitive-history-path" "$object_path"
                fi
                ;;
        esac
    done < <(git rev-list --objects --all)
}

case "$audit_mode" in
    tracked)
        scan_tracked_tree
        ;;
    history)
        scan_history
        ;;
    all)
        scan_tracked_tree
        scan_history
        ;;
esac

sorted_issues="$audit_temp/issues.sorted.tsv"
LC_ALL=C sort -u "$issues_file" > "$sorted_issues"

if [[ -n "$audit_report" ]]; then
    mkdir -p "${audit_report:h}"
    cp "$sorted_issues" "$audit_report"
fi

if [[ -s "$sorted_issues" ]]; then
    print -u2 "Public release audit failed:"
    while IFS=$'\t' read -r reason location; do
        printf -- '- %s: %s\n' "$reason" "$location" >&2
    done < "$sorted_issues"
    exit 1
fi

print "Public release audit passed ($audit_mode)."
