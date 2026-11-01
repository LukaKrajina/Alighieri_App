#!/usr/bin/env bash
# 定位 Android NDK，并把交叉编译需要的东西放进当前 shell。
#
#   source scripts/android-env.sh
#   cargo build --release --target aarch64-linux-android
#
# 支持 ANDROID_NDK_HOME / ANDROID_NDK_ROOT / ANDROID_HOME / ANDROID_SDK_ROOT，
# 也会检查常见的用户级 SDK 路径。必须用 `source` 执行，
# 否则变量全留在子 shell 里，exit 之后等于白忙。

_alighieri_find_ndk() {
  local candidate
  for candidate in \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "${ANDROID_HOME:+$ANDROID_HOME/ndk/28.2.13676358}" \
    "${ANDROID_SDK_ROOT:+$ANDROID_SDK_ROOT/ndk/28.2.13676358}" \
    "$HOME/Android/Sdk/ndk/28.2.13676358" \
    "/opt/android-sdk/ndk/28.2.13676358"; do
    if [ -n "$candidate" ] && [ -d "$candidate/toolchains/llvm/prebuilt" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  # 没有精确版本时，取 SDK 里最新的 NDK，也就是版本号最大的那个。
  for candidate in \
    "${ANDROID_HOME:-$HOME/Android/Sdk}" \
    "${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}" \
    "/opt/android-sdk"; do
    if [ -d "$candidate/ndk" ]; then
      local newest
      newest="$(find "$candidate/ndk" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
      if [ -n "$newest" ] && [ -d "$candidate/ndk/$newest/toolchains/llvm/prebuilt" ]; then
        printf '%s\n' "$candidate/ndk/$newest"
        return 0
      fi
    fi
  done
  return 1
}

if ! _alighieri_find_ndk >/dev/null; then
  echo "android-env: 找不到 Android NDK。请设置 ANDROID_NDK_HOME 或安装 NDK 28.2.13676358。" >&2
  return 1 2>/dev/null || exit 1
fi

ANDROID_NDK_HOME="$(_alighieri_find_ndk)"
export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"

_ndk_prebuilt="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt"
_ndk_bin="$(find "$_ndk_prebuilt" -mindepth 1 -maxdepth 1 -type d | head -1)/bin"
if [ ! -d "$_ndk_bin" ]; then
  echo "android-env: NDK 里没有 clang 工具链：$_ndk_prebuilt" >&2
  return 1 2>/dev/null || exit 1
fi
export PATH="$_ndk_bin:$PATH"

# cc-rs（ring 等 C 依赖）用这些变量找交叉编译器；名字不好看，但这是它认的暗号。
export CC_aarch64_linux_android="$_ndk_bin/aarch64-linux-android24-clang"
export AR_aarch64_linux_android="$_ndk_bin/llvm-ar"
export CC_armv7_linux_androideabi="$_ndk_bin/armv7a-linux-androideabi24-clang"
export AR_armv7_linux_androideabi="$_ndk_bin/llvm-ar"
export CC_x86_64_linux_android="$_ndk_bin/x86_64-linux-android24-clang"
export AR_x86_64_linux_android="$_ndk_bin/llvm-ar"

unset _ndk_prebuilt _ndk_bin