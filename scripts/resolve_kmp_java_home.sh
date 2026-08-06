#!/bin/sh

set -eu

is_jdk_major() {
    candidate="$1"
    expected_major="$2"
    [ -x "$candidate/bin/java" ] || return 1

    version_line="$("$candidate/bin/java" -version 2>&1 | sed -n '1p')"
    case "$version_line" in
        *\"$expected_major.*) return 0 ;;
        *) return 1 ;;
    esac
}

is_supported_local_jdk() {
    is_jdk_major "$1" 17 || is_jdk_major "$1" 21
}

homebrew_jdk_17_arm64="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
homebrew_jdk_17_x86_64="/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"

# Xcode Cloud runners must use the JDK installed at a deterministic Homebrew
# path. In particular, do not accept an arbitrary override or ambient JDK.
if [ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || [ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
    for candidate in "$homebrew_jdk_17_arm64" "$homebrew_jdk_17_x86_64"
    do
        if is_jdk_major "$candidate" 17; then
            printf '%s\n' "$candidate"
            exit 0
        fi
    done

    echo "error: Xcode Cloud requires Homebrew OpenJDK 17 at a fixed path." >&2
    exit 1
fi

if [ -n "${KMP_JAVA_HOME:-}" ]; then
    if is_supported_local_jdk "$KMP_JAVA_HOME"; then
        printf '%s\n' "$KMP_JAVA_HOME"
        exit 0
    fi

    echo "error: KMP_JAVA_HOME must point to JDK 17 or 21." >&2
    exit 1
fi

android_studio_jbr="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
if is_jdk_major "$android_studio_jbr" 21; then
    printf '%s\n' "$android_studio_jbr"
    exit 0
fi

for candidate in "$homebrew_jdk_17_arm64" "$homebrew_jdk_17_x86_64"
do
    if is_jdk_major "$candidate" 17; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

java_17_home="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
if [ -n "$java_17_home" ] && is_jdk_major "$java_17_home" 17; then
    printf '%s\n' "$java_17_home"
    exit 0
fi

echo "error: KMP requires an explicit JDK 17 or Android Studio JBR 21; ambient JAVA_HOME is not used." >&2
exit 1
