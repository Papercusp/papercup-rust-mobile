#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Resolve a Java runtime suitable for the Android Gradle Plugin.
#
# Explicit JAVA_HOME wins when it points at Java 17+. Otherwise discover an
# Android Studio JBR from the current or versioned install (including Snap),
# then fall back to the ambient java. The candidate override/search-root
# variables are deterministic seams for the shell regression test.
set -euo pipefail

MIN_JAVA_MAJOR="${PAPERCUP_MIN_JAVA_MAJOR:-17}"
if ! [[ "$MIN_JAVA_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PAPERCUP_MIN_JAVA_MAJOR must be an integer, got '$MIN_JAVA_MAJOR'." >&2
    exit 2
fi

declare -a CANDIDATES=()
declare -A SEEN=()
declare -A DIAGNOSTICS=()

add_candidate() {
    local candidate="${1:-}"
    [[ -n "$candidate" ]] || return 0
    candidate="${candidate%/}"
    [[ -n "$candidate" ]] || candidate="/"
    [[ -n "${SEEN[$candidate]+yes}" ]] && return 0
    SEEN["$candidate"]=1
    CANDIDATES+=("$candidate")
}

add_java_bin_home() {
    local java_bin="${1:-}"
    [[ -n "$java_bin" ]] || return 0
    local resolved
    resolved="$(readlink -f "$java_bin" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || resolved="$java_bin"
    add_candidate "$(cd "$(dirname "$resolved")/.." 2>/dev/null && pwd -P || true)"
}

discover_from_root() {
    local root="$1"
    [[ -d "$root" ]] || return 0

    # The explicit paths cover the stable Android Studio layouts and the Snap
    # `current` link; find covers numbered Snap revisions and Toolbox installs.
    local jbr
    for jbr in "$root/jbr" "$root/current/jbr"; do
        [[ -x "$jbr/bin/java" ]] && add_candidate "$jbr"
    done
    while IFS= read -r -d '' jbr; do
        [[ -x "$jbr/bin/java" ]] && add_candidate "$jbr"
    done < <(find "$root" -type d -name jbr -print0 2>/dev/null)
}

if [[ -n "${JAVA_HOME:-}" ]]; then
    add_candidate "$JAVA_HOME"
fi
if [[ -n "${ANDROID_STUDIO_JBR:-}" ]]; then
    add_candidate "$ANDROID_STUDIO_JBR"
fi

if [[ -n "${PAPERCUP_JAVA_CANDIDATES:-}" ]]; then
    IFS=: read -r -a override_candidates <<< "$PAPERCUP_JAVA_CANDIDATES"
    for candidate in "${override_candidates[@]}"; do
        add_candidate "$candidate"
    done
else
    if [[ -n "${PAPERCUP_JAVA_SEARCH_ROOTS:-}" ]]; then
        IFS=: read -r -a search_roots <<< "$PAPERCUP_JAVA_SEARCH_ROOTS"
    else
        search_roots=(
            /snap/android-studio
            /opt/android-studio
            /usr/local/android-studio
            "$HOME/android-studio"
            "$HOME/.local/share/JetBrains/Toolbox/apps/AndroidStudio"
        )
    fi
    for root in "${search_roots[@]}"; do
        discover_from_root "$root"
    done
fi

if [[ "${PAPERCUP_SKIP_AMBIENT_JAVA:-0}" != "1" ]]; then
    ambient_java="$(command -v java 2>/dev/null || true)"
    [[ -n "$ambient_java" ]] && add_java_bin_home "$ambient_java"
fi

validate_candidate() {
    local candidate="$1"
    local java_bin="$candidate/bin/java"
    if [[ ! -x "$java_bin" ]]; then
        DIAGNOSTICS["$candidate"]='missing executable bin/java'
        return 1
    fi

    local version_output status=0 major one_line
    version_output="$($java_bin -version 2>&1)" || status=$?
    major="$(printf '%s\n' "$version_output" | sed -nE \
        -e 's/.*version "([0-9]+)(\.[0-9]+)?.*/\1/p' \
        -e 's/.*openjdk[[:space:]]+([0-9]+).*/\1/p' \
        -e 's/.*java[[:space:]]+([0-9]+).*/\1/p' | head -n 1)"
    one_line="$(printf '%s' "$version_output" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-180)"

    if (( status == 0 )) && [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_JAVA_MAJOR )); then
        return 0
    fi
    if [[ -n "$major" ]]; then
        DIAGNOSTICS["$candidate"]="Java major $major is below $MIN_JAVA_MAJOR${one_line:+ ($one_line)}"
    else
        DIAGNOSTICS["$candidate"]="could not read a Java version${one_line:+ ($one_line)}"
    fi
    return 1
}

for candidate in "${CANDIDATES[@]}"; do
    if validate_candidate "$candidate"; then
        printf '%s\n' "$(cd "$candidate" && pwd -P)"
        exit 0
    fi
done

echo "ERROR: no Java ${MIN_JAVA_MAJOR}+ runtime was found for Android Gradle." >&2
if ((${#CANDIDATES[@]} == 0)); then
    echo 'Checked no candidates: set JAVA_HOME or install Android Studio with its bundled JBR.' >&2
else
    echo 'Candidates checked:' >&2
    for candidate in "${CANDIDATES[@]}"; do
        echo "  - $candidate: ${DIAGNOSTICS[$candidate]}" >&2
    done
fi
echo 'Set JAVA_HOME to a Java 17+ installation, or install Android Studio/JBR.' >&2
exit 1
