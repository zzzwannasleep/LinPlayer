#!/usr/bin/env bash
# 拉取项目级工具链到 .toolchain/(Windows x64)。已存在就跳过,可重复执行。
#
#   bash scripts/fetch-toolchain.sh
#
# 版本和 sha256 **写死在这里**。不写死的「项目级环境」等于没有 ——
# 换台机器拉到别的版本,产物就对不上,而这套东西的全部意义是可复现。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/.toolchain"
DL="$TC/dl"

# ---- 钉版本 ---------------------------------------------------------------
# Go:编核心层。Windows 上编 c-shared 必须 cgo,所以下面那个 C 编译器不是可选项。
GO_VER="1.27.0"
GO_ZIP="go${GO_VER}.windows-amd64.zip"
GO_URL="https://go.dev/dl/${GO_ZIP}"
GO_SHA="f0c0a0d33ba94f4d2c5dbc887334ce678b21813504ddb3aafcb06e60a5a667c4"

# zig:当 cgo 的 C 编译器。选它而不是 mingw 的两个理由:
#   ① 一个包同时能当 Windows 和 Linux 的 cc(核心层要出三平台产物)
#   ② 官方发布带 sha256 且是纯 zip(w64devkit 只有自解压 exe 且不发校验和)
ZIG_VER="0.16.0"
ZIG_ZIP="zig-x86_64-windows-${ZIG_VER}.zip"
ZIG_URL="https://ziglang.org/download/${ZIG_VER}/${ZIG_ZIP}"
ZIG_SHA="68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e"
ZIG_DIR="zig-x86_64-windows-${ZIG_VER}"

# 安卓的 C 编译器不在这里 —— 用已装的 NDK clang(见 scripts/build-android-apk.sh)。
# Linux 侧要用时在这里补一份 linux-amd64 的 URL 与 sha256,**别抄未经下载校验的常量**。

fetch() { # $1=url $2=文件名 $3=期望 sha256
  local out="$DL/$2"
  if [ -f "$out" ] && [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$3" ]; then
    echo "  已有且校验通过: $2"; return
  fi
  echo "  下载 $2 …"
  curl -fsSL -o "$out" "$1"
  local got; got="$(sha256sum "$out" | cut -d' ' -f1)"
  if [ "$got" != "$3" ]; then
    echo "  !! sha256 不符"; echo "     期望 $3"; echo "     实得 $got"
    rm -f "$out"; exit 1
  fi
  echo "  校验通过: $2"
}

mkdir -p "$DL"

echo "== Go $GO_VER =="
if [ -x "$TC/go/bin/go.exe" ]; then
  echo "  已解压,跳过"
else
  fetch "$GO_URL" "$GO_ZIP" "$GO_SHA"
  unzip -q "$DL/$GO_ZIP" -d "$TC"
fi

echo "== zig $ZIG_VER(cgo 的 C 编译器)=="
if [ -x "$TC/zig/zig.exe" ]; then
  echo "  已解压,跳过"
else
  fetch "$ZIG_URL" "$ZIG_ZIP" "$ZIG_SHA"
  unzip -q "$DL/$ZIG_ZIP" -d "$TC"
  mv "$TC/$ZIG_DIR" "$TC/zig"
fi

# 遥测关掉:它默认往**用户配置目录**写计数文件。GOENV 已被 env.sh 指到项目里,
# 所以这句写的是项目自己的 goenv,不碰系统。
( source "$ROOT/scripts/env.sh" && go telemetry off )

echo
echo "完成。激活:  source scripts/env.sh   (PowerShell: . .\\scripts\\env.ps1)"
echo "校验:        bash scripts/check-toolchain.sh"
