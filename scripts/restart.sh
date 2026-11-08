#!/bin/bash
echo "🔄 正在关闭旧版本并重启 SysPulse..."
killall -9 SysPulse 2>/dev/null || true
sleep 0.5
open "$(cd "$(dirname "$0")/.." && pwd)/../build/SysPulse.app"
echo "✅ 已启动全新原生状态栏版本！"
