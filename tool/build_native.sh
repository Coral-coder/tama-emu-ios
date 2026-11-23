#!/bin/sh
# Builds native/tama_core (the Capybara Paradise emulator with its C ABI) for the app.
#   tool/build_native.sh android   -> android/app/src/main/jniLibs/<abi>/libtama_core.so (needs cargo-ndk, ANDROID_NDK_HOME)
#   tool/build_native.sh ios       -> native/tama_core/target/aarch64-apple-ios/release/libtama_core.a (linked by Xcode)
#   tool/build_native.sh watchos   -> native/tama_core/target/watchos/libtama_core.a (arm64_32 + arm64; nightly, build-std)
#   tool/build_native.sh host      -> native/tama_core/target/release/libtama_core.so (tests on the computer)
set -e
cd "$(dirname "$0")/.."
[ -f third_party/capybara/src/emulator/mod.rs ] || git submodule update --init third_party/capybara
cd native/tama_core
# the natively compiled blocks of the built-in ROMs, when tool/aot_gen.sh made them
FEAT=""
[ -f src/aot_gen/blocks.rs ] && FEAT="--features aot" && echo "native blocks: compiled in"
case "$1" in
  android)
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android >/dev/null
    cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 24 -o ../../android/app/src/main/jniLibs build --release --lib $FEAT
    ls -l ../../android/app/src/main/jniLibs/*/ ;;
  ios)
    rustup target add aarch64-apple-ios >/dev/null
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo rustc --release --lib $FEAT --target aarch64-apple-ios --crate-type staticlib
    ls -l target/aarch64-apple-ios/release/libtama_core.a ;;
  watchos)
    # The watchOS targets are tier 3: built with nightly and the standard library from source.
    rustup toolchain install nightly --profile minimal --component rust-src >/dev/null
    out=target/watchos
    mkdir -p $out
    libs=""
    for t in arm64_32-apple-watchos aarch64-apple-watchos; do
      WATCHOS_DEPLOYMENT_TARGET=9.0 cargo +nightly rustc -Z build-std=std,panic_abort --release --lib $FEAT --target $t --crate-type staticlib
      libs="$libs target/$t/release/libtama_core.a"
    done
    lipo -create $libs -output $out/libtama_core.a
    lipo -info $out/libtama_core.a ;;
  host)
    cargo build --release --lib $FEAT
    ls -l target/release/libtama_core.so ;;
  *) echo "usage: $0 android|ios|watchos|host"; exit 1 ;;
esac
