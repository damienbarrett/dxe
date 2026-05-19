#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

out_dir="${HOME}/.claude"
out_file="${out_dir}/agent_stats_limits.json"
tmp_file="${out_file}.tmp.$$"

mkdir -p "$out_dir"

# Always emit the same schema so the reader's validation is unambiguous, even
# before the first API response (when rate_limits is absent).
printf '%s\n' "$input" | jq '{
  five_hour: (.rate_limits.five_hour // null),
  seven_day: (.rate_limits.seven_day // null),
  updated_at: now
}' > "$tmp_file"
mv "$tmp_file" "$out_file"

# Minimal default status line. Customize freely — the file write above is the
# only part agent-stats depends on.
model=$(printf '%s' "$input" | jq -r '.model.display_name // "claude"')
pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
five_h=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

limits=""
[ -n "$five_h" ] && limits="5h $(printf '%.0f' "$five_h")%"
[ -n "$week" ] && limits="${limits:+$limits · }7d $(printf '%.0f' "$week")%"

if [ -n "$limits" ]; then
  echo "[$model] ctx ${pct}% · $limits"
else
  echo "[$model] ctx ${pct}%"
fi
