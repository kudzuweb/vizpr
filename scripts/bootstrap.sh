#!/usr/bin/env bash
# Generate the Xcode project from project.yml and resolve pinned dependencies.
# Run once after cloning, and again whenever project.yml changes.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! which xcodegen >/dev/null; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

echo "Generating Vizpr.xcodeproj from project.yml ..."
xcodegen generate

echo "Resolving pinned Swift package dependencies ..."
xcodebuild -resolvePackageDependencies -project Vizpr.xcodeproj -scheme Vizpr >/dev/null

echo "Done. Open Vizpr.xcodeproj or build with:"
echo "  xcodebuild -project Vizpr.xcodeproj -scheme Vizpr -configuration Debug build"
