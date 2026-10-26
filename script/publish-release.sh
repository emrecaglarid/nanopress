#!/usr/bin/env bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

# Builds a release, tags it, and puts the cask into a clone of https://github.com/emrecaglarid/homebrew-tap

build_version=""
tap_git_repo_path=""
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --tap-git-repo-path) tap_git_repo_path="$2"; shift 2;;
        *) echo "Unknown option $1"; exit 1;;
    esac
done

if test -z "$build_version"; then
    echo "--build-version flag is mandatory" > /dev/stderr
    exit 1
fi

if ! test -d "$tap_git_repo_path"; then
    echo "--tap-git-repo-path is a mandatory flag that must point to a clone of emrecaglarid/homebrew-tap" > /dev/stderr
    exit 1
fi

./build-release.sh --build-version "$build_version"

git tag -a "v$build_version" -m "v$build_version" && git push git@github.com:emrecaglarid/nanopress.git "v$build_version"
link="https://github.com/emrecaglarid/nanopress/releases/new?tag=v$build_version"
open "$link" || { echo "$link"; exit 1; }
sleep 1
open -R "./.release/nanopress-v$build_version.zip"

echo "Upload the .zip to the GitHub release, publish it, then hit Enter"
read -r

mkdir -p "$tap_git_repo_path/Casks"
cp .release/nanopress.rb "$tap_git_repo_path/Casks/nanopress.rb"
echo "Copied the cask to $tap_git_repo_path/Casks/nanopress.rb. Commit and push it to publish"
