#!/usr/bin/env bash
# sponge-admin-kit 정합성 검사. 실패하면 exit 1.
set -u
cd "$(dirname "$0")/.."
fail=0
say(){ echo "✗ $1"; fail=1; }

# 1. frontmatter
head -1 SKILL.md | grep -q '^---$' || say "SKILL.md frontmatter 없음"
grep -q '^name: sponge-admin-kit$' SKILL.md || say "SKILL.md name 불일치"
grep -q '^description: .\{80,\}' SKILL.md || say "SKILL.md description 80자 미만"
grep -q '^license:' SKILL.md || say "SKILL.md license 없음"
grep -q '^version:' SKILL.md || say "SKILL.md version 없음"

# 2. references 필수 파일
for f in 00-detect 10-spec-admin 11-spec-ga 12-spec-security 13-spec-admin-extensions \
         20-impl-utm 21-impl-shortlink 22-impl-migrations 23-impl-api 24-impl-ga 25-impl-admin-ui 26-impl-admin-auth \
         30-browser-setup 40-lessons 50-report-templates; do
  [ -f "references/$f.md" ] || say "references/$f.md 없음"
  grep -q "references/$f.md" SKILL.md || say "SKILL.md가 references/$f.md 를 언급하지 않음"
done

# 3. 금지 문자열 (README 의 '출처' 줄만 예외)
if grep -rniE 'vetd|first100|G-SJH91732LJ|tvrmejtgyjxmklytuzmb|zemma' SKILL.md references CHANGELOG.md >/dev/null; then
  grep -rniE 'vetd|first100|G-SJH91732LJ|tvrmejtgyjxmklytuzmb|zemma' SKILL.md references CHANGELOG.md | head -5
  say "금지 문자열 발견 (위)"
fi
if grep -niE 'vetd|first100|G-SJH91732LJ|tvrmejtgyjxmklytuzmb|zemma' README.md | grep -v '출처' >/dev/null; then
  say "README.md 금지 문자열 (출처 줄 외)"
fi

# 4. 키 값 패턴
if grep -rnE 'eyJ[A-Za-z0-9_-]{20,}|sk_(live|test)_[A-Za-z0-9]{10,}|AIza[0-9A-Za-z_-]{20,}' . --include=*.md >/dev/null; then
  say "키처럼 보이는 문자열 발견"
fi

# 5. SKILL.md 길이
lines=$(wc -l < SKILL.md); [ "$lines" -le 360 ] || say "SKILL.md ${lines}줄 (360 초과)"

# 6. 플레이스홀더 잔여
if grep -rnE 'TBD|TODO|작성 중' SKILL.md references README.md >/dev/null; then say "플레이스홀더(TBD/TODO/작성 중) 남음"; fi

[ $fail -eq 0 ] && echo "✓ check passed"
exit $fail
