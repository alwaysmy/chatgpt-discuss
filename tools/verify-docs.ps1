#!/usr/bin/env pwsh
<#
.SYNOPSIS
  gpt_qa 文档体检：比对"文档里存的答案"与"ChatGPT 会话里的权威正文"，找出残缺。
.DESCRIPTION
  背景（2026-09-14 实测）：旧版脚本从 DOM innerText 取答案，而 DOM 只渲染第一段
  （实测 27/163、52/582 字符）→ 文档里的答案可能大面积残缺。

  本工具**只读**，不修改任何文件：
    1. 扫描 <Root>\**\docs\gpt_qa\*.md 与其它 *.md，提取会话链接（chatgpt-discuss 标记 或 正文里的 /c/<uuid>）
    2. 按会话 id 去重（多个文档可能引用同一条会话）
    3. 用 webbridge 在 ChatGPT 页面里 fetch 后端接口，取回该会话的完整 user/assistant 消息
    4. 把文档里的 ## Q<n> 段落按【问题文本前缀】对齐到会话轮次（不按序号，防错位）
    5. 比对答案：ok / TRUNCATED（前缀截断）/ 片段（文档是整轮正文的中段/尾段——2026-10-15 起识别）/ SHORTER / MISMATCH / UNMATCHED（接口侧按"该轮全部 assistant 文本聚合"比对）
.PARAMETER Roots
  要扫描的根目录，默认 D:\MyProjects
.PARAMETER Only
  只处理路径匹配该通配符的文档（调试用），默认全部
.PARAMETER Session
  webbridge 会话名（默认 cc-browse，会自动准备标签）
.PARAMETER MaxChars
  单条答案比对时截断显示长度，默认 120
.EXAMPLE
  pwsh -File verify-docs.ps1 -Roots D:\MyProjects
#>
param(
  [string[]]$Roots = @('D:\MyProjects'),
  [string]$Only = "*",
  [string]$Session = "cc-browse",
  [int]$MaxChars = 120
)

$ErrorActionPreference = "Continue"
$CHAT_HOME = "https://chatgpt.com/"
$skillDir = Split-Path $PSScriptRoot -Parent
$askGpt = Join-Path $skillDir "scripts\ask-gpt.ps1"

# ---------- webbridge 封装 ----------
# 共享库（dot-source）：webbridge 封装与通用文件 IO 已抽到 scripts\lib\，单一事实源。
# dot-source 后与本脚本共享 $script: 作用域。注意：库里的 Invoke-WB 返回 data（不是整体响应），
# 且 daemon 返回 ok=false 时会 throw——本脚本原先不查 ok 是一处隐患，此处顺带修正。
. "$PSScriptRoot\..\scripts\lib\common.ps1"
. "$PSScriptRoot\..\scripts\lib\wb.ps1"
$Daemon = Resolve-DaemonAddr

function Ensure-ChatTab {
  $tabs = @()
  # 库版 Invoke-WB 返回 data（不是整体响应），失败时 throw
  try { $r = Invoke-WB "list_tabs" @{} $Session; if ($r -and $r.tabs) { $tabs = @($r.tabs | Where-Object { $_.url -like "*chatgpt.com/*" }) } } catch {}
  if ($tabs.Count -gt 0) {
    try { Invoke-WB "find_tab" @{ url = $tabs[0].url } $Session | Out-Null; return $true } catch {}
  }
  Write-Host "  准备 ChatGPT 标签..." -ForegroundColor DarkGray
  Invoke-WB "navigate" @{ url = $CHAT_HOME; newTab = $true; group_title = "GPT讨论：文档体检" } $Session | Out-Null
  Start-Sleep -Seconds 6
  for ($i = 0; $i -lt 20; $i++) {
    # 与 ask-gpt.ps1 同一套多候选定位：未登录/新版页面的 composer 不是 #prompt-textarea
    $probe = '(()=>{const v=e=>{try{const r=e.getBoundingClientRect();return r.width>0&&r.height>0}catch(_){return false}};for(const s of ["#prompt-textarea","div[contenteditable=\"true\"]#prompt-textarea","form .ProseMirror[contenteditable=\"true\"]","form [contenteditable=\"true\"]","main [contenteditable=\"true\"]","form textarea","textarea"]){const e=document.querySelector(s);if(e&&v(e)&&!e.disabled&&!e.readOnly)return true}return false})()'
    try { $v = Eval-JS $probe $Session; if ($v -eq $true -or "$v" -eq "true") { return $true } } catch {}
    Start-Sleep -Milliseconds 1500
  }
  return $false
}

# 取一条会话的 (user, assistant) 有序序列
function Get-ConvTurns {
  param([string]$ConvId)
  $js = @"
(async()=>{
  try{
    if(!window.__ccTok){ try{ const s=await (await fetch('/api/auth/session')).json(); window.__ccTok=s&&s.accessToken; }catch(e){} }
    const h=window.__ccTok?{Authorization:'Bearer '+window.__ccTok}:{};
    const r=await fetch('/backend-api/conversation/$ConvId',{headers:h,credentials:'include'});
    if(!r.ok) return JSON.stringify({error:'HTTP '+r.status});
    const j=await r.json();
    // 只取 current_node 回溯出的活动分支（2026-10-15 修）：mapping 里含"重新生成"留下的
    // 历史分支，全收会把两版答案都算进同一轮，导致完整档案被误报"截断/片段"。
    let ms=[];
    if(j.current_node && j.mapping && j.mapping[j.current_node]){
      const seen=new Set(); let nid=j.current_node;
      while(nid && j.mapping[nid] && !seen.has(nid)){ seen.add(nid); ms.push(j.mapping[nid].message); nid=j.mapping[nid].parent; }
    } else {
      ms=j.mapping?Object.values(j.mapping).map(n=>n&&n.message):[];
    }
    ms=ms.filter(m=>m&&m.author);
    ms.sort((a,b)=>(a.create_time||0)-(b.create_time||0));
    const out=[];
    for(const m of ms){
      const ct=m.content&&m.content.content_type;
      if(ct!=='text') continue;
      const t=(m.content.parts||[]).join('');
      if(!t) continue;
      if(m.author.role==='user') out.push({r:'u',t:t});
      else if(m.author.role==='assistant'&&m.end_turn===true) out.push({r:'a',t:t});
    }
    return JSON.stringify({title:j.title,turns:out});
  }catch(e){ return JSON.stringify({error:String(e)}) }
})()
"@
  $raw = $null
  try { $raw = Eval-JS $js $Session } catch { return $null }
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Normalize-Text {
  # 比对口径：两侧剥掉 markdown 的"渲染差异"后再比。
  # 文档里的答案是当年从 DOM innerText 抓的（**渲染后**文本：`**`、`##`、```text 语言标记、
  # `---` 分隔线都被渲染掉了），接口返回的是**原始 markdown 源码**。
  # 不剥就会把格式差异误报成"残缺"（这个坑实测踩了三次）。
  param([string]$T)
  if (-not $T) { return "" }
  $s = [regex]::Replace($T, '(?m)^\s*```.*$', '')      # 代码围栏整行（含 text/c/cpp 语言标记）
  $s = [regex]::Replace($s, '(?m)^\s*[-*_]{3,}\s*$', '')  # 水平分隔线
  $s = [regex]::Replace($s, '\s+', '')
  $s = $s -replace '[*_`~]', ''
  return ($s -replace '#', '')
}
function Get-Tail { param([string]$T, [int]$N = 120) if (-not $T) { return "" }; if ($T.Length -le $N) { return $T }; return $T.Substring($T.Length - $N) }

# ---------- 扫描文档 ----------
Write-Host ""
Write-Host "=== 扫描文档 ===" -ForegroundColor Cyan
$docs = New-Object System.Collections.Generic.List[object]
foreach ($root in $Roots) {
  if (-not (Test-Path $root)) { continue }
  Get-ChildItem -Path $root -Recurse -Directory -Filter 'gpt_qa' -ErrorAction SilentlyContinue | ForEach-Object {
    Get-ChildItem -Path $_.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.FullName -notlike $Only) { return }
      $txt = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
      $cid = $null
      # 同 chatgpt-anchor.ps1：必须 UUID 形态，否则会认领前端占位符（如 c/local-chatgpt）
      $mk = [regex]::Match($txt, 'chatgpt-discuss:.*?conv=https://chatgpt\.com/(?:c|uc)/([0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12})')
      if ($mk.Success) { $cid = $mk.Groups[1].Value }
      if (-not $cid) {
        $lm = [regex]::Match($txt.Substring(0, [Math]::Min(3000, $txt.Length)), 'chatgpt\.com/(?:c|uc)/([0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12})')
        if ($lm.Success) { $cid = $lm.Groups[1].Value }
      }
      # 分类：脚本型（脚本自动落盘，含 **Q:** / **A:**）vs 汇总型（AI 手工整理，含要点/完整原文）
      $kind = '脚本型'
      if ($txt -notmatch '\*\*Q[:：]\*\*' -or $txt -match '\*\*Q[（(]') { $kind = '汇总型' }
      [void]$docs.Add([pscustomobject]@{ Path = $_.FullName; Name = $_.Name; Dir = (Split-Path $_.FullName -Parent); Text = $txt; ConvId = $cid; QCount = ([regex]::Matches($txt, '(?m)^##\s*Q\d+')).Count; Kind = $kind })
    }
  }
}
Write-Host ("  找到 " + $docs.Count + " 份文档；其中 " + @($docs | Where-Object { $_.ConvId }).Count + " 份带会话链接")
$withLink = @($docs | Where-Object { $_.ConvId })
if ($withLink.Count -eq 0) { Write-Host "没有可体检的文档（都需要会话链接）" -ForegroundColor Yellow; exit 0 }

if (-not (Ensure-ChatTab)) { Write-Host "ChatGPT 标签未就绪，退出" -ForegroundColor Red; exit 5 }

# ---------- 逐会话取正文（去重） ----------
Write-Host ""
Write-Host "=== 拉取会话正文（接口） ===" -ForegroundColor Cyan
$convCache = @{}
foreach ($cid in ($withLink | Select-Object -ExpandProperty ConvId -Unique)) {
  $c = Get-ConvTurns -ConvId $cid
  if (-not $c -or $c.error) {
    Write-Host ("  [X] " + $cid.Substring(0, 8) + "  " + $(if ($c) { $c.error } else { "无响应" })) -ForegroundColor Red
    $convCache[$cid] = $null
  } else {
    $nu = @($c.turns | Where-Object { $_.r -eq 'u' }).Count
    $tot = ($c.turns | Where-Object { $_.r -eq 'a' } | ForEach-Object { $_.t.Length } | Measure-Object -Sum).Sum
    Write-Host ("  [OK] " + $cid.Substring(0, 8) + "  「" + $c.title + "」  提问 " + $nu + "  回答总长 " + $tot)
    $convCache[$cid] = $c
  }
}

# ---------- 比对 ----------
Write-Host ""
Write-Host "=== 比对结果 ===" -ForegroundColor Cyan
$verdicts = New-Object System.Collections.Generic.List[object]
foreach ($doc in $withLink) {
  $conv = $convCache[$doc.ConvId]
  if (-not $conv) { [void]$verdicts.Add([pscustomobject]@{ 文档=$doc.Name; 类型=$doc.Kind; 会话=$doc.ConvId.Substring(0,8); 段数=$doc.QCount; 一致=0; 问题=0; 结论="会话拉取失败" }); continue }
  if ($doc.Kind -eq '汇总型') {
    # 人工整理的要点稿：与原文比对没有意义（它本来就不是原文）
    [void]$verdicts.Add([pscustomobject]@{ 文档=$doc.Name; 类型="汇总型"; 会话=$doc.ConvId.Substring(0,8); 段数=$doc.QCount; 一致=0; 问题=0; 结论="人工汇总稿·跳过比对" })
    continue
  }
  $blocks = [regex]::Matches($doc.Text, '(?ms)^##\s*Q(\d+).*?(?=^##\s*Q\d+|\z)')
  $okN = 0; $probN = 0; $detail = New-Object System.Collections.Generic.List[string]
  foreach ($b in $blocks) {
    $qIdx = $b.Groups[1].Value
    $blk = $b.Value
    $qm = [regex]::Match($blk, '(?s)\*\*Q:?\*\*\s*(.*?)\s*\*\*A:?\*\*')
    if (-not $qm.Success) { [void]$detail.Add("Q${qIdx}: 无法解析"); $probN++; continue }
    $qText = Normalize-Text $qm.Groups[1].Value
    $am = [regex]::Match($blk, '(?s)\*\*A:?\*\*\s*(.*)$')
    $aText = if ($am.Success) { Normalize-Text $am.Groups[1].Value } else { "" }
    if ($qText.Length -gt 60) { $qKey = $qText.Substring(0, 60) } else { $qKey = $qText }
    # 按问题前缀对齐到会话里的 user 消息
    $turnIdx = -1
    for ($i = 0; $i -lt $conv.turns.Count; $i++) {
      if ($conv.turns[$i].r -ne 'u') { continue }
      $un = Normalize-Text $conv.turns[$i].t
      if ($un.Length -ge 20 -and $un.StartsWith($qKey.Substring(0, [Math]::Min(40, $qKey.Length)))) { $turnIdx = $i; break }
    }
    if ($turnIdx -lt 0) { [void]$detail.Add("Q${qIdx}: 会话里找不到对应提问"); $probN++; continue }
    # 接口侧按"该轮全部 assistant 文本聚合"比对（2026-10-15：与整轮聚合落档对齐）
    $apiParts = New-Object System.Collections.Generic.List[string]
    for ($j = $turnIdx + 1; $j -lt $conv.turns.Count; $j++) {
      if ($conv.turns[$j].r -eq 'a') { [void]$apiParts.Add((Normalize-Text $conv.turns[$j].t)); continue }
      if ($conv.turns[$j].r -eq 'u') { break }
    }
    $apiA = ($apiParts -join "")
    if (-not $apiA) { [void]$detail.Add("Q${qIdx}: 该轮没有已完成回答"); $probN++; continue }
    # 判据优先级：①完全一致 ②文档是接口的严格前缀＝截断 ③文档是整轮正文的中段/尾段片段 ④结尾逐字一致＝完整（仅格式差异）
    if ($aText -eq $apiA) { $okN++; continue }
    if ($apiA.StartsWith($aText)) {
      $probN++
      [void]$detail.Add("Q${qIdx}: **截断** 文档 " + $aText.Length + " / 接口 " + $apiA.Length + " 字（丢 " + [int](100 - 100.0 * $aText.Length / $apiA.Length) + "%）")
    } elseif ($apiA.Contains($aText)) {
      $probN++
      [void]$detail.Add("Q${qIdx}: **片段** 文档 " + $aText.Length + " / 接口 " + $apiA.Length + " 字（文档是整轮回答的中段/尾段片段，非前缀截断）")
    } elseif ((Get-Tail $aText) -eq (Get-Tail $apiA)) {
      $okN++
      [void]$detail.Add("Q${qIdx}: 完整（结尾逐字一致；仅 markdown 渲染差异，长度 " + $aText.Length + " / " + $apiA.Length + "）")
    } elseif ($aText.Length -lt $apiA.Length * 0.85) {
      $probN++
      [void]$detail.Add("Q${qIdx}: **疑似偏短** 文档 " + $aText.Length + " / 接口 " + $apiA.Length + " 字，且结尾不一致 → 需人工看")
    } else {
      $probN++
      [void]$detail.Add("Q${qIdx}: 不一致 文档 " + $aText.Length + " / 接口 " + $apiA.Length + " 字（非前缀、结尾不同）")
    }
  }
  $verdict = if ($probN -eq 0 -and $blocks.Count -gt 0) { "全部一致" } elseif ($blocks.Count -eq 0) { "无可解析段落" } else { "有问题" }
  [void]$verdicts.Add([pscustomobject]@{ 文档 = $doc.Name; 会话 = $doc.ConvId.Substring(0, 8); 段数 = $blocks.Count; 一致 = $okN; 问题 = $probN; 结论 = $verdict })
  foreach ($d in $detail) { Write-Host ("    " + $doc.Name.PadRight(38) + " " + $d) -ForegroundColor $(if ($d -match '截断|片段') { "Red" } else { "Yellow" }) }
}

Write-Host ""
Write-Host "=== 汇总 ===" -ForegroundColor Cyan
$verdicts | Sort-Object 结论, 文档 | Format-Table -AutoSize
$bad = @($verdicts | Where-Object { $_.结论 -eq '有问题' })
$trunc = ($verdicts | Measure-Object -Property 问题 -Sum).Sum
Write-Host ("文档 " + $verdicts.Count + " 份；有问题的 " + $bad.Count + " 份；问题段落合计 " + $trunc) -ForegroundColor $(if ($bad.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "（本工具只读，未修改任何文件。确认伤情后可再做带 -Fix 的补全）" -ForegroundColor DarkGray
exit 0
