# chatgpt-discuss 共享库：ChatGPT 后端接口层（会话正文、账号会话列表）。
# 依赖：lib/wb.ps1（Eval-JS）。
# 防重复加载的依赖声明（让本文件可被单独 dot-source / lint）：
if (-not (Get-Command Eval-JS -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\wb.ps1" }
# 说明：未登录时这些接口靠 cookie 认证即可（实测 2026-09-20，匿名会话也能读），
# accessToken 不是必需——所以这里"有 token 才发 Authorization"，不发空的 Bearer。

function Get-ConversationState {
  # 从 ChatGPT 后端接口读权威消息体（而不是抓 DOM）
  # 实测(2026-09-14)：DOM innerText 只拿到第一段（27/163、52/582），丢 80~95% 正文；
  # 接口有干净的完成信号：end_turn=true && content_type='text' && status='finished_successfully'
  # 2026-10-15：**整轮聚合**——长回答会拆多条消息交付（1~3 条/轮），取"最后一条 user 消息
  # 之后的全部 assistant 文本"拼接；只取最后一条会把文档截段（实测 4250 vs 17778 字）。
  # 2026-10-15 同时：只取 current_node 回溯出的**活动分支**——mapping 含"重新生成"留下的
  # 历史分支，全收会把两个版本拼进同一轮。
  param([string]$S, [string]$ConvId)
  $js = @"
(async()=>{
  try{
    if(!window.__ccTok){ try{ const s=await (await fetch('/api/auth/session')).json(); window.__ccTok=s&&s.accessToken; }catch(e){} }
    const h=window.__ccTok?{Authorization:'Bearer '+window.__ccTok}:{};
    const r=await fetch('/backend-api/conversation/$ConvId',{headers:h,credentials:'include'});
    if(!r.ok) return JSON.stringify({error:'HTTP '+r.status});
    const j=await r.json();
    // ── 只取活动分支（2026-10-15 修）────────────────────────────────────────
    // mapping 是**完整对话树**：用户点"重新生成"后，旧回答仍留在树里（同一 parent 的
    // 兄弟节点）。以前 Object.values(mapping) 全收，会把两个版本拼进同一轮（合成数据
    // 实测得到 "OLD-ANSWER\n\nNEW-ANSWER"），档案变成两版拼接且无告警。
    // 屏幕上可见的多段交付必定都在 current_node 回溯出的活动路径上，所以按 parent 链
    // 回溯既不会误杀多段，也能排除重新生成留下的历史分支。取不到 current_node 时退回全量。
    let all=[];
    if(j.current_node && j.mapping && j.mapping[j.current_node]){
      const seen=new Set(); const chain=[];
      let nid=j.current_node;
      while(nid && j.mapping[nid] && !seen.has(nid)){
        seen.add(nid); chain.push(j.mapping[nid].message); nid=j.mapping[nid].parent;
      }
      all=chain;
    } else {
      all=Object.values(j.mapping||{}).map(n=>n&&n.message);
    }
    all=all.filter(m=>m&&m.author&&m.content);
    const byTime=all.slice().sort((a,b)=>(a.create_time||0)-(b.create_time||0));
    const isText=m=>m.content.content_type==='text';
    const fin=byTime.filter(m=>m.author.role==='assistant' && m.end_turn===true && isText(m) && m.status==='finished_successfully');
    const last=fin[fin.length-1];
    // ── 整轮聚合（2026-10-15 加）──────────────────────────────────────────────
    // 网页端会把长回答拆成多条 assistant 消息连续交付（实测 1~3 条/轮）。旧实现只取
    // fin 最后一条——多段回答时文档只剩最后一段（实测：文档 4250 字 vs 会话 17778 字，
    // 用户侧表现为"只答了最后一问"）。这里按**最后一条 user 消息之后**聚合本轮全部
    // 已完成 assistant 文本（时间序，\n\n 分隔）；取不到 user 消息时退回单条。
    const lastUser=byTime.filter(m=>m.author.role==='user').pop();
    const lastUserT=(lastUser&&typeof lastUser.create_time==='number')?lastUser.create_time:null;
    // 已完成段只取本轮（最后一条 user 之后）。注意：本轮还没有完成段时结果应为空，
    // **不能回退到上一轮的旧答案**（否则部分获取会把旧答案混进本轮正文）；只有整个会话
    // 都取不到 user 消息时，才退回最后一条完成回答。
    const turnFin=(lastUserT===null)?(last?[last]:[]):fin.filter(m=>typeof m.create_time==='number'&&m.create_time>lastUserT);
    const turnParts=(turnFin.length?turnFin:((lastUserT===null&&last)?[last]:[]));
    const txt=turnParts.map(m=>(m.content.parts||[]).join('')).join('\n\n');
    // 历史生成耗时样本（2026-09-23 加）：用于给轮询节奏与耐心上限提供依据。
    // 实测同一会话内生成耗时可从 4.5s 到 274s（方差极大），所以它**不能用来预测**
    // 本轮要多久，只能用来判断"已经等得比历史最久还长了"这类异常。
    const us=byTime.filter(m=>m.author.role==='user'&&typeof m.create_time==='number').map(m=>m.create_time);
    const as=fin.filter(m=>typeof m.create_time==='number').map(m=>m.create_time);
    const gen=[];
    for(let i=0;i<Math.min(us.length,as.length);i++){ const d=as[i]-us[i]; if(d>0) gen.push(+d.toFixed(1)); }
    // ── 进行中的回答（2026-09-23 加）────────────────────────────────────────
    // 用于"先部分获取"：不等它收尾，把当前已生成的部分取回来（调用方必须标注为不完整）。
    const asstText=byTime.filter(m=>m.author.role==='assistant' && isText(m));
    const newest=asstText[asstText.length-1];
    // 部分获取同样按"整轮"：本轮已完成段 + 进行中段（否则多段交付时光取后半/前半）。
    let partialText='';
    if (newest && newest.end_turn!==true && (lastUserT===null || (typeof newest.create_time==='number' && newest.create_time>lastUserT))) {
      const inprog=(newest.content.parts||[]).join('');
      partialText=(txt.length>0)?(txt+'\n\n'+inprog):inprog;
    }
    // ── 工具/搜索活动（2026-09-23 加）───────────────────────────────────────
    // ChatGPT 联网搜索期间会先插 tool 角色的消息，这段时间答案根本不会增长；
    // 此处把"本轮是否出现工具活动"报给调用方，让它**别在搜索期间一直轮询**。
    const toolMsgs=byTime.filter(m=>m.author.role==='tool');
    return JSON.stringify({n:fin.length,turn_parts:turnParts.length,len:txt.length,text:txt,gen_seconds:gen,
                           partial_len:partialText.length,partial_text:partialText,
                           tool_count:toolMsgs.length});
  }catch(e){ return JSON.stringify({error:String(e)}) }
})()
"@
  try {
    $v = Eval-JS $js $S
    if (-not $v) { return $null }
    return ($v | ConvertFrom-Json)
  } catch { return $null }
}

function Test-NewAnswer {
  # 判定"接口读到的最后一条完成回答"是不是**本轮新产生的**。纯函数（不碰浏览器），
  # 由 tools\selftest.ps1 表驱动覆盖。
  #
  # 为什么要有这个函数（2026-09-23 实测缺陷，连续两轮命中）：
  #   ask-gpt.ps1 原先把基线 `$baseN` 默认为 0，且只在**发送之后**才去读它；
  #   后端返回 HTTP 429 时那次读取失败 → `$baseN` 静默留 0 → 轮询里
  #   `n > baseN` 对**任何已存在**的回答都成立 → 把上一轮的回答当成这一轮的结果
  #   写进文档，而且**不报错**（Q2 记成了 Q1 的逐字副本、Q3 记成了 Q2 的副本）。
  #   根因不是"读失败"，而是"读失败被当成了基线为 0"。
  #
  # 因此本函数把基线是否可信（BaseKnown）作为一等输入：基线不可信时**任何** n 都
  # 不能判为 new。调用方（ask-gpt.ps1）另有一条更硬的约束——续聊模式下基线是
  # **发送的前置条件**，拿不到就 Fail 16，压根不发问。
  param(
    [int]$BaseN,
    [string]$BaseText = '',
    [bool]$BaseKnown = $true,
    [int]$N,
    [string]$Text = ''
  )
  if (-not $BaseKnown) { return 'unknown-baseline' }
  if ($N -le $BaseN) { return 'not-yet' }
  if (-not $Text -or $Text.Length -eq 0) { return 'empty' }
  # 条数涨了但正文与基线正文逐字相同 → 不是新回答（陈旧响应 / 上一轮迟到完成）。
  if ($BaseText -and $Text -eq $BaseText) { return 'stale-same-text' }
  return 'new'
}

function Get-PollDelayMs {
  # 下一次轮询前应该等多久（纯函数，不碰浏览器，由 tools\selftest.ps1 表驱动覆盖）。
  #
  # 演进（两个阶段，都是被实测逼出来的）：
  #   ① 原实现"前 40 次 1.2s、之后 2.5s"，默认 TimeoutSec=360 下单轮约 165 次请求；
  #      生成耗时实测方差极大（4.5s / 7.3s / 50.5s / 274s），多数请求注定读到"还没好"。
  #   ② 只加几何退避（起始 1s、上限 20s）**仍然不够**：用户实测在长回合里被限流到
  #      页面提示 "too many requests"，会话页直接打不开。原因是上限太低，而且
  #      **联网搜索期间答案根本不会增长**，那段时间轮询纯属白打。
  #
  # 现在：起始 2s（最快的答案 4.5s 出现，2s 起步仍能命中）、上限 60s；
  #      搜索中/停滞时进一步放宽；429 退避可到 120s。
  #      600s 预算内约 18 次请求（对比原约 165 次）。
  param(
    [int]$Iter,
    [int]$BackoffMs = 0,
    [bool]$Searching = $false,
    [int]$StallCount = 0,
    [int]$StartMs = 2000,
    [int]$CapMs = 60000
  )
  # 429 退避优先：限流期间是**服务端在拒绝**，此时轮询毫无意义，允许退得更久。
  if ($BackoffMs -gt 0) { return [int][Math]::Min($BackoffMs, 120000) }
  if ($Iter -lt 1) { $Iter = 1 }
  $step = [Math]::Floor(($Iter - 1) / 2)      # 2,2,4,4,8,8,16,16,32,32,60,60,…
  $d = [int][Math]::Min($StartMs * [Math]::Pow(2, $step), $CapMs)
  # 联网搜索阶段：答案不会增长，等久一点完全无损（用户明确要求"搜索时别一直轮询"）。
  if ($Searching) { $d = [Math]::Max($d, 30000) }
  # 进行中但正文连续多次没有增量 → 大概率仍在搜索/长思考，进一步放宽。
  if ($StallCount -ge 3) { $d = [Math]::Max($d, 45000) }
  return [int][Math]::Min($d, 120000)
}

function Test-PartialAnswer {
  # 判定"进行中的回答"是否可作为**部分结果**取回（纯函数，表驱动）。
  # 只在没等到完整回答、且已经等够了才用；调用方必须把它标注为不完整。
  #   NotReady  —— 还没有任何可取的正文或与基线相同（等于没进展）
  #   Partial   —— 有正文且与基线不同，可以取回
  param(
    [string]$PartialText = '',
    [string]$BaseText = '',
    [double]$ElapsedS = 0,
    [double]$MinElapsedS = 60
  )
  if ($ElapsedS -lt $MinElapsedS) { return 'not-ready' }
  if (-not $PartialText -or $PartialText.Length -eq 0) { return 'not-ready' }
  if ($BaseText -and $PartialText -eq $BaseText) { return 'not-ready' }
  return 'partial'
}

function Test-AnswerReady {
  # 整轮落档门（纯函数，表驱动，2026-10-15 加）：Test-NewAnswer 判 new 之后，现在能不能
  # 真的把这段正文写进档案。多段交付的回答里，**先完成的段**就会让 Test-NewAnswer 判 new，
  # 但页面可能仍在生成后续段——直接落档会丢后半（实测案例：5262+3967、13090+4837、
  # 86+10508+6582）。页面"停止"按钮是廉价的整轮完成信号（一次本机 DOM 读，不耗接口配额）：
  #   GenActive=$false → 生成已结束，落档；
  #   GenActive=$true  → 仍在生成，先不取（继续等整轮）；
  #   GenActive=$null  → 信号不可用，**不能**当完成——继续等，等不到由超时收尾按
  #                      "不完整"落档并标注（2026-10-15 修正：原先拿"两次组合文本逐字
  #                      一致"当完成证据是错的，见下）。
  #   accept          —— 可写入档案
  #   wait-generating —— 页面仍在生成（多段交付中间态）
  #   wait-stability  —— 信号不可用，继续轮询等信号恢复（不是"文本稳定即可落档"）
  #   wait            —— verdict 本身不该取（继续轮询）
  #
  # 为什么删掉"两读文本一致就落档"（2026-10-15 修正）：
  #   `$Text` 只含 end_turn=true 的**已完成段**，后续段流式期间它天然不变。因此
  #   "两读一致"并不能证明整轮生成结束；只要页面探测出现过一次 $true、紧接着一次瞬态
  #   异常返回 $null，就可能在段间空档里判定"稳定"并把前缀写进档案——那正是本 PR 要
  #   修掉的静默截断。信号不可用时唯一安全的做法是继续等（或超时按不完整落档）。
  param(
    [string]$Verdict = '',
    [object]$GenActive = $null,     # $true / $false / $null（非 [bool] 一律视为信号不可用）
    [string]$Text = '',
    [object]$LastText = $null        # 保留：仅用于调用方诊断，不参与落档判定
  )
  if ($Verdict -ne 'new') { return 'wait' }
  if ($GenActive -is [bool]) {
    if ($GenActive) { return 'wait-generating' }
    return 'accept'
  }
  return 'wait-stability'
}

function Get-ChatListJs {
  # 在 ChatGPT 页面里用它的后端接口取会话列表（走页面自身的登录态 + accessToken）
  param([int]$Limit = 30)
  @"
(async()=>{
  try{
    let tk=null;
    try{ const s=await (await fetch('/api/auth/session',{credentials:'include'})).json(); tk=s&&s.accessToken; }catch(e){}
    const h = tk ? {Authorization:'Bearer '+tk} : {};
    let out=[], off=0, total=null;
    while(out.length < $Limit){
      const r = await fetch('/backend-api/conversations?offset='+off+'&limit=28&order=updated',{headers:h,credentials:'include'});
      if(!r.ok) return JSON.stringify({error:'HTTP '+r.status});
      const j = await r.json();
      if(total===null) total=(typeof j.total==='number')?j.total:null;
      const items=j.items||[];
      if(!items.length) break;
      for(const i of items) out.push({id:i.id, title:i.title, upd:i.update_time});
      off += items.length;
      if(out.length >= $Limit) break;
      if(total!==null && off>=total) break;
    }
    return JSON.stringify({total:total, count:out.length, items:out.slice(0,$Limit)});
  }catch(e){ return JSON.stringify({error:String(e)}); }
})()
"@
}
