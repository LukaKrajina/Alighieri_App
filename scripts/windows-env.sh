#!/usr/bin/env bash
# 配置 Rust -> Windows (x86_64-pc-windows-gnu) 的交叉编译环境。
#
#   source scripts/windows-env.sh
#   cd rust && cargo build --release --target x86_64-pc-windows-gnu
#
# 工具链位于 ~/.local/opt/mingw-w64（Arch 的 mingw-w64 包解压，无需 root）。
# 也可以用 MINGW_ROOT 指向其它 MinGW 前缀。
#
# 这儿得注意，这里只生成 Rust DLL。Flutter 的 Windows 桌面壳仍然必须在 Windows
# 上构建（Linux 上的 flutter tool 不提供 Windows 引擎和 MSVC 构建链）。
# 别指望这台 Linux 顺手把整个 App 也变出来。

MINGW_ROOT="${MINGW_ROOT:-$HOME/.local/opt/mingw-w64/usr}"

if [ ! -x "$MINGW_ROOT/bin/x86_64-w64-mingw32-gcc" ]; then
  echo "windows-env: 找不到 $MINGW_ROOT/bin/x86_64-w64-mingw32-gcc。" >&2
  echo "  安装方法见 README 的 Windows 交叉编译一节。" >&2
  return 1 2>/dev/null || exit 1
fi

export PATH="$MINGW_ROOT/bin:$PATH"
export CC_x86_64_pc_windows_gnu="$MINGW_ROOT/bin/x86_64-w64-mingw32-gcc"
export AR_x86_64_pc_windows_gnu="$MINGW_ROOT/bin/x86_64-w64-mingw32-ar"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$MINGW_ROOT/bin/x86_64-w64-mingw32-gcc"
export MINGW_ROOT