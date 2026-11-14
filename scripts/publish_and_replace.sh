#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"

APP_NAME="QuotioPlus"
TARGET_APP="/Applications/${APP_NAME}.app"
BACKUP_APP="/Applications/${APP_NAME}.app.bak"

echo "=========================================="
echo " QuotioPlus 1.1.2 发布与本机替换"
echo "=========================================="

# 1. 运行核心定向测试
echo "==> 步骤 1/4: 执行定向测试..."
xcodebuild test -scheme "${APP_NAME}" \
    -only-testing:QuotioPlusTests/ClientAnalyticsOverviewTests \
    -only-testing:QuotioPlusTests/ClientAnalyticsDailyTrendTests \
    -only-testing:QuotioPlusTests/UsageHeatmapPresentationTests \
    -only-testing:QuotioPlusTests/OpenAIProtocolRoutingTests 2>&1 | tail -n 25

# 2. 构建 Release 产物
echo "==> 步骤 2/4: 构建 Release 应用与安装包..."
"${PROJECT_DIR}/scripts/build_dmg.sh"

BUILT_APP="${PROJECT_DIR}/build/${APP_NAME}.app"
if [ ! -d "${BUILT_APP}" ]; then
    echo "错误: 未找到构建生成的 ${BUILT_APP}" >&2
    exit 1
fi

# 3. 替换本机应用
echo "==> 步骤 3/4: 替换本机应用 (${TARGET_APP})..."
if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "正在停止运行中的 ${APP_NAME}..."
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
fi

if [ -d "${TARGET_APP}" ]; then
    echo "备份现有应用至 ${BACKUP_APP}..."
    rm -rf "${BACKUP_APP}"
    mv "${TARGET_APP}" "${BACKUP_APP}"
fi

echo "安装新版本至 ${TARGET_APP}..."
cp -R "${BUILT_APP}" "${TARGET_APP}"
xattr -cr "${TARGET_APP}" 2>/dev/null || true

echo "启动新安装的 ${APP_NAME}..."
open "${TARGET_APP}"
sleep 1.5

if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "成功: ${APP_NAME} 已在本机启动运行！"
    rm -rf "${BACKUP_APP}"
else
    echo "警告: ${APP_NAME} 启动后未检测到活动进程，恢复备份..."
    if [ -d "${BACKUP_APP}" ]; then
        rm -rf "${TARGET_APP}"
        mv "${BACKUP_APP}" "${TARGET_APP}"
        open "${TARGET_APP}"
    fi
    exit 1
fi

echo "==> 步骤 4/5: 提交更改并推送至 GitHub..."
git add -A
COMMIT_MSG="release: 发布 QuotioPlus 1.1.2 构建 1.1.2.1 [skip ci]

- 客户端调用统计优化与去 Token 化：移除“未调用技能”标签，聚焦四项核心调用指标。
- 修复 KeychainHelper Swift 6 并发安全隔离错误与后台凭据访问安全性。
- 完善 OpenAI 官方 responses 协议路由分发与上游拓扑实时感知。
- 校准分析看板热力图展示边界与客户端调用日趋势统计。
- 升级版本为 1.1.2（构建 1.1.2.1），更新 CHANGELOG 及发行说明。

Co-Authored-By: Claude Code <noreply@anthropic.com>"

git commit -m "${COMMIT_MSG}" || true
git tag -f -a "v1.1.2" -m "QuotioPlus 1.1.2"
git push origin master
git push origin "v1.1.2" --force

echo "==> 步骤 5/5: 升级、发布与本机替换全部完成！"
