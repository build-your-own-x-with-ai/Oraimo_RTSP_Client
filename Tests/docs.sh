#!/bin/bash
# 校验文档里的 Mermaid 图能不能渲染。
#
# 起因：交互图提交出去之后 VS Code 预览直接报解析错误 —— 分号在 Mermaid 里是
# 语句分隔符，写进消息文本就把语句截断了。这种错误肉眼扫不出来，得让真正的
# 解析器过一遍。
#
# 用 VS Code 自带的那份 mermaid（见 MermaidCheck/validate.mjs 里的理由）。
# 找不到 VS Code 或找不到够新的 node 就跳过，不假报通过 —— 这台机器上没法
# 验，和验过了是两件事。

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# --- 找 mermaid bundle：按 glob 找，不写死文件名哈希（VS Code 一升级就变） ---
BUNDLE=""
for base in \
    "/Applications/Visual Studio Code.app" \
    "/Applications/Visual Studio Code - Insiders.app" \
    "$HOME/Applications/Visual Studio Code.app"; do
    d="$base/Contents/Resources/app/extensions/markdown-language-features/markdown-editor-out"
    if compgen -G "$d/mermaid.core-*.js" > /dev/null 2>&1; then
        BUNDLE="$d"
        break
    fi
done

if [ -z "$BUNDLE" ]; then
    echo "跳过：找不到 VS Code 自带的 mermaid bundle。"
    echo "      装了 VS Code 才能跑这项检查（用的就是编辑器预览那份解析器）。"
    exit 0
fi

# --- 找 node ≥ 18：mermaid 11 用到的语法更老的版本读不了 ---
NODE=""
pick_node() {
    local p="$1"
    [ -x "$p" ] || return 1
    local v
    v=$("$p" -v 2>/dev/null) || return 1
    v=${v#v}; v=${v%%.*}
    [ -n "$v" ] && [ "$v" -ge 18 ] 2>/dev/null
}

for cand in \
    "$(command -v node 2>/dev/null || true)" \
    /usr/local/bin/node \
    /opt/homebrew/bin/node; do
    [ -n "$cand" ] || continue
    if pick_node "$cand"; then NODE="$cand"; break; fi
done

# 常见的多版本管理目录，取版本号最大的那个
if [ -z "$NODE" ]; then
    while IFS= read -r cand; do
        if pick_node "$cand"; then NODE="$cand"; break; fi
    done < <(ls -d "$HOME"/.vite-plus/js_runtime/node/*/bin/node \
                   "$HOME"/.nvm/versions/node/*/bin/node \
                   "$HOME"/.volta/tools/image/node/*/bin/node 2>/dev/null | sort -Vr)
fi

if [ -z "$NODE" ]; then
    echo "跳过：找不到 node ≥ 18（mermaid 11 读不了更老的版本）。"
    exit 0
fi

echo "mermaid bundle：${BUNDLE}"
# 花括号是必须的：$NODE（ 里的全角括号首字节会被 bash 3.2 算进变量名，
# 报成 NODE\xef: unbound variable，很难看出是标点的问题。
echo "node：${NODE}（$("$NODE" -v)）"
echo

# 仓库里所有 markdown 都过一遍，新增文档自动纳入。
# 不用 mapfile —— 那是 bash 4+ 的，macOS 自带的是 3.2。
DOCS=()
while IFS= read -r f; do
    [ -n "$f" ] && DOCS+=("$REPO/$f")
done < <(cd "$REPO" && git ls-files '*.md' 2>/dev/null)

if [ ${#DOCS[@]} -eq 0 ]; then
    DOCS=("$REPO/Docs/RTSPFlow.md" "$REPO/Tests/README.md")
fi

exec "$NODE" "$HERE/MermaidCheck/validate.mjs" "$BUNDLE" "${DOCS[@]}"
