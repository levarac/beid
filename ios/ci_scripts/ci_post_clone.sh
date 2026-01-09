#!/bin/sh

#  ci_post_clone.sh
#  Xcode Cloud post-clone script for Flutter project

# Fail this script if any subcommand fails.
set -e

# The default execution directory of this script is the ci_scripts directory.
cd $CI_PRIMARY_REPOSITORY_PATH # change working directory to the root of your cloned repo.

# --------------------------------------------------
# 1. Set Development Team ID for Xcode Cloud builds
# --------------------------------------------------
# TEAM_ID is set via Xcode Cloud environment variable or workflow settings
if [ -n "$CI_TEAM_ID" ]; then
    PROJECT_FILE="$CI_PRIMARY_REPOSITORY_PATH/ios/Runner.xcodeproj/project.pbxproj"
    if [ -f "$PROJECT_FILE" ]; then
        echo "🔵 Setting DEVELOPMENT_TEAM to $CI_TEAM_ID"
        sed -i '' "s/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = $CI_TEAM_ID;/g" "$PROJECT_FILE"
        echo "Team ID updated successfully"
    fi
else
    echo "⚠️ CI_TEAM_ID not set, using Xcode Cloud workflow settings"
fi

# --------------------------------------------------
# 2. Flutter Setup
# --------------------------------------------------
flutter_version=`grep '^flutter ' ./.tool-versions | head -n 1 | awk '{print $2}' | sed 's/-stable//'`
echo "Flutter version: `echo $flutter_version`"

echo "🔵 flutter download"
git clone https://github.com/flutter/flutter.git -b $flutter_version --depth 1 --single-branch $HOME/flutter

export PATH="$PATH:$HOME/flutter/bin"

echo "🔵 flutter setup"
flutter doctor
echo "🟡 flutter precache --ios"
flutter precache --ios --no-android --no-linux --no-macos --no-windows --no-web
echo "🟡 flutter pub get"
flutter pub get

# Run build_runner to generate code files
echo "🔵 Running build_runner"
flutter pub run build_runner build --delete-conflicting-outputs

# --------------------------------------------------
# 3. CocoaPods Setup
# --------------------------------------------------
# Install CocoaPods using Homebrew.
export HOMEBREW_NO_AUTO_UPDATE=1 # disable homebrew's automatic updates.
echo "🔵 install cocoapods"
brew install cocoapods

echo "🔵 pod install"
cd ios && pod install # run `pod install` in the `ios` directory.

cd $CI_PRIMARY_REPOSITORY_PATH

# --------------------------------------------------
# 4. Generate iOS build configuration
# --------------------------------------------------
echo "🔵 flutter build ios --config-only"
flutter build ios --config-only --release

exit 0
