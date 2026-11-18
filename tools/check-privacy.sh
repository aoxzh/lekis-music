#!/bin/sh
# 提交前的隐私自检（可提交版：只做通用检查，不包含任何本地私有文件名）。
#
# 检查暂存内容里有没有不该进公开仓库的东西：
#   · 本机的绝对路径（Windows / macOS / Linux 的家目录）
#   · 邮箱、GitHub Token、私钥、疑似 API Key
#   · 常见的证书 / 密钥文件名
#
# 用法：
#   tools/check-privacy.sh          检查暂存区（pre-commit 会自动调用）
#   tools/check-privacy.sh --tree   检查当前 HEAD 里的全部文件
#   tools/check-privacy.sh --range  main..HEAD   检查一段提交范围
#
# 误报时用 SKIP_PRIVACY_CHECK=1 git commit ... 跳过，但要想清楚。
# 仓库还会在本地 pre-commit 里追加一层"私有目录不得提交"的检查（不在仓库中）。

set -u

mode="${1:-staged}"

if [ "${SKIP_PRIVACY_CHECK:-0}" = "1" ]; then
    echo "隐私检查已跳过（SKIP_PRIVACY_CHECK=1）" >&2
    exit 0
fi

# 匹配规则：本机路径 + 凭据。宁可误报也不要漏。
PATTERN='C:\\\\?Users\\\\?|/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|\\\\Users\\\\[A-Za-z0-9._-]+\\\\|[A-Za-z0-9._%+-]+@(gmail|qq|outlook|hotmail|163|126|foxmail)\.[A-Za-z]{2,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-[A-Za-z0-9]{24,}|AKIA[0-9A-Z]{16}'

BAD_NAMES='(^|/)\.env$|(^|/)local\.properties$|\.(jks|keystore|p12|pfx|mobileprovision)$|(^|/)id_(rsa|ed25519|ecdsa)$'

fail=0

report() {
    echo "✗ 隐私检查失败：$1" >&2
    shift
    printf '%s\n' "$@" | head -20 >&2
    fail=1
}

case "$mode" in
    --tree)
        files=$(git ls-files)
        ;;
    --range)
        range="${2:-HEAD~1..HEAD}"
        files=$(git diff --name-only --diff-filter=ACMR "$range")
        ;;
    *)
        files=$(git diff --cached --name-only --diff-filter=ACMR)
        ;;
esac

if [ -z "$files" ]; then
    exit 0
fi

bad=$(printf '%s\n' "$files" | grep -Ei "$BAD_NAMES" || true)
[ -n "$bad" ] && report "疑似密钥或凭据文件" $bad

text_files=$(printf '%s\n' "$files" | grep -Eiv '\.(png|jpe?g|gif|webp|ico|icns|bmp|jar|so|dll|dylib|a|lib|exe|apk|aab|zip|gz|zst|7z|ttf|otf|woff2?|mp[34]|flac|wav|ogg|opus)$' || true)

for f in $text_files; do
    # 只检查暂存/目标版本的内容
    case "$mode" in
        --range) content=$(git show "${2:-HEAD~1..HEAD}:$f" 2>/dev/null) ;;
        --tree)  content=$(git show "HEAD:$f" 2>/dev/null) ;;
        *)       content=$(git show ":$f" 2>/dev/null) ;;
    esac
    [ -z "$content" ] && continue
    hit=$(printf '%s\n' "$content" | grep -Eni "$PATTERN" || true)
    if [ -n "$hit" ]; then
        echo "  $f:" >&2
        printf '%s\n' "$hit" | sed 's/^/    /' | head -5 >&2
        fail=1
    fi
done

if [ "$fail" = "1" ]; then
    echo "" >&2
    echo "请修正后重试；确认是误报可以设置 SKIP_PRIVACY_CHECK=1 跳过。" >&2
    exit 1
fi

exit 0
