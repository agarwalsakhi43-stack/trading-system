#!/bin/bash
echo "🚀 Starting Trading System..."

# Step 1: Launch TradingView with debug port
echo "📈 Opening TradingView..."
/Applications/TradingView.app/Contents/MacOS/TradingView --remote-debugging-port=9222 &
sleep 5

# Step 2: Launch Claude Code
echo "🤖 Starting Claude Code..."
cd "/Users/sakhiagarwal/trading-system"
claude

