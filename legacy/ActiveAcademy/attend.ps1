$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

$BASE   = 'https://portal.osaka-seikei.ac.jp/web_gen'
$LOGIN  = "$BASE/cl0010.aspx"
$PORTAL = "$BASE/portal/mt0010.aspx"
$MENU_SYUKETSU = 'repMenuCategory$ctl01$repSubMenu$ctl05$lbtnSubMenu'  # メニュー「出欠確認」
$YOUBI  = @('？','月','火','水','木','金','土','日')
$CACHE_PATH = Join-Path $PSScriptRoot 'attend_cache.json'
$script:TimeoutSec = 15     # 既定（未計測時）。calibrate 後はキャッシュ値を使用
$script:Retries    = 4      # 1リクエストあたりの試行回数
$script:ChurnLines = @()    # 「履修が変わっています」通知（選択画面の再描画で消えないよう保持）
$script:MenuIdx    = 0      # 選択メニューが自動リロードするとき、引き継ぐハイライト位置

function Pause-Exit($code){ Write-Host ''; Write-Host 'Enter キーで閉じます...'; [void][Console]::ReadLine(); exit $code }
function Fail($m){ Write-Host ''; Write-Host "[エラー] $m" -ForegroundColor Red; Pause-Exit 1 }

function Get-Token($html,$id){
  if ($html -match ('id="'+[regex]::Escape($id)+'"[^>]*value="([^"]*)"')) { return $matches[1] }
  return ''
}
function Html-Decode($s){
  $s -replace '&#39;',"'" -replace '&quot;','"' -replace '&nbsp;',' ' -replace '&lt;','<' -replace '&gt;','>' -replace '&amp;','&'
}
# 全角の英数字・記号(U+FF01-FF5E)・空白(U+3000)・ローマ数字を半角へ正規化（日本語のかな漢字はそのまま）
function To-Han($s){
  if ([string]::IsNullOrEmpty($s)) { return $s }
  $s = $s -replace 'Ⅰ','I' -replace 'Ⅱ','II' -replace 'Ⅲ','III' -replace 'Ⅳ','IV' -replace 'Ⅴ','V' -replace 'Ⅵ','VI' -replace 'Ⅶ','VII' -replace 'Ⅷ','VIII' -replace 'Ⅸ','IX' -replace 'Ⅹ','X'
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $c = [int][char]$ch
    if     ($c -ge 0xFF01 -and $c -le 0xFF5E) { [void]$sb.Append([char]($c - 0xFEE0)) }
    elseif ($c -eq 0x3000)                    { [void]$sb.Append(' ') }
    else                                      { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}
function To-Form($ord){
  ($ord.GetEnumerator() | ForEach-Object {
    [Uri]::EscapeDataString([string]$_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value)
  }) -join '&'
}
# タイムアウト + リトライ付き Invoke-WebRequest
function Fetch($params){
  $lastErr = $null
  for ($a=1; $a -le $script:Retries; $a++) {
    try { return Invoke-WebRequest @params -UseBasicParsing -TimeoutSec $script:TimeoutSec }
    catch { $lastErr = $_; if ($a -lt $script:Retries) { Start-Sleep -Milliseconds (300 * $a) } }
  }
  throw $lastErr
}

function Load-Cache {
  if (-not (Test-Path $CACHE_PATH)) { return $null }
  try { return ([IO.File]::ReadAllText($CACHE_PATH, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function Save-Cache($obj){
  try { [IO.File]::WriteAllText($CACHE_PATH, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false))) } catch {}
}
# 現在の全状態でキャッシュを書き出す（ログイン情報も保持）
function Write-CacheState($timeoutSec,$calib,$courses,$hash,$updated,$userId,$userPw){
  Save-Cache ([pscustomobject]@{
    timeoutSec=$timeoutSec; calib=$calib; courses=$courses; hash=$hash; updated=$updated; userId=$userId; userPw=$userPw
  })
}
function Compute-CourseHash($courses){
  $keys = @($courses | ForEach-Object { "{0}|{1}|{2}" -f $_.code, $_.youbi, $_.jigen } | Sort-Object)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($keys -join ';'))) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $sha.Dispose() }
}

# 溜まったキー入力（長押しの自動リピート等）を破棄
function Flush-Input {
  try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch {}
}
# 指定秒待つ。待機中に Esc が押されたら $false（中止）を返す。
function Wait-Or-Abort($seconds){
  if ([Console]::IsInputRedirected) { Start-Sleep -Seconds $seconds; return $true }
  Flush-Input
  for ($i=0; $i -lt [int]($seconds*10); $i++){
    try { if ([Console]::KeyAvailable) { if (([Console]::ReadKey($true)).Key -eq 'Escape') { return $false } } } catch {}
    Start-Sleep -Milliseconds 100
  }
  return $true
}
# 全角=2/半角=1 の表示幅
function Disp-Width($s){
  $w = 0
  foreach ($ch in $s.ToCharArray()) {
    $c = [int][char]$ch
    if ($c -ge 0x1100 -and (
        $c -le 0x115F -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or ($c -ge 0xFFE0 -and $c -le 0xFFE6))) { $w += 2 } else { $w += 1 }
  }
  return $w
}

# ログイン試行。成功: @{ok=$true; ss; portal} / 認証失敗: @{ok=$false; reason='cred'} / 接続失敗: @{ok=$false; reason='conn'}
function Try-Login($uid,$pw){
  try {
    $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $r = Fetch @{ Uri=$LOGIN; WebSession=$s }
    $body = [ordered]@{
      '__LASTFOCUS'=''; '__EVENTTARGET'=''; '__EVENTARGUMENT'=''
      '__VIEWSTATE'          = (Get-Token $r.Content '__VIEWSTATE')
      '__VIEWSTATEGENERATOR' = (Get-Token $r.Content '__VIEWSTATEGENERATOR')
      '__EVENTVALIDATION'    = (Get-Token $r.Content '__EVENTVALIDATION')
      'txtUserid'=$uid; 'txtUserpw'=$pw; 'ibtnLogin.x'='10'; 'ibtnLogin.y'='10'
    }
    $r = Fetch @{ Uri=$LOGIN; WebSession=$s; Method='Post'; Body=(To-Form $body); ContentType='application/x-www-form-urlencoded' }
    $html = $r.Content
    $title = if ($html -match '<title>([\s\S]*?)</title>') { $matches[1] } else { '' }
    if ($html -match 'id="txtUserpw"') { return @{ ok=$false; reason='cred' } }                       # ログイン画面のまま＝認証失敗
    if ($title -match 'トップ' -or $html -match 'putPopupLinkSetFlag') { return @{ ok=$true; ss=$s; portal=$html } }  # ポータル到達＝成功
    return @{ ok=$false; reason='busy' }                                                              # エラー画面等の一時状態
  } catch {
    return @{ ok=$false; reason='conn' }
  }
}
# 表示幅で右パディング
function Pad-Disp($s,$w){ $s + (' ' * [Math]::Max(0, $w - (Disp-Width $s))) }
# 初期値を保持したインライン1行編集（Enter確定 / Esc取消(=null)）
function Read-LineEdit($initial){
  $sb = New-Object System.Text.StringBuilder
  if ($initial) { [void]$sb.Append([string]$initial); Write-Host -NoNewline ([string]$initial) }
  while ($true) {
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'Enter') { Write-Host ''; return $sb.ToString() }
    elseif ($k.Key -eq 'Escape') { Write-Host ''; return $null }
    elseif ($k.Key -eq 'Backspace') {
      if ($sb.Length -gt 0) {
        $w = if ((Disp-Width ([string]$sb[$sb.Length-1])) -eq 2) { 2 } else { 1 }
        [void]$sb.Remove($sb.Length-1,1)
        for ($z=0; $z -lt $w; $z++) { Write-Host -NoNewline "`b `b" }
      }
    }
    elseif ($k.KeyChar -and -not [char]::IsControl([char]$k.KeyChar)) {
      [void]$sb.Append($k.KeyChar); Write-Host -NoNewline ([string]$k.KeyChar)
    }
  }
}
# パスワード再入力。対話は Esc で終了（$null）/ 空Enterはもう一度。自動実行は空Enterで終了（$null）。
function Read-Pw-OrCancel($prompt){
  if ([Console]::IsInputRedirected) {
    $s = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s.Trim()
  }
  Write-Host -NoNewline ($prompt + ': ')
  $s = Read-LineEdit ''
  if ($null -eq $s) { return $null }   # Esc
  return $s.Trim()
}
# 出席送信が『可能時間外／判定不能』のとき、再試行するか尋ねる（再試行=$true / 終了=$false）
function Confirm-Retry {
  if ([Console]::IsInputRedirected) {
    $s = Read-Host '再試行するには r を入力（それ以外で終了）'
    return ("$s".Trim().ToLower() -eq 'r')
  }
  Flush-Input
  Write-Host -NoNewline 'Enter で再試行 / Esc で終了 ... '
  while ($true) {
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'Enter')  { Write-Host '再試行します'; return $true }
    if ($k.Key -eq 'Escape') { Write-Host '終了します';   return $false }
  }
}
# ログイン情報フォーム。前回値を保持し、↑↓で項目選択→Enterで編集、[送信]で確定。
# 返り値 @{ submit=$bool; userId; userPw }
function Edit-Login-Form($uid,$pw){
  if ([Console]::IsInputRedirected) {
    $u = Read-Host ("ユーザー名（Enterで [{0}] を維持）" -f $uid)
    if ([string]::IsNullOrEmpty($u)) { $u = $uid }
    $p = Read-Host 'パスワード（Enterで現状維持）'
    if ([string]::IsNullOrEmpty($p)) { $p = $pw }
    return @{ submit=$true; userId=(To-Han ("$u").Trim()); userPw=(To-Han ("$p").Trim()) }
  }
  $fields = @("$uid","$pw")
  $idx = 0
  try { [Console]::CursorVisible=$false } catch {}
  while ($true) {
    try { Clear-Host } catch {}
    Write-Host 'ログイン情報の入力（↑↓ 項目選択 / Enter 編集・送信 / Esc 中止）'
    Write-Host ''
    $rows = @(("ユーザー名 : {0}" -f $fields[0]), ("パスワード : {0}" -f $fields[1]), '[ 送信 ]')
    for ($i=0; $i -lt 3; $i++){
      $line = Pad-Disp (("{0} {1}" -f $(if ($i -eq $idx) { '>' } else { ' ' }), $rows[$i])) 44
      if ($i -eq $idx) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
      else            { Write-Host $line }
    }
    $k = [Console]::ReadKey($true)
    if     ($k.Key -eq 'UpArrow')   { $idx = ($idx - 1 + 3) % 3 }
    elseif ($k.Key -eq 'DownArrow') { $idx = ($idx + 1) % 3 }
    elseif ($k.Key -eq 'Escape')    { try { [Console]::CursorVisible=$true } catch {}; return @{ submit=$false } }
    elseif ($k.Key -eq 'Enter') {
      if ($idx -eq 2) { try { [Console]::CursorVisible=$true } catch {}; return @{ submit=$true; userId=(To-Han $fields[0].Trim()); userPw=(To-Han $fields[1].Trim()) } }
      Write-Host ''
      Write-Host -NoNewline ("{0}: " -f @('ユーザー名','パスワード')[$idx])
      try { [Console]::CursorVisible=$true } catch {}
      $new = Read-LineEdit $fields[$idx]
      try { [Console]::CursorVisible=$false } catch {}
      if ($null -ne $new) { $fields[$idx] = $new }
    }
  }
}
# メニュー「出欠確認」をPOSTし jc1010 の @{ html=…; url=… } を返す
function Goto-Jc1010($ss, $portalHtml){
  $b = [ordered]@{
    'tabCalender_ClientState' = '{"ActiveTabIndex":1,"TabState":[true,true,true]}'
    '__EVENTTARGET'=''; '__EVENTARGUMENT'=''
    '__VIEWSTATE'          = (Get-Token $portalHtml '__VIEWSTATE')
    '__VIEWSTATEGENERATOR' = (Get-Token $portalHtml '__VIEWSTATEGENERATOR')
    '__EVENTVALIDATION'    = (Get-Token $portalHtml '__EVENTVALIDATION')
    ($MENU_SYUKETSU+'.x')='10'; ($MENU_SYUKETSU+'.y')='10'
  }
  $r = Fetch @{ Uri=$PORTAL; WebSession=$ss; Method='Post'; Body=(To-Form $b); ContentType='application/x-www-form-urlencoded' }
  # PS5.1 は ResponseUri、PS7(Core) は RequestMessage.RequestUri を使う（PS7 では ResponseUri が無い）
  $uri = $null
  try { if ($r.BaseResponse.ResponseUri) { $uri = $r.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
  if (-not $uri) { try { $uri = $r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri } catch {} }
  return @{ html = $r.Content; url = $uri }
}
# 出欠グリッドから 指定 時限×曜日 セル(前期/後期行)の __doPostBack ターゲットを取得
function Get-SlotCtlId($jcHtml,$youbiNum,$jigen){
  $dec = Html-Decode $jcHtml
  $m = [regex]::Match($dec, '<table[^>]*class="item_shusseki"[\s\S]*?</table>')
  if (-not $m.Success) { return $null }
  $curJigen = $null
  foreach ($rowM in [regex]::Matches($m.Value, '<tr[^>]*>([\s\S]*?)</tr>')) {
    $ch = @([regex]::Matches($rowM.Groups[1].Value, '<t[dh][^>]*>([\s\S]*?)</t[dh]>') | ForEach-Object { $_.Groups[1].Value })
    if ($ch.Count -lt 2) { continue }
    $ft = ($ch[0] -replace '<[^>]+>','').Trim()
    if ($ft -match '^(\d+)限$') { $curJigen=[int]$matches[1]; $gt=($ch[1] -replace '<[^>]+>','').Trim(); $dc=@(if ($ch.Count -gt 2) { $ch[2..($ch.Count-1)] } else { @() }) }
    elseif ($ft -eq 'その他') { $curJigen=-1;             $gt=($ch[1] -replace '<[^>]+>','').Trim(); $dc=@(if ($ch.Count -gt 2) { $ch[2..($ch.Count-1)] } else { @() }) }
    else                       {                            $gt=$ft;    $dc=@($ch[1..($ch.Count-1)]) }
    if ($curJigen -eq $jigen -and ($gt -eq '前期' -or $gt -eq '後期')) {
      $di = $youbiNum - 1
      if ($di -ge 0 -and $di -lt $dc.Count -and $dc[$di] -match "__doPostBack\('([^']+)'") { return $matches[1] }
    }
  }
  return $null
}
function Get-Detail($ss,$jcUrl,$jcHtml,$ctlId){
  $b = [ordered]@{
    '__EVENTTARGET'=$ctlId; '__EVENTARGUMENT'=''
    '__VIEWSTATE'          = (Get-Token $jcHtml '__VIEWSTATE')
    '__VIEWSTATEGENERATOR' = (Get-Token $jcHtml '__VIEWSTATEGENERATOR')
    '__EVENTVALIDATION'    = (Get-Token $jcHtml '__EVENTVALIDATION')
  }
  return (Fetch @{ Uri=$jcUrl; WebSession=$ss; Method='Post'; Body=(To-Form $b); ContentType='application/x-www-form-urlencoded' }).Content
}
# 明細から 指定コード の行を探し、集計と 指定日(MM/DD)のマークを返す
function Parse-DetailMark($detailHtml,$code,$mmdd){
  $out = @{ mark=$null; survey=$null; present=$null; absent=$null; late=$null; found=$false }
  $tm = [regex]::Match($detailHtml, '<table[^>]*class="roll_man_table"[\s\S]*?</table>')
  if (-not $tm.Success) { return $out }
  foreach ($rowM in [regex]::Matches($tm.Value, '<tr[^>]*>([\s\S]*?)</tr>')) {
    $cells = @([regex]::Matches($rowM.Groups[1].Value, '<t[dh][^>]*>([\s\S]*?)</t[dh]>') | ForEach-Object {
      ((Html-Decode ($_.Groups[1].Value -replace '<[^>]+>','')) -replace '\s+',' ').Trim()
    })
    if ($cells.Count -lt 5 -or $cells[0] -ne $code) { continue }
    $out.found = $true
    if ($cells[3] -match '(\d+)\s*/\s*(\d+)\s*/\s*(\d+)\s*/\s*(\d+)') {
      $out.survey=[int]$matches[1]; $out.present=[int]$matches[2]; $out.absent=[int]$matches[3]; $out.late=[int]$matches[4]
    }
    # mmdd はゼロ埋め(例 07/15)。ポータルが "7/15" のように非ゼロ埋め表示でも拾えるようにする
    $dp = '0?{0}\s*/\s*0?{1}' -f [int]($mmdd -split '/')[0], [int]($mmdd -split '/')[1]
    foreach ($c in $cells) { if ($c -match ($dp + '\s*(\S+)')) { $out.mark = $matches[1]; break } }
    break
  }
  return $out
}
function Mark-Label($mark){
  if ($mark -match '○|◯')        { return '出席' }
  if ($mark -match '△|▲|遅|早')   { return '遅刻・早退' }
  if ($mark -match '×|✕|／|/|欠') { return '欠席' }
  return $mark
}
# ↑↓ + Enter で選択（入力リダイレクト時は番号入力）。R=再取得(-2)、自動リロード(-3)、Esc/キャンセル=-1。
# ハイライトは文字末尾までの幅。$startIdx=初期ハイライト / $keepInput=$true なら入力バッファを消さない。
function Select-Menu($items, $sync, $rev0, $wasLive, $startIdx, $keepInput){
  if ([Console]::IsInputRedirected) {
    if ($items.Count -eq 0) {
      Write-Host '（入力可能な授業がありません）'
      $s = Read-Host 'r=再取得 / それ以外=終了'
      if ("$s".Trim().ToLower() -eq 'r') { return -2 } else { return -1 }
    }
    for ($i=0; $i -lt $items.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i+1), $items[$i]) }
    $s = Read-Host '番号を選択（r=再取得）'
    if ("$s".Trim().ToLower() -eq 'r') { return -2 }
    $n = 0; [void][int]::TryParse($s, [ref]$n); return ($n - 1)
  }
  Write-Host '↑↓ 選択  Enter 決定  R 再取得  Esc 中止'
  Write-Host ''
  $idx = 0
  if ($startIdx) { $idx = [Math]::Max(0, [Math]::Min([int]$startIdx, [Math]::Max(0, $items.Count - 1))) }
  try { [Console]::CursorVisible = $false } catch {}
  $top = [Console]::CursorTop
  $maxw = 0
  foreach ($it in $items) { $dw = Disp-Width ("  $it"); if ($dw -gt $maxw) { $maxw = $dw } }
  if ($maxw -eq 0) { $maxw = 40 }
  $maxw = [Math]::Min($maxw, [Console]::WindowWidth - 1)
  if (-not $keepInput) { Flush-Input }   # 通常は直前の長押し等で溜まったキーを破棄（自動リロード継続時は温存）
  while ($true) {
    try { [Console]::SetCursorPosition(0, $top) } catch { $top = [Console]::CursorTop }
    if ($items.Count -eq 0) {
      Write-Host ('（入力可能な授業がありません — R で再取得）'.PadRight($maxw)) -ForegroundColor DarkGray
    } else {
      for ($i=0; $i -lt $items.Count; $i++) {
        $text = ("{0} {1}" -f $(if ($i -eq $idx) { '>' } else { ' ' }), $items[$i])
        $line = $text + (' ' * [Math]::Max(0, ($maxw - (Disp-Width $text))))
        if ($i -eq $idx) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
        else            { Write-Host $line }
      }
    }
    # キー入力を待つ間、裏の取得で受付中の授業が変わったら（またはキャッシュ表示中にログイン完了したら）自動でリロード
    $k = $null
    while ($null -eq $k) {
      if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); break }
      if ($sync -and (((-not $wasLive) -and $sync.loggedIn -and $sync.portal) -or $sync.credNeeded -or ($sync.rev -ne $rev0))) {
        Start-Sleep -Milliseconds 40
        if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); break }   # 直前に押されたキーを優先（Enter を取りこぼさない）
        $script:MenuIdx = $idx                                                    # ハイライト中の項目を呼び出し側へ引き継ぐ
        try { [Console]::CursorVisible = $true } catch {}; return -3              # 自動リロード（入力バッファは破棄しない）
      }
      Start-Sleep -Milliseconds 70
    }
    if     ($k.Key -eq 'UpArrow')   { if ($items.Count -gt 0) { $idx = ($idx - 1 + $items.Count) % $items.Count } }
    elseif ($k.Key -eq 'DownArrow') { if ($items.Count -gt 0) { $idx = ($idx + 1) % $items.Count } }
    elseif ($k.Key -eq 'Enter')     { if ($items.Count -gt 0) { try { [Console]::CursorVisible = $true } catch {}; return $idx } }
    elseif ($k.Key -eq 'Escape')    { try { [Console]::CursorVisible = $true } catch {}; return -1 }
    elseif ($k.Key -eq 'R')         { try { [Console]::CursorVisible = $true } catch {}; return -2 }
  }
}
# ポータルHTML + 授業名マップ から開講中(RN)の授業リストを作る
function Build-Options($portalHtml, $nameByCode){
  $d = Html-Decode $portalHtml
  $infos = @([regex]::Matches($d, "'RN',\s*'([0-9]{4},[^']+?,[0-9]{8},[0-9]+,[0-9]+,[0-9]+)'") |
             ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  $opts = @()
  foreach ($info in $infos) {
    $f = $info -split ','
    if ($f.Count -lt 8) { continue }
    $opts += [pscustomobject]@{ Info=$info; Jigen=[int]$f[7]; Code=$f[2]; Youbi=[int]$f[6]; Name=$(if ($nameByCode.ContainsKey($f[2])) { $nameByCode[$f[2]] } else { '' }) }
  }
  return @($opts | Sort-Object Jigen)
}

# ============ 非同期: バックグラウンドでログインしながら前面で選択・入力 ============
# worker: ログイン成功まで再試行し、成功後はポータルを定期取得して $sync.portal を更新。
$WORKER = {
  $ProgressPreference='SilentlyContinue'
  function GT($h,$id){ if($h -match ('id="'+[regex]::Escape($id)+'"[^>]*value="([^"]*)"')){$matches[1]}else{''} }
  function TF($o){ ($o.GetEnumerator()|ForEach-Object{[Uri]::EscapeDataString([string]$_.Key)+'='+[Uri]::EscapeDataString([string]$_.Value)}) -join '&' }
  function SIG($h){ ( [regex]::Matches(($h -replace '&#39;',"'"), "'RN',\s*'([0-9]{4},[^']+?,[0-9]{8},[0-9]+,[0-9]+,[0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object ) -join ';' }
  try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {}
  while (-not $sync.stop) {
    if (-not $sync.loggedIn) {
      if ($sync.credNeeded) { Start-Sleep -Milliseconds 300; continue }
      try {
        $s=New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $r=Invoke-WebRequest -Uri $LOGIN -WebSession $s -UseBasicParsing -TimeoutSec $TimeoutSec
        $b=[ordered]@{'__LASTFOCUS'='';'__EVENTTARGET'='';'__EVENTARGUMENT'='';'__VIEWSTATE'=(GT $r.Content '__VIEWSTATE');'__VIEWSTATEGENERATOR'=(GT $r.Content '__VIEWSTATEGENERATOR');'__EVENTVALIDATION'=(GT $r.Content '__EVENTVALIDATION');'txtUserid'=$sync.uid;'txtUserpw'=$sync.pw;'ibtnLogin.x'='10';'ibtnLogin.y'='10'}
        $r=Invoke-WebRequest -Uri $LOGIN -WebSession $s -Method Post -Body (TF $b) -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec $TimeoutSec
        if ($r.Content -match 'id="txtUserpw"') { $sync.status='cred'; $sync.credNeeded=$true }
        elseif ($r.Content -match 'トップ' -or $r.Content -match 'putPopupLinkSetFlag') { $sync.session=$s; $sync.portal=$r.Content; $sync.rnSig=(SIG $r.Content); $sync.loggedIn=$true; $sync.status='connected' }
        else { $sync.status='busy'; Start-Sleep -Seconds 2 }
      } catch { $sync.status='conn'; Start-Sleep -Seconds 2 }
    } else {
      try {
        $p=Invoke-WebRequest -Uri $PORTAL -WebSession $sync.session -UseBasicParsing -TimeoutSec $TimeoutSec; $sync.portal=$p.Content
        $s2=(SIG $p.Content); if ($s2 -ne '' -and $s2 -ne $sync.rnSig) { $sync.rnSig=$s2; $sync.rev=[int]$sync.rev+1 }  # 空(一時的な不完全応答)では更新しない
      }
      catch { $sync.loggedIn=$false; $sync.session=$null; $sync.status='lost' }
      for ($z=0; $z -lt 20 -and -not $sync.stop; $z++){ Start-Sleep -Milliseconds 100 }
    }
  }
}
function Start-Worker($sync){
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync',$sync)
  $rs.SessionStateProxy.SetVariable('LOGIN',$LOGIN)
  $rs.SessionStateProxy.SetVariable('PORTAL',$PORTAL)
  $rs.SessionStateProxy.SetVariable('TimeoutSec',$script:TimeoutSec)
  $psh=[powershell]::Create(); $psh.Runspace=$rs; [void]$psh.AddScript($WORKER)
  return @{ ps=$psh; rs=$rs; handle=$psh.BeginInvoke() }
}
function Stop-Worker($w,$sync){
  if (-not $w) { return }
  $sync.stop=$true
  try { if (-not $w.handle.IsCompleted) { [void]$w.ps.EndInvoke($w.handle) } } catch {}
  try { $w.ps.Dispose() } catch {}
  try { $w.rs.Close() } catch {}
  try { $w.rs.Dispose() } catch {}
}
# 現在の選択肢: ログイン済みなら開講中ライブ、未ならキャッシュの「今日の授業」
function Cur-Options($sync, $nameByCode, $cache){
  if ($sync.loggedIn -and $sync.portal) { return Build-Options $sync.portal $nameByCode }
  $ty=[int](Get-Date).DayOfWeek; if($ty -eq 0){$ty=7}
  $pool=@(); if($cache -and $cache.courses){ $pool=@($cache.courses|Where-Object{$_.code}) }
  $td=@($pool|Where-Object{[int]$_.youbi -eq $ty}); $src= if($td.Count){$td}else{$pool}
  return @($src|Sort-Object youbi,jigen|ForEach-Object{ [pscustomobject]@{ Info=''; Jigen=[int]$_.jigen; Code="$($_.code)"; Youbi=[int]$_.youbi; Name="$($_.name)" } })
}
# ポータルHTMLから 授業名マップ を作り、履修の検知・保存も行う。$nameByCode を返す。
function Sync-Cache($portalHtml, $cache, $userId, $userPw){
  $dhtml = Html-Decode $portalHtml
  $nameBySuffix = @{}
  foreach ($nm in [regex]::Matches($dhtml, '大学<br\s*/?>([^<]+)<br\s*/?>[^<]*<div[^>]*id="[^"]*(div_(?:day|week|month)_\d+)"')) {
    $sfx = $nm.Groups[2].Value
    if (-not $nameBySuffix.ContainsKey($sfx)) { $nameBySuffix[$sfx] = $nm.Groups[1].Value.Trim() }
  }
  $nc = @{}
  foreach ($lk in [regex]::Matches($dhtml, "'[0-9]{4},[^,]+,([^,]+),[^']*'[^<]*?lbtn_(?:RN|EU)_(div_(?:day|week|month)_\d+)")) {
    $code = $lk.Groups[1].Value; $sfx = $lk.Groups[2].Value
    if ($nameBySuffix.ContainsKey($sfx) -and -not $nc.ContainsKey($code)) { $nc[$code] = $nameBySuffix[$sfx] }
  }
  $seen = @{}; $courses = @()
  foreach ($mm in [regex]::Matches($dhtml, "'([0-9]{4},[^']+?,[0-9]{8},[0-9]+,[0-9]+,[0-9]+)'")) {
    $f = $mm.Groups[1].Value -split ','
    if ($f.Count -lt 8) { continue }
    $key = "$($f[2])|$($f[6])|$($f[7])"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $courses += [pscustomobject]@{ code=$f[2]; name=$(if ($nc.ContainsKey($f[2])) { $nc[$f[2]] } else { '' }); youbi=[int]$f[6]; jigen=[int]$f[7] }
  }
  if ($courses.Count -gt 0) {
    if ($cache -and $cache.courses) {
      $prevName = @{}
      foreach ($pc in @($cache.courses)) { if ($pc.code -and $pc.name) { $prevName["$($pc.code)"] = $pc.name } }
      foreach ($c in $courses) { if ([string]::IsNullOrEmpty($c.name) -and $prevName.ContainsKey($c.code)) { $c.name = $prevName[$c.code] } }
    }
    $newHash = Compute-CourseHash $courses
    if ($cache -and $cache.hash -and $cache.hash -ne $newHash) {
      $oldKeys = @(); if ($cache.courses) { $oldKeys = @($cache.courses | ForEach-Object { "$($_.code)|$($_.youbi)|$($_.jigen)" }) }
      $newKeys = @($courses | ForEach-Object { "$($_.code)|$($_.youbi)|$($_.jigen)" })
      $added   = @($courses        | Where-Object { "$($_.code)|$($_.youbi)|$($_.jigen)" -notin $oldKeys })
      $removed = @(@($cache.courses) | Where-Object { "$($_.code)|$($_.youbi)|$($_.jigen)" -notin $newKeys })
      $script:ChurnLines = @('※ 履修が前回と変わっています')
      foreach ($c in $added)   { $script:ChurnLines += ("  + {0}曜{1}限 {2} {3}" -f $YOUBI[[int]$c.youbi], $c.jigen, $c.code, $c.name) }
      foreach ($c in $removed) { $script:ChurnLines += ("  - {0}曜{1}限 {2} {3}" -f $YOUBI[[int]$c.youbi], $c.jigen, $c.code, $c.name) }
    }
    Write-CacheState $script:TimeoutSec $(if($cache){$cache.calib}else{$null}) $courses $newHash (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') $userId $userPw
  }
  return $nc
}
# 送信＋出欠明細確認＋結果表示
function Do-Punch($main, $chosen, $attPw, $quiet){
  $attPw = To-Han "$attPw"   # 全角で入力されたパスワード（全角数字など）は通らないので半角へ
  $dstr = ($chosen.Info -split ',')[5]
  if ("$dstr" -notmatch '^[0-9]{8}$') { throw "授業情報の日付フィールドが不正です: '$dstr' (Info=$($chosen.Info))" }
  $mmdd = $dstr.Substring(4,2) + '/' + $dstr.Substring(6,2)
  if (-not $quiet) { Write-Host ''; Write-Host '出席を送信中...' }
  $rp2 = Fetch @{ Uri=$PORTAL; WebSession=$main.ss }
  $punchBody = [ordered]@{
    'tabCalender_ClientState' = '{"ActiveTabIndex":1,"TabState":[true,true,true]}'
    '__EVENTTARGET'=''; '__EVENTARGUMENT'=''
    '__VIEWSTATE'          = (Get-Token $rp2.Content '__VIEWSTATE')
    '__VIEWSTATEGENERATOR' = (Get-Token $rp2.Content '__VIEWSTATEGENERATOR')
    '__EVENTVALIDATION'    = (Get-Token $rp2.Content '__EVENTVALIDATION')
    'txtPassword'          = $attPw
    'hdnSyussekiPwd'=''; 'hdnLiknClickKbn'='RN'
    'hdnLinkTransitionInfo'= $chosen.Info
    'ibtnOK.x'='10'; 'ibtnOK.y'='10'
  }
  $rr = Fetch @{ Uri=$PORTAL; WebSession=$main.ss; Method='Post'; Body=(To-Form $punchBody); ContentType='application/x-www-form-urlencoded' }
  $resp = $rr.Content
  $msg = ''
  if ($resp -match 'id="lblMessage"[^>]*>([\s\S]*?)</') { $msg = (Html-Decode ($matches[1] -replace '<[^>]+>','')).Trim() }
  $wrongPw = ($msg -match '正しくありません|一致しません|違います')
  $closed  = ($msg -match '可能時間|時間外|受付時間|時間内では|時間ではありません')  # 「出席登録の可能時間ではありません」等
  $okMsg   = ($msg -match '登録しました|受け付けました|受付けました|完了しました|完了いたしました|登録済み|すでに登録|既に登録')  # 肯定的な完了文言のみを成功とみなす
  $dm = $null
  if (-not $wrongPw -and -not $closed) {
    try {
      $jc = Goto-Jc1010 $main.ss $resp
      $ctlId = Get-SlotCtlId $jc.html $chosen.Youbi $chosen.Jigen
      if ($ctlId) { $dm = Parse-DetailMark (Get-Detail $main.ss $jc.url $jc.html $ctlId) $chosen.Code $mmdd }
    } catch { $dm = $null }
  }
  if ($quiet -and $closed) {   # 自動再送信中の「時間外」は1行だけ表示して即返す
    Write-Host ("  {0}  時間外: {1}" -f (Get-Date).ToString('HH:mm:ss'), $(if ($msg) { $msg } else { '可能時間ではありません' })) -ForegroundColor DarkGray
    return 'closed'
  }
  Write-Host ''
  Write-Host '--------------------------------------------'
  Write-Host ("対象      : {0}曜 {1}限 {2} ({3})" -f $YOUBI[$chosen.Youbi], $chosen.Jigen, $chosen.Name, $chosen.Code)
  Write-Host ("サーバ応答: {0}" -f ($(if ($msg) { $msg } else { '(メッセージなし)' })))
  if ($dm -and $null -ne $dm.survey) { Write-Host ("出欠集計  : 調査{0} / 出席{1} / 欠席{2} / 遅早{3}" -f $dm.survey, $dm.present, $dm.absent, $dm.late) }
  if ($dm -and $dm.mark)             { Write-Host ("本日の記録: {0}  {1}  ({2})" -f $mmdd, $dm.mark, (Mark-Label $dm.mark)) }
  Write-Host '--------------------------------------------'
  if ($wrongPw) { Write-Host '結果: [失敗] 出席パスワードが違います。登録されていません。' -ForegroundColor Red }
  elseif ($dm -and $dm.mark) {
    if ($dm.mark -match '○|◯') { Write-Host ('結果: [正常] 出席として登録されました（本日 {0} = ○）。' -f $mmdd) -ForegroundColor Green }
    elseif ($dm.mark -match '△|▲|遅|早') { Write-Host ('結果: [遅刻・早退] 本日 {0} = {1} で登録されています。' -f $mmdd, $dm.mark) -ForegroundColor Yellow }
    elseif ($dm.mark -match '×|✕|／|/|欠') { Write-Host ('結果: [欠席扱い] 本日 {0} = {1}。反映されていない可能性があります。' -f $mmdd, $dm.mark) -ForegroundColor Red }
    else { Write-Host ('結果: [要確認] 本日 {0} のマーク = {1}' -f $mmdd, $dm.mark) -ForegroundColor Yellow }
  }
  elseif ($closed) { Write-Host ('結果: [時間外] {0}' -f $(if ($msg) { $msg } else { '出席登録の可能時間ではありません' })) -ForegroundColor Yellow }
  elseif ($okMsg) { Write-Host ('結果: [成功] {0}（明細のマークは取得できませんでした）' -f $msg) -ForegroundColor Green }
  else { Write-Host '結果: [要確認] 応答を判定できませんでした。ポータルで確認してください。' -ForegroundColor Yellow }
  # 呼び出し側の分岐用ステータス（ok=完了 / wrongpw=パスワード誤り / retry=時間外・判定不能で再試行可）
  if ($wrongPw) { return 'wrongpw' }
  if ($dm -and $dm.mark) { return 'ok' }                        # マークが付いている＝登録済み
  if ($closed) { return 'closed' }                              # 可能時間外 → 呼び出し側で自動再送信
  if ($okMsg) { return 'ok' }                                   # 肯定的な完了文言
  return 'retry'                                                # 判定不能 → 再試行できる
}
# 分が変わるまで待つ（対話時は Esc で中止 → $false。自動実行では待たない）
function Wait-MinuteChange {
  if ([Console]::IsInputRedirected) { Start-Sleep -Milliseconds 200; return $true }
  $m0 = (Get-Date).Minute
  Flush-Input
  while ((Get-Date).Minute -eq $m0) {
    try { if ([Console]::KeyAvailable -and ([Console]::ReadKey($true)).Key -eq 'Escape') { return $false } } catch {}
    Start-Sleep -Milliseconds 200
  }
  return $true
}
# 可能時間外のとき、分が変わってから3秒間隔で5回、時間内になるまで自動送信する
# 返り値: 'ok' / 'wrongpw' / 'retry' / 'cancel'(Esc) / 'closed'(自動実行で打ち切り)
function Auto-Retry-Closed($main, $chosen, $attPw){
  Write-Host ''
  Write-Host '可能時間外です。分が変わってから3秒間隔で5回、時間内になるまで自動送信します（Esc で中止）。' -ForegroundColor Cyan
  $cycles = 0
  while ($true) {
    if (-not (Wait-MinuteChange)) { return 'cancel' }
    for ($i = 1; $i -le 5; $i++) {
      $r = Do-Punch $main $chosen $attPw $true
      if ($r -ne 'closed') { return $r }
      if ($i -lt 5) { if (-not (Wait-Or-Abort 3)) { return 'cancel' } }
    }
    $cycles++
    if ([Console]::IsInputRedirected -and $cycles -ge 2) { return 'closed' }   # 自動実行では無限ループにしない
  }
}

# ---- キャッシュ読込・タイムアウト適用・ログイン情報取得 ----
$cache = Load-Cache
if ($cache -and $cache.timeoutSec) { $tmpTo=0; if ([int]::TryParse("$($cache.timeoutSec)", [ref]$tmpTo) -and $tmpTo -gt 0) { $script:TimeoutSec = $tmpTo } }
$UserId = if ($cache -and $cache.userId) { [string]$cache.userId } else { '' }
$UserPw = if ($cache -and $cache.userPw) { [string]$cache.userPw } else { '' }

# ---- calibrate モード ----
if ($args.Count -ge 1 -and "$($args[0])".Trim().ToLower() -eq 'calibrate') {
  $n = 100
  if ($args.Count -ge 2) { $tmp=0; if ([int]::TryParse("$($args[1])", [ref]$tmp) -and $tmp -gt 0) { $n = $tmp } }
  Write-Host ("タイムアウト計測: ログインページを {0} 回取得します..." -f $n)
  $durs = New-Object System.Collections.Generic.List[double]
  $fail = 0
  for ($i=1; $i -le $n; $i++) {
    try {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $null = Invoke-WebRequest -Uri $LOGIN -UseBasicParsing -TimeoutSec 60
      $sw.Stop(); $durs.Add($sw.Elapsed.TotalSeconds)
    } catch { $fail++ }
    if ($i % 20 -eq 0) { Write-Host ("  {0}/{1}  (失敗 {2})" -f $i, $n, $fail) }
    Start-Sleep -Milliseconds 80
  }
  if ($durs.Count -eq 0) { Fail 'すべて失敗しました。接続を確認してください。' }
  $max=($durs|Measure-Object -Maximum).Maximum; $min=($durs|Measure-Object -Minimum).Minimum; $avg=($durs|Measure-Object -Average).Average
  $timeout=[int][Math]::Ceiling($max*3); if ($timeout -lt 3) { $timeout=3 }
  $calib=[pscustomobject]@{ samples=$durs.Count; fail=$fail; minSec=[Math]::Round($min,3); maxSec=[Math]::Round($max,3); avgSec=[Math]::Round($avg,3); at=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
  Write-CacheState $timeout $calib $(if($cache){$cache.courses}else{@()}) $(if($cache){$cache.hash}else{''}) $(if($cache){$cache.updated}else{''}) $UserId $UserPw
  Write-Host ''
  Write-Host ("計測完了: 成功 {0}/{1}  min={2:N3}s  max={3:N3}s  avg={4:N3}s" -f $durs.Count, $n, $min, $max, $avg) -ForegroundColor Green
  Write-Host ("→ タイムアウト = max×3 = {0}s に設定しました（キャッシュ保存）" -f $timeout) -ForegroundColor Green
  Pause-Exit 0
}

Write-Host '============================================'
Write-Host ' 出席パスワード 直接入力ツール'
Write-Host '============================================'

# 初回でログイン情報が無ければフォームで入力
if ([string]::IsNullOrWhiteSpace($UserId) -or [string]::IsNullOrWhiteSpace($UserPw)) {
  $form = Edit-Login-Form $UserId $UserPw
  if (-not $form.submit) { Pause-Exit 1 }
  $UserId = $form.userId; $UserPw = $form.userPw
  Write-CacheState $script:TimeoutSec $(if($cache){$cache.calib}else{$null}) $(if($cache){$cache.courses}else{@()}) $(if($cache){$cache.hash}else{''}) $(if($cache){$cache.updated}else{''}) $UserId $UserPw
  $cache = Load-Cache
}

# バックグラウンドでログイン開始（裏で継続）。前面では授業選択・パスワード入力を進められる。
$sync = [hashtable]::Synchronized(@{ stop=$false; loggedIn=$false; session=$null; portal=$null; status='init'; credNeeded=$false; uid=$UserId; pw=$UserPw; rev=0; rnSig='' })
$worker = Start-Worker $sync
$nameByCode = @{}
if ($cache -and $cache.courses) { foreach ($c in @($cache.courses)) { if ($c.code -and $c.name) { $nameByCode["$($c.code)"] = $c.name } } }
$synced = $false

Write-Host ''
Write-Host '授業を選択してパスワードを入力してください。' -ForegroundColor DarkGray

$chosen = $null; $attPw = $null; $preferKey = $null; $keepInput = $false
while (-not $chosen) {
  # 認証失敗 → フォームで再入力
  if ($sync.credNeeded) {
    $preferKey = $null; $keepInput = $false
    Write-Host ''
    Write-Host 'ログインに失敗しました。ユーザー名／パスワードを再入力してください。' -ForegroundColor Yellow
    $form = Edit-Login-Form $UserId $UserPw
    if (-not $form.submit) { Stop-Worker $worker $sync; Pause-Exit 1 }
    $UserId = $form.userId; $UserPw = $form.userPw; $sync.uid = $UserId; $sync.pw = $UserPw
    Write-CacheState $script:TimeoutSec $(if($cache){$cache.calib}else{$null}) $(if($cache){$cache.courses}else{@()}) $(if($cache){$cache.hash}else{''}) $(if($cache){$cache.updated}else{''}) $UserId $UserPw
    $cache = Load-Cache
    $sync.credNeeded = $false
    Start-Sleep -Milliseconds 500
    continue
  }
  # 表示できる授業がまだ無い（初回でキャッシュ無し）／自動テスト時はログイン完了を待つ
  if (-not $sync.loggedIn -and -not $sync.credNeeded) {
    $co0 = Cur-Options $sync $nameByCode $cache
    if ([Console]::IsInputRedirected -or $co0.Count -eq 0) {
      $wc = 0
      while (-not $sync.loggedIn -and -not $sync.credNeeded) {
        if ([Console]::IsInputRedirected) { Start-Sleep -Milliseconds 100; $wc++; if ($wc -ge 400) { break } }
        else { Write-Host "`rログイン待ち...             " -NoNewline; if (-not (Wait-Or-Abort 0.5)) { Stop-Worker $worker $sync; Pause-Exit 0 } }
      }
      if (-not [Console]::IsInputRedirected) { Write-Host '' }
    }
    if ($sync.credNeeded) { continue }
  }
  # ポータル取得後、履修同期を一度だけ
  if ($sync.loggedIn -and $sync.portal -and -not $synced) { $nameByCode = Sync-Cache $sync.portal $cache $UserId $UserPw; $cache = Load-Cache; $synced = $true }

  $opts = @(Cur-Options $sync $nameByCode $cache)
  $keys = @($opts | ForEach-Object { "$($_.Code)|$($_.Youbi)|$($_.Jigen)" })
  # 自動リロード直後は、前にハイライトしていた授業を識別子で引き継ぐ（消えていたら入力を捨てて誤選択を防ぐ）
  $startIdx = 0
  if ($preferKey) {
    $ix = [array]::IndexOf($keys, $preferKey)
    if ($ix -ge 0) { $startIdx = $ix } else { Flush-Input; $keepInput = $false }
    $preferKey = $null
  }
  # 対話時は毎回クリアして同じ位置に描き直す（R 再取得などで下へ伸び続けないように）
  if (-not [Console]::IsInputRedirected) {
    try { Clear-Host } catch {}
    Write-Host '============================================'
    Write-Host ' 出席パスワード 直接入力ツール'
    Write-Host '============================================'
    if ($script:ChurnLines.Count) { Write-Host ''; foreach ($ln in $script:ChurnLines) { Write-Host $ln -ForegroundColor Magenta } }
  }
  Write-Host ''
  Write-Host ("入力可能な授業（{0}／{1}）:" -f $(if($sync.loggedIn){'ライブ'}else{'キャッシュ'}), (Get-Date).ToString('HH:mm:ss'))
  $labels = @($opts | ForEach-Object { "{0}曜 {1}限   {2}  ({3})" -f $YOUBI[$_.Youbi], $_.Jigen, $(if($_.Name){$_.Name}else{'?'}), $_.Code })
  $rev0 = $sync.rev; $wasLive = [bool]$sync.loggedIn
  $sel = Select-Menu $labels $sync $rev0 $wasLive $startIdx $keepInput
  $keepInput = $false
  if ($sel -eq -3) {   # 自動リロード：ハイライトを引き継ぎ、入力は捨てない
    if ($script:MenuIdx -ge 0 -and $script:MenuIdx -lt $keys.Count) { $preferKey = $keys[$script:MenuIdx]; $keepInput = $true }
    continue
  }
  if ($sel -eq -2) { Flush-Input; Start-Sleep -Milliseconds 200; Flush-Input; continue }   # R=再取得（長押し対策で入力を吸収）
  if ($sel -lt 0) { Stop-Worker $worker $sync; Pause-Exit 0 }                                # Esc/中止
  if ($sel -ge $opts.Count) { continue }
  $selOpt = $opts[$sel]

  Flush-Input
  $pw = $null
  while ($true) {
    $pwr = Read-Pw-OrCancel ("出席パスワード（{0}）" -f $selOpt.Code)
    if ($null -eq $pwr) { break }                 # Esc（自動実行では空Enter）→ 選択へ戻る
    if ($pwr -ne '') { $pw = $pwr; break }
    Write-Host 'もう一度入力してください。' -ForegroundColor Yellow
  }
  if ($null -eq $pw) { continue }

  # ログイン完了を待つ（裏で継続中）。認証が必要になったら上へ。自動実行時は約40秒で打ち切る。
  $wc2 = 0
  while (-not $sync.loggedIn -and -not $sync.credNeeded) {
    Write-Host "`rログイン待ち...             " -NoNewline
    if ([Console]::IsInputRedirected) { Start-Sleep -Milliseconds 400; $wc2++; if ($wc2 -ge 100) { break } }
    elseif (-not (Wait-Or-Abort 0.6)) { Stop-Worker $worker $sync; Pause-Exit 0 }
  }
  Write-Host ''
  if ($sync.credNeeded) { continue }
  if (-not $sync.loggedIn) { Stop-Worker $worker $sync; Fail 'ログインが完了しませんでした（サーバ応答なし）。時間をおいて再実行してください。' }
  if (-not $synced -and $sync.portal) { $nameByCode = Sync-Cache $sync.portal $cache $UserId $UserPw; $cache = Load-Cache; $synced = $true }

  # 送信直前にライブで受付状況を確認。変わっていたら（パスワード入力後でも）選択に戻す。
  $live = Build-Options $sync.portal $nameByCode
  $mt = @($live | Where-Object { $_.Code -eq $selOpt.Code -and [int]$_.Youbi -eq [int]$selOpt.Youbi -and [int]$_.Jigen -eq [int]$selOpt.Jigen })
  if ($mt.Count -eq 0) {
    Write-Host ("{0} は現在受付中ではありません（一覧が変わりました）。選び直してください。" -f $selOpt.Code) -ForegroundColor Yellow
    Start-Sleep -Milliseconds 900
    continue
  }
  $chosen = $mt[0]; $attPw = $pw
}

Stop-Worker $worker $sync     # 以降は前面がセッションを専有して送信
# worker のポータル再取得失敗などで直前にセッションが失われることがある。null なら前面で張り直す。
$mainSess = @{ ss = $sync.session }
if (-not $mainSess.ss) {
  Write-Host ''
  Write-Host 'セッションを再確立しています...' -ForegroundColor DarkGray
  $rl = Try-Login $UserId $UserPw
  if ($rl.ok) { $mainSess.ss = $rl.ss }
  else { Fail 'ログインセッションを確立できませんでした。時間をおいて再実行してください。' }
}
# 送信。パスワード誤りなら終了せず再入力できる（Esc で終了 / 空Enterはもう一度）。
# 送信時の通信失敗などは握らずに明示表示して終了（ウィンドウを閉じない）。
try {
  while ($true) {
    $res = Do-Punch $mainSess $chosen $attPw
    if ($res -eq 'closed') { $res = Auto-Retry-Closed $mainSess $chosen $attPw }   # 時間外 → 時間内になるまで自動送信
    if ($res -eq 'ok') { break }
    if ($res -eq 'cancel' -or $res -eq 'closed') { break }                          # Esc 中止 / 自動実行で打ち切り
    if ($res -eq 'wrongpw') {
      $np = $null
      while ($true) {
        Write-Host ''
        Flush-Input
        $r = Read-Pw-OrCancel ("パスワードが違います。再入力（{0}）／Esc で終了" -f $chosen.Code)
        if ($null -eq $r) { $np = $null; break }   # Esc（自動実行では空Enter）→ 終了
        if ($r -ne '') { $np = $r; break }          # 入力あり → 再送信
        # 空Enter → もう一度
      }
      if ($null -eq $np) { break }
      $attPw = $np
      continue
    }
    # 'retry'：判定不能 → 同じパスワードで手動再試行できる（Esc で終了）
    Write-Host ''
    if (-not (Confirm-Retry)) { break }
  }
} catch {
  Fail ("送信中にエラーが発生しました: {0}" -f $_.Exception.Message)
}
Pause-Exit 0
