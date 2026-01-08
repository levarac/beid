#!/bin/sh

#  ci_post_clone.sh
#  Xcode Cloud post-clone script for Flutter project

# Fail this script if any subcommand fails.
set -e

echo "====================================="
echo "Running ci_post_clone.sh"
echo "====================================="

# The default execution directory of this script is the ci_scripts directory.
cd $CI_PRIMARY_REPOSITORY_PATH # change working directory to the root of your cloned repo.

# --------------------------------------------------
# 1. Set Development Team ID for Xcode Cloud builds
# --------------------------------------------------
TEAM_ID="4WQE792998"
PROJECT_FILE="$CI_PRIMARY_REPOSITORY_PATH/ios/Runner.xcodeproj/project.pbxproj"

if [ -f "$PROJECT_FILE" ]; then
    echo "Setting DEVELOPMENT_TEAM to $TEAM_ID"
    sed -i '' "s/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = $TEAM_ID;/g" "$PROJECT_FILE"
    echo "Team ID updated successfully"
fi

# --------------------------------------------------
# 2. Flutter Setup
# --------------------------------------------------
flutter_version=$(cat ./.tool-versions | sed -nre 's/^[^0-9]*(([0-9]+\.)*[0-9]+(-([0-9]+\.)*[0-9a-zA-Z]+)?).*/\1/p' | sed 's/-stable//')
echo "Flutter version: $flutter_version"

echo "Downloading Flutter..."
git clone https://github.com/flutter/flutter.git -b $flutter_version --depth 1 $HOME/flutter

export PATH="$PATH:$HOME/flutter/bin"

echo "Running flutter doctor..."
flutter doctor

echo "Running flutter precache --ios..."
flutter precache --ios

echo "Running flutter pub get..."
flutter pub get

# --------------------------------------------------
# 3. CocoaPods Setup
# --------------------------------------------------
# Install CocoaPods using Homebrew.
HOMEBREW_NO_AUTO_UPDATE=1 # disable homebrew's automatic updates.
echo "Installing CocoaPods..."
brew install cocoapods

echo "Running pod install..."
cd ios && pod install

echo "====================================="
echo "ci_post_clone.sh completed"
echo "====================================="

exit 0
