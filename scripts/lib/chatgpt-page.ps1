# chatgpt-discuss 共享库：ChatGPT 页面 DOM 事实层
# （登录态探测、会话标签发现、Edge 激活、对话框/发送键定位、DOM 兜底读答案）。
# 依赖：lib/wb.ps1（Eval-JS / Invoke-WB）。
# 防重复加载的依赖声明（让本文件可被单独 dot-source / lint）：
if (-not (Get-Command Eval-JS -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\wb.ps1" }
# 全部无自有状态（只经 Eval-JS 读写页面 DOM）；dot-source 后与调用方共享 $script: 作用域。

function Get-LoginState {
  # 探测当前 ChatGPT 页面的登录态：/api/auth/session 带 user.id 即已登录。
  # 它只用于"开场判断与告知"，**不**决定恢复策略——恢复策略以锚点的会话种类
  # （/c/ 登录会话 vs /uc/ 匿名会话）为准，那是事实，而登录态可能中途变化。
  param([string]$S)
  $js = @'
(async()=>{
  try{
    const r = await fetch('/api/auth/session', {credentials:'include'});
    if(!r.ok) return 'unknown';
    const j = await r.json();
    return (j && j.user && j.user.id) ? 'in' : 'out';
  }catch(e){ return 'unknown' }
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return 'unknown'
}
function Get-SessionChatGptTabs {
  param([string]$S)
  try {
    $r = Invoke-WB "list_tabs" @{} $S
    if ($r -and $r.tabs) { return @($r.tabs | Where-Object { $_.url -like "*chatgpt.com/*" -or $_.url -like "*chat.openai.com/*" }) }
  } catch {}
  return @()
}
function Activate-EdgeWindow {
  # 浏览器进程名未必是 msedge（Chrome / 其它 Chromium 分支）——逐个试，别硬编码一个
  foreach ($name in @('msedge', 'chrome', 'brave', 'vivaldi')) {
    try {
      $ws = New-Object -ComObject WScript.Shell
      if ($ws.AppActivate($name)) { Start-Sleep -Milliseconds 500; return $true }
    } catch {}
  }
  return $false
}
function Get-LastAnswerText {
  param([string]$S)
  try { return Eval-JS '(()=>{const els=document.querySelectorAll("[data-message-author-role=\"assistant\"]");const el=els[els.length-1];return el?el.innerText:""})()' $S }
  catch { return $null }
}
function Test-GenActive {
  # 页面是否仍在生成：定位"停止"按钮（生成中才存在）。返回 $true/$false；信号不可用返回 $null。
  # 2026-10-15 加：作为"整轮落档"的页面侧完成信号——多段交付时，先完成的段不落档的判据。
  # 不押单一选择器：新版无 data-testid 时按 aria-label（停止/stop）兜底，并做可见性检查。
  # 2026-10-26 真机实测（登录态、新版页面）：`button[data-testid="stop-button"]` 已不存在，
  # 停止键只有 aria-label="停止"；生成中稳定 $true、结束后 $false（双候选设计成立）。
  # **契约**：只有 [bool] 才算有效信号；Eval-JS 返回 $null/字符串/多值一律返回 $null。
  #   "探测失败" ≠ "生成已结束"——把前者当后者会直接落档前缀（静默写残缺）。
  param([string]$S)
  $js = @'
(()=>{
  const vis = e => { try { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 } catch(_) { return false } };
  const a = document.querySelector('button[data-testid="stop-button"]');
  if (a && vis(a)) return true;
  const b = [...document.querySelectorAll('button')].find(x => vis(x) && /停止|stop/i.test(x.getAttribute('aria-label') || ''));
  return !!b;
})()
'@
  try {
    $v = Eval-JS $js $S
    if ($v -is [bool]) { return $v }
    return $null
  } catch { return $null }
}
function Resolve-ComposerTarget {
  # 定位对话框并打标记 data-cc-composer，返回命中描述（空串 = 没找到）。
  # 不押单一选择器：composer 在登录/未登录、新旧版之间结构不同
  # （textarea#prompt-textarea ↔ ProseMirror contenteditable），写死一个必然脆。
  # 候选按"最具体 → 最通用"排序；全落空时退到"页面上最后一个可见可编辑元素"。
  param([string]$S)
  $js = @'
(()=>{
  const vis = e => { try { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 } catch(_) { return false } };
  document.querySelectorAll('[data-cc-composer]').forEach(e => e.removeAttribute('data-cc-composer'));
  const ok = e => e && vis(e) && !e.disabled && !e.readOnly;
  const cands = [
    '#prompt-textarea',
    'div[contenteditable="true"]#prompt-textarea',
    'form .ProseMirror[contenteditable="true"]',
    'form [contenteditable="true"]',
    'main [contenteditable="true"]',
    'form textarea',
    'textarea'
  ];
  let el = null;
  for (const c of cands) {
    try { const e = document.querySelector(c); if (ok(e)) { el = e; break } } catch(_) {}
  }
  if (!el) {
    const all = [...document.querySelectorAll('[contenteditable="true"],textarea')].filter(ok);
    el = all.length ? all[all.length - 1] : null;
  }
  if (!el) return '';
  el.setAttribute('data-cc-composer', '1');
  return el.tagName.toLowerCase() + (el.getAttribute('contenteditable') === 'true' ? '/ce' : '/val');
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return ''
}
function Resolve-SendTarget {
  # 定位发送按钮并打标记 data-cc-send，返回命中描述（空串 = 没找到）。
  # **必须在填完内容之后调用**：输入框为空时 ChatGPT 把发送键换成语音按钮，
  # 那一刻"最后一个按钮"并不是发送键。
  param([string]$S)
  $js = @'
(()=>{
  const vis = e => { try { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 } catch(_) { return false } };
  document.querySelectorAll('[data-cc-send]').forEach(e => e.removeAttribute('data-cc-send'));
  const cands = [
    'button[data-testid="send-button"]',
    'button[aria-label*="Send"]',
    'button[aria-label*="发送"]',
    'form button[type="submit"]'
  ];
  let el = null;
  for (const c of cands) {
    try { const e = document.querySelector(c); if (e && vis(e) && !e.disabled) { el = e; break } } catch(_) {}
  }
  if (!el) {
    const comp = document.querySelector('[data-cc-composer]') || document.querySelector('#prompt-textarea');
    const scope = comp ? (comp.closest('form') || comp.parentElement) : null;
    if (scope) {
      const skip = /voice|dictat|microphone|attach|upload|tool|语音|话筒|附件|上传|工具/i;
      const btns = [...scope.querySelectorAll('button')].filter(b =>
        vis(b) && !b.disabled && !skip.test(b.getAttribute('aria-label') || ''));
      el = btns.length ? btns[btns.length - 1] : null;
    }
  }
  if (!el) return '';
  el.setAttribute('data-cc-send', '1');
  return (el.getAttribute('aria-label') || el.getAttribute('data-testid') || el.tagName.toLowerCase());
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return ''
}
function Get-CurrentThinkingName {
  # 从 composer 按钮文本读当前思考强度档位名（**不开菜单**，零副作用）。
  # 按钮文本形如 "5.6即时"（模型简写+档位名）。档位名按"先长后短"匹配，
  # 避免"高"误中"极高"。返回档位名（即时/中/高/极高/Pro），读不到返回空串。
  # 未登录/匿名会话无此选择器（返回空）。
  param([string]$S)
  $js = @'
(()=>{
  const form=document.querySelector('form.group')||document.querySelector('form');
  if(!form) return '';
  const b=[...form.querySelectorAll('button[aria-haspopup="menu"]')].find(x=>x.getAttribute('data-testid')!=='composer-plus-btn');
  if(!b) return '';
  const t=(b.textContent||'').trim();
  for(const lv of ['即时','极高','Pro','中','高']) { if(t.includes(lv)) return lv; }
  return '';
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return ''
}
