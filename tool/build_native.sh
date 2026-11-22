#!/bin/sh
# Builds native/tama_core (the Capybara Paradise emulator with its C ABI) for the app.
#   tool/build_native.sh android   -> android/app/src/main/jniLibs/<abi>/libtama_core.so (needs cargo-ndk, ANDROID_NDK_HOME)
#   tool/build_native.sh ios       -> native/tama_core/target/aarch64-apple-ios/release/libtama_core.a (linked by Xcode)
#   tool/build_native.sh host      -> native/tama_core/target/release/libtama_core.so (tests on the computer)
set -e
cd "$(dirname "$0")/.."
[ -f third_party/capybara/src/emulator/mod.rs ] || git submodule update --init third_party/capybara
cd native/tama_core
case "$1" in
  android)
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android >/dev/null
    cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 24 -o ../../android/app/src/main/jniLibs build --release --lib
    ls -l ../../android/app/src/main/jniLibs/*/ ;;
  ios)
    rustup target add aarch64-apple-ios >/dev/null
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo rustc --release --lib --target aarch64-apple-ios --crate-type staticlib
    ls -l target/aarch64-apple-ios/release/libtama_core.a ;;
  host)
    cargo build --release --lib
    ls -l target/release/libtama_core.so ;;
  *) echo "usage: $0 android|ios|host"; exit 1 ;;
esac
