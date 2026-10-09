#!/bin/bash
# Claude Code 状态栏脚本：把订阅额度写成桌宠能读的通用格式。
# Claude Code 每次刷新状态栏都会把会话信息（JSON）从标准输入传进来，
# 其中 rate_limits.five_hour / seven_day 只有 Pro / Max 订阅、并且本会话已经回答过一次后才有。
# 写到 ~/.pet-quota/claude.json；格式说明见 docs/额度来源.md。
input=$(cat)
dir="$HOME/.pet-quota"
mkdir -p "$dir"
date +%s > "$dir/.claude-statusline-ran"          # 只用来确认脚本确实被运行过
if echo "$input" | jq -e '.rate_limits.five_hour // .rate_limits.seven_day' >/dev/null 2>&1; then
  echo "$input" | jq --arg now "$(date +%s)" '{
      name: "Claude",
      updated_at: ($now | tonumber),
      windows: ([
        (.rate_limits.five_hour | select(.) | {label: "5 小时", used_percent: .used_percentage, resets_at: .resets_at}),
        (.rate_limits.seven_day | select(.) | {label: "每周", used_percent: .used_percentage, resets_at: .resets_at})
      ])
    }' > "$dir/claude.json.tmp" && mv "$dir/claude.json.tmp" "$dir/claude.json"
  echo "$input" | jq -r '[
      (.rate_limits.five_hour.used_percentage // empty | "5h \(floor)%"),
      (.rate_limits.seven_day.used_percentage // empty | "周 \(floor)%")
    ] | join(" · ")'
fi
