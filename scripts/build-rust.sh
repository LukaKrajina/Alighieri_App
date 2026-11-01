#!/usr/bin/env bash
# 编译 Rust 核心（alighieri_core）到各个目标平台
# ------------------------------------------------
# Flutter 的三端构建脚本会自动调用 cargo（见 linux/CMakeLists.txt、
# windows/CMakeLists.txt、android/app/build.gradle.kts）。
# 这个脚本用于**手工预编译** —— 交叉编译 Android 时尤其有用，
# 因为 Android 的 target 需要先 rustup 装好。
# 平时交给 Flutter 自动挡，这里留一根手动挡的杆。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

usage() {
  cat <<'EOF'
用法：scripts/build-rust.sh [host|android|all]

  host     只编当前平台（Linux -> .so，Windows -> .dll）
  android  为 arm64-v8a / armeabi-v7a / x86_64 各编一个 .so，
           并复制到 android/app/src/main/jniLibs/<abi>/
  all      两者都做

Android 前置条件（只需一次）：
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
EOF
}

build_host() {
  echo "==> 编译当前平台"
  (cd "$ROOT/rust" && cargo build --release)
  case "$(uname -s)" in
    Linux*) echo "  -> rust/target/release/libalighieri_core.so" ;;
    MINGW*|MSYS*|CYGWIN*) echo "  -> rust/target/release/alighieri_core.dll" ;;
  esac
}

build_android() {
  echo "==> 编译 Android"
  # shellcheck source=scripts/android-env.sh
  source "$ROOT/scripts/android-env.sh"
  local abis=(arm64-v8a:aarch64-linux-android armeabi-v7a:armv7-linux-androideabi x86_64:x86_64-linux-android)
  for pair in "${abis[@]}"; do
    local abi="${pair%%:*}" target="${pair##*:}"
    if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
      echo "  ! 跳过 $abi：没有安装 target $target（rustup target add $target）"
      continue
    fi
    echo "  -> $abi ($target)"
    (cd "$ROOT/rust" && cargo build --release --target "$target")
    mkdir -p "$ROOT/android/app/src/main/jniLibs/$abi"
    cp "$ROOT/rust/target/$target/release/libalighieri_core.so" \
       "$ROOT/android/app/src/main/jniLibs/$abi/libalighieri_core.so"
  done
}

case "${1:-host}" in
  host) build_host ;;
  android) build_android ;;
  all) build_host; build_android ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac