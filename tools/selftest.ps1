#!/usr/bin/env pwsh
<#
.SYNOPSIS
  chatgpt-discuss 的自检（改完脚本跑这个，不依赖 AI 自己判断"改对没改对"）。
.DESCRIPTION
  三部分：
    A. 静态检查：对真实脚本跑 lint.ps1（必须 0 ERROR）
       A2 锚点纯函数表驱动；A3 新答案判定表驱动（含 2026-09-23 静默写错档案的回归）；
       A4 轮询节奏表驱动 + 请求量性质断言（治 429 加压 / 页面加载不出来）；
       A5 部分获取判定表驱动（等够且确有新内容才取回）；
       A6 整轮落档门表驱动（多段交付：先完成的段不落档，等整轮/两读一致）
    B. 检查器自证：对故意注入坑的样本跑 lint.ps1（必须抓到 ≥6 项）
    C. 离线行为：只测不碰浏览器的路径（用不可达 daemon 逼它提前失败），校验退出码
       T1 -Status 空状态            → 0
       T2 已有锚点 + -New           → 10（拒绝新建）
       T3 非法 -ConvUrl             → 13
       T4 既无 -Question 也无模式   → 13
       T5 锁被活跃进程持有          → 12
       T6 v1 旧文档链接认领         → 3（但必须报"旧格式链接"）
  退出码 0 = 全 PASS。
.EXAMPLE
  pwsh -File selftest.ps1
#>
param(
  [string]$SkillDir = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = "Continue"
$scriptPath = Join-Path $SkillDir "scripts\ask-gpt.ps1"
$lintPath   = Join-Path $SkillDir "tools\lint.ps1"
$badSample  = Join-Path $SkillDir "tools\lint-testdata-bad.ps1"
$pwshExe    = (Get-Process -Id $PID).Path

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param([string]$Name, [bool]$Ok, [string]$Detail = "")
  [void]$results.Add([pscustomobject]@{ 项 = $Name; 结果 = $(if ($Ok) { "PASS" } else { "FAIL" }); 说明 = $Detail })
  $color = if ($Ok) { "Green" } else { "Red" }
  Write-Host ("  [{0}] {1}  {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $Name, $Detail) -ForegroundColor $color
}

# 运行脚本并取回 {code, out}
function Invoke-Target {
  param([string[]]$TargetArgs, [hashtable]$Env)
  $saved = @{}
  foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process') }
  try {
    $raw = & $pwshExe -NoProfile -File $scriptPath @TargetArgs 2>&1
    return @{ code = $LASTEXITCODE; out = ($raw | ForEach-Object { $_.ToString() }) -join "`n" }
  } finally {
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
}

$tmpRoot = Join-Path $env:TEMP ("cc-selftest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$tmpState = Join-Path $tmpRoot "state"
$tmpWork  = Join-Path $tmpRoot "work"
$tmpDocs  = Join-Path $tmpWork "docs\gpt_qa"
New-Item -ItemType Directory -Path $tmpState, $tmpDocs -Force | Out-Null
$envMap = @{ CHATGPT_DISCUSS_STATE = $tmpState }
$deadDaemon = @("-Daemon", "http://127.0.0.1:19999")   # 不可达：逼脚本在碰浏览器之前失败

Write-Host ""
Write-Host "=== A. 静默检查（真实脚本） ===" -ForegroundColor Cyan
& $pwshExe -NoProfile -File $lintPath -Path $scriptPath | Out-Null
Add-Result "A1 lint 真实脚本 0 ERROR" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

Write-Host ""
Write-Host "=== A2. 锚点纯函数（库单测，表驱动） ===" -ForegroundColor Cyan
$anchorLib = Join-Path $SkillDir "scripts\lib\chatgpt-anchor.ps1"
. $anchorLib
$anchorCases = @(
  @{ url='https://chatgpt.com/c/6aa00000-0000-0000-0000-000000000000';  id='6aa00000-0000-0000-0000-000000000000'; kind='c';  canon='https://chatgpt.com/c/6aa00000-0000-0000-0000-000000000000' }
  @{ url='https://chatgpt.com/uc/6aafb7c5-c2a8-83ea-ae37-3b148929c03c'; id='6aafb7c5-c2a8-83ea-ae37-3b148929c03c'; kind='uc'; canon='https://chatgpt.com/uc/6aafb7c5-c2a8-83ea-ae37-3b148929c03c' }
  @{ url='https://chat.openai.com/c/6ab00000-1111-2222-3333-444444444444'; id='6ab00000-1111-2222-3333-444444444444'; kind='c';  canon='https://chatgpt.com/c/6ab00000-1111-2222-3333-444444444444' }
  # 回归（2026-09-28）：前端在服务端分配 id 之前会短暂显示客户端占位符。旧正则
  # （8 位以上 [0-9a-zA-Z-]）会把它认成锚点，之后所有接口读取都打在不存在的会话上
  # （HTTP 400）并被判成"标签读不到"而反复重开——整轮白跑且不写文档。必须判为非法。
  @{ url='https://chatgpt.com/c/local-chatgpt';   id=$null;         kind='c';  canon=$null }
  @{ url='https://chatgpt.com/';                  id=$null;         kind='c';  canon=$null }
  @{ url='not-a-url';                             id=$null;         kind='c';  canon=$null }
)
$a2bad = @()
foreach ($c in $anchorCases) {
  if ((Get-ConvId $c.url) -ne $c.id) { $a2bad += "Get-ConvId($($c.url))" }
  if ((Get-CanonicalConvUrl $c.url) -ne $c.canon) { $a2bad += "Get-CanonicalConvUrl($($c.url))" }
  if ((Get-ConvKind $c.url) -ne $c.kind) { $a2bad += "Get-ConvKind($($c.url))" }
}
Add-Result "A2 锚点纯函数（c/uc/openai/占位符/非法）" ($a2bad.Count -eq 0) $(if ($a2bad.Count) { "失败: " + ($a2bad -join '; ') } else { "6 组用例全过" })

Write-Host ""
Write-Host "=== A3. 新答案判定（纯函数，表驱动） ===" -ForegroundColor Cyan
# 这一组覆盖 2026-09-23 的**静默写错档案**缺陷：基线读取失败（后端 429）时，
# 旧实现把 `n > baseN` 里的 baseN 当成 0，于是任何**已存在**的回答都被判成本轮新答案。
# 下面第 3、4 条就是那个回归——它们必须**不**返回 new。
$apiLib = Join-Path $SkillDir "scripts\lib\chatgpt-api.ps1"
. $apiLib
$verdictCases = @(
  @{ name = '基线可信/n未涨(还在生成)'; p = @{ BaseN = 1; BaseText = 'A1'; BaseKnown = $true;  N = 1; Text = 'A1' }; want = 'not-yet' }
  @{ name = '基线可信/n涨/正文不同';    p = @{ BaseN = 1; BaseText = 'A1'; BaseKnown = $true;  N = 2; Text = 'A2' }; want = 'new' }
  @{ name = '回归:基线不可信+n>0';      p = @{ BaseN = 0; BaseText = '';   BaseKnown = $false; N = 1; Text = 'A1' }; want = 'unknown-baseline' }
  @{ name = '回归:基线不可信+n=3';      p = @{ BaseN = 0; BaseText = '';   BaseKnown = $false; N = 3; Text = 'A3' }; want = 'unknown-baseline' }
  @{ name = 'n涨但正文与基线逐字同';     p = @{ BaseN = 1; BaseText = 'A1'; BaseKnown = $true;  N = 2; Text = 'A1' }; want = 'stale-same-text' }
  @{ name = '首轮提问(base=0)';         p = @{ BaseN = 0; BaseText = '';   BaseKnown = $true;  N = 1; Text = 'A1' }; want = 'new' }
  @{ name = 'n涨但正文为空';            p = @{ BaseN = 0; BaseText = '';   BaseKnown = $true;  N = 1; Text = ''   }; want = 'empty' }
)
$a3bad = @()
foreach ($c in $verdictCases) {
  $pp = $c.p
  $got = Test-NewAnswer @pp
  if ($got -ne $c.want) { $a3bad += "$($c.name): 期望 $($c.want) 实得 $got" }
}
Add-Result "A3 新答案判定（含静默写错回归）" ($a3bad.Count -eq 0) $(if ($a3bad.Count) { "失败: " + ($a3bad -join '; ') } else { "$($verdictCases.Count) 组用例全过" })

Write-Host ""
Write-Host "=== A4. 轮询节奏（纯函数 + 请求量性质断言） ===" -ForegroundColor Cyan
# 旧实现"前 40 次 1.2s、之后 2.5s"在默认 TimeoutSec=360 下一轮约 165 次请求。
# 只加"起始 1s 上限 20s"的几何退避**仍不够**（实测被限流到页面提示 too many requests），
# 故改为起始 2s、上限 60s，并对"搜索中/停滞"进一步放宽。这里既钉单点值，也钉总请求量。
$delayCases = @(
  @{ name = '第1次(最快答案要能命中)'; p = @{ Iter = 1 };                          want = 2000 }
  @{ name = '第2次';                   p = @{ Iter = 2 };                          want = 2000 }
  @{ name = '第3次翻倍';               p = @{ Iter = 3 };                          want = 4000 }
  @{ name = '第5次';                   p = @{ Iter = 5 };                          want = 8000 }
  @{ name = '第9次';                   p = @{ Iter = 9 };                          want = 32000 }
  @{ name = '第11次到上限';            p = @{ Iter = 11 };                         want = 60000 }
  @{ name = '很多次仍在上限';          p = @{ Iter = 100 };                        want = 60000 }
  @{ name = 'Iter=0 视作1';            p = @{ Iter = 0 };                          want = 2000 }
  @{ name = '搜索中至少30s';           p = @{ Iter = 1; Searching = $true };       want = 30000 }
  @{ name = '停滞≥3次至少45s';         p = @{ Iter = 1; StallCount = 3 };          want = 45000 }
  @{ name = '429退避优先';             p = @{ Iter = 1; BackoffMs = 5000 };        want = 5000 }
  @{ name = '429退避上限120s';         p = @{ Iter = 1; BackoffMs = 999999 };      want = 120000 }
)
$a4bad = @()
foreach ($c in $delayCases) {
  $pp = $c.p
  $got = Get-PollDelayMs @pp
  if ($got -ne $c.want) { $a4bad += "$($c.name): 期望 $($c.want) 实得 $got" }
}
Add-Result "A4a 轮询间隔表驱动" ($a4bad.Count -eq 0) $(if ($a4bad.Count) { "失败: " + ($a4bad -join '; ') } else { "$($delayCases.Count) 组用例全过" })

# 性质断言：默认 TimeoutSec=360 内的总请求次数必须远低于旧设计（旧约 165 次）
$total = 0; $polls = 0; $budget = 360
while ($total -lt $budget) {
  $polls++
  $total += (Get-PollDelayMs -Iter $polls) / 1000.0
}
Add-Result "A4b 360s 内请求数 ≤20（旧约165）" ($polls -le 20) "$polls 次"
$firstHit = (Get-PollDelayMs -Iter 1) / 1000.0
Add-Result "A4c 首次轮询 ≤2.5s（不拖慢快答案）" ($firstHit -le 2.5) "$firstHit s"
# 搜索场景下的请求量：这是"搜索时别一直轮询"的直接量化
$total = 0; $polls = 0; $budget = 600
while ($total -lt $budget) {
  $polls++
  $total += (Get-PollDelayMs -Iter $polls -Searching $true) / 1000.0
}
Add-Result "A4d 搜索中 600s 内请求数 ≤20" ($polls -le 20) "$polls 次"

Write-Host ""
Write-Host "=== A5. 部分获取判定（纯函数，表驱动） ===" -ForegroundColor Cyan
# "先部分获取"：等够时间且进行中正文确有新内容才取回；否则必须判 not-ready，
# 不能把半截/旧内容当结果写进档案。
$partialCases = @(
  @{ name = '等够+有新内容';   p = @{ PartialText = 'abc'; BaseText = 'old'; ElapsedS = 90 };  want = 'partial' }
  @{ name = '没等够(60s)';     p = @{ PartialText = 'abc'; BaseText = 'old'; ElapsedS = 30 };  want = 'not-ready' }
  @{ name = '无进行中正文';    p = @{ PartialText = '';    BaseText = 'old'; ElapsedS = 90 };  want = 'not-ready' }
  @{ name = '正文等于基线';    p = @{ PartialText = 'old'; BaseText = 'old'; ElapsedS = 90 };  want = 'not-ready' }
  @{ name = '首轮无基线+有新'; p = @{ PartialText = 'abc'; BaseText = '';    ElapsedS = 90 };  want = 'partial' }
)
$a5bad = @()
foreach ($c in $partialCases) {
  $pp = $c.p
  $got = Test-PartialAnswer @pp
  if ($got -ne $c.want) { $a5bad += "$($c.name): 期望 $($c.want) 实得 $got" }
}
Add-Result "A5 部分获取判定" ($a5bad.Count -eq 0) $(if ($a5bad.Count) { "失败: " + ($a5bad -join '; ') } else { "$($partialCases.Count) 组用例全过" })

Write-Host ""
Write-Host "=== A6. 整轮落档门（纯函数，表驱动） ===" -ForegroundColor Cyan
# 2026-10-15 多段交付回归：长回答拆多条消息时，先完成的段就会让"新答案判定"成立；
# 落档门保证只在"页面生成已结束"（或信号不可用时两读一致）才写入档案，避免只存一段。
$readyCases = @(
  @{ name = 'verdict 非 new 一律不等';       p = @{ Verdict = 'not-yet';         GenActive = $false; Text = 'x';  LastText = $null }; want = 'wait' }
  @{ name = '页面已结束 → 落档';             p = @{ Verdict = 'new';             GenActive = $false; Text = 'x';  LastText = $null }; want = 'accept' }
  @{ name = '页面仍在生成 → 继续等(多段)';   p = @{ Verdict = 'new';             GenActive = $true;  Text = 'x';  LastText = $null }; want = 'wait-generating' }
  @{ name = '信号不可用 + 首见 → 等稳定';    p = @{ Verdict = 'new';             GenActive = $null;  Text = 'x';  LastText = $null }; want = 'wait-stability' }
  @{ name = '信号不可用 + 两读一致 → 落档';  p = @{ Verdict = 'new';             GenActive = $null;  Text = 'x';  LastText = 'x'   }; want = 'accept' }
  @{ name = '信号不可用 + 文本仍变 → 等';    p = @{ Verdict = 'new';             GenActive = $null;  Text = 'x2'; LastText = 'x1'  }; want = 'wait-stability' }
  @{ name = 'stale-same-text 不等';          p = @{ Verdict = 'stale-same-text'; GenActive = $false; Text = 'x';  LastText = $null }; want = 'wait' }
  @{ name = 'empty 不等';                    p = @{ Verdict = 'empty';           GenActive = $false; Text = '';   LastText = $null }; want = 'wait' }
)
$a6bad = @()
foreach ($c in $readyCases) {
  $pp = $c.p
  $got = Test-AnswerReady @pp
  if ($got -ne $c.want) { $a6bad += "$($c.name): 期望 $($c.want) 实得 $got" }
}
Add-Result "A6 整轮落档门（多段交付回归）" ($a6bad.Count -eq 0) $(if ($a6bad.Count) { "失败: " + ($a6bad -join '; ') } else { "$($readyCases.Count) 组用例全过" })

Write-Host ""
Write-Host "=== B. 检查器自证（故意注入坑的样本）===" -ForegroundColor Cyan
$badOut = (& $pwshExe -NoProfile -File $lintPath -Path $badSample) -join "`n"
$badCount = ([regex]::Matches($badOut, '(?m)^\s+(E\d|W\d) ')).Count
Add-Result "B1 样本被拦下（≥6 项）" ($badCount -ge 6 -and $LASTEXITCODE -ne 0) "抓到 $badCount 项"
foreach ($need in @('E1 ', 'E2 ', 'E3 ', 'E4 ')) {
  Add-Result "B2 抓到 $need" ($badOut -match [regex]::Escape($need)) ""
}

Write-Host ""
Write-Host "=== C. 离线行为（不碰浏览器） ===" -ForegroundColor Cyan
Push-Location $tmpWork
try {
  # T1
  $r = Invoke-Target -TargetArgs @("-Status") -Env $envMap
  Add-Result "T1 -Status 空状态 → 0" ($r.code -eq 0) "exit=$($r.code)"

  # T2：先放一个已有锚点的 state
  $docPath = Join-Path $tmpDocs "t2.md"
  @{
    session = 't2'; convUrl = 'https://chatgpt.com/c/6aa00000-0000-0000-0000-000000000000'
    convHistory = @(); docPath = $docPath; title = 't2'; groupTitle = 'GPT讨论：t2'
    rounds = 1; createdAt = '2026-09-14T00:00:00'; updatedAt = '2026-09-14T00:00:00'
  } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $tmpState "t2.json") -Encoding UTF8
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t2", "-New", "-DocPath", $docPath) + $deadDaemon) -Env $envMap
  Add-Result "T2 已有锚点 + -New → 10" ($r.code -eq 10) "exit=$($r.code)"

  # T3
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t3", "-ConvUrl", "not-a-url", "-DocPath", (Join-Path $tmpDocs "t3.md")) + $deadDaemon) -Env $envMap
  Add-Result "T3 非法 -ConvUrl → 13" ($r.code -eq 13) "exit=$($r.code)"

  # T4
  $r = Invoke-Target -TargetArgs @("-Session", "t4") -Env $envMap
  Add-Result "T4 既无 -Question 也无模式 → 13" ($r.code -eq 13) "exit=$($r.code)"

  # T5：伪造一个"活跃进程持有"的锁
  $lockPath = Join-Path $tmpState "t5.lock"
  @{ pid = $PID; time = (Get-Date).ToString("o"); session = 't5' } | ConvertTo-Json -Compress |
    ForEach-Object { [System.IO.File]::WriteAllText($lockPath, $_, (New-Object System.Text.UTF8Encoding($false))) }
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t5", "-DocPath", (Join-Path $tmpDocs "t5.md")) + $deadDaemon) -Env $envMap
  Add-Result "T5 锁被活跃进程持有 → 12" ($r.code -eq 12) "exit=$($r.code)"
  Remove-Item $lockPath -Force -ErrorAction SilentlyContinue

  # T6：v1 旧文档（无标记但有 /c/ 链接）
  $legacyDoc = Join-Path $tmpDocs "legacy.md"
  @(
    "# GPT 讨论：老文档（2026-09-01）"
    "- 会话: rigol-xaxis | 模型: GPT-5.6 Luna | 链接: https://chatgpt.com/c/6aa11111-1111-1111-1111-111111111111"
    ""
    "## Q1"
    "**Q:** 老问题"
  ) -join "`r`n" | Set-Content $legacyDoc -Encoding UTF8
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t6", "-DocPath", $legacyDoc) + $deadDaemon) -Env $envMap
  $adopted = $r.out -match '旧格式链接' -and $r.out -match '6aa11111-1111-1111-1111-111111111111'
  Add-Result "T6 v1 旧文档链接被认领" $adopted "exit=$($r.code)"
} finally {
  Pop-Location
  Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$pass = @($results | Where-Object { $_.结果 -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.结果 -eq 'FAIL' }).Count
Write-Host "=== 汇总: $pass PASS / $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
$results | Format-Table -AutoSize
if ($fail -gt 0) { exit 1 }
exit 0
