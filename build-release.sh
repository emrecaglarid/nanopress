#!/usr/bin/env bash
cd "$(dirname "$0")"
source ./script/setup.sh

build_version="0.0.0-SNAPSHOT"
# Unsigned: an ad-hoc signature. The Homebrew cask removes the quarantine flag on install, like AeroSpace's
codesign_identity="-"
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

#############
### BUILD ###
#############

./generate.sh
./script/check-uncommitted-files.sh
./generate.sh --build-version "$build_version" --codesign-identity "$codesign_identity" --generate-git-hash

swift_build_cli=(build -c release --arch arm64 --arch x86_64 --product nanopress)
swift "${swift_build_cli[@]}" # CLI
cli_bin_path="$(swift "${swift_build_cli[@]}" --show-bin-path)"

rm -rf .release && mkdir .release

cd ./xcode
    xcode_configuration="Release"
    xcodebuild -version
    xcodebuild-pretty ../.release/xcodebuild.log clean build \
        -scheme AeroSpace \
        -destination "generic/platform=macOS" \
        -configuration "$xcode_configuration" \
        -derivedDataPath .xcode-build
cd -

git checkout .

cp -r "xcode/.xcode-build/Build/Products/$xcode_configuration/nanopress.app" .release
cp -r "$cli_bin_path/nanopress" .release

################
### SIGN CLI ###
################

codesign -s "$codesign_identity" .release/nanopress

################
### VALIDATE ###
################

check-universal-binary() {
    if ! file "$1" | grep --fixed-string -q "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64"; then
        echo "$1 is not a universal binary"
        exit 1
    fi
}

check-contains-hash() {
    hash=$(git rev-parse HEAD)
    if ! strings "$1" | grep --fixed-string "$hash" > /dev/null; then
        echo "$1 doesn't contain $hash"
        exit 1
    fi
}

check-universal-binary .release/nanopress.app/Contents/MacOS/nanopress
check-universal-binary .release/nanopress

check-contains-hash .release/nanopress.app/Contents/MacOS/nanopress
check-contains-hash .release/nanopress

codesign -v .release/nanopress.app
codesign -v .release/nanopress

############
### PACK ###
############

release_dir="nanopress-v$build_version"
mkdir -p ".release/$release_dir" && cp -r ./legal ".release/$release_dir/legal"
cd .release
    mkdir -p "$release_dir/bin" && cp nanopress "$release_dir/bin"
    cp -r nanopress.app "$release_dir"
    zip -qr "$release_dir.zip" "$release_dir"
cd -

#################
### Brew Cask ###
#################

./script/build-brew-cask.sh --zip-file ".release/$release_dir.zip" --build-version "$build_version"

echo "Built .release/$release_dir.zip and .release/nanopress.rb"
