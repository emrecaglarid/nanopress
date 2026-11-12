#!/usr/bin/env bash
cd "$(dirname "$0")"
source ./script/setup.sh

./generate.sh --ignore-xcodeproj
swift build --build-tests "$@"

rm -rf .debug && mkdir .debug
cp -r .build/debug/nanopress .debug
cp -r .build/debug/NanopressApp .debug
