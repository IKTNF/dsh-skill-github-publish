<#
.SYNOPSIS
    把本地目录发布到 GitHub —— 无需安装 gh CLI。

.DESCRIPTION
    用 Git Credential Manager 已缓存的凭据调 GitHub REST API 建仓库，
    然后 git init / commit / push，最后克隆回来逐文件校验。
    幂等：仓库已存在时复用，不会报错。

    认证细节见 SKILL.md 第 1 步；脚本不会打印令牌。

.PARAMETER RepoDir
    要发布的本地目录（绝对路径）。

.PARAMETER Name
    GitHub 仓库名（建议 ASCII、kebab-case）。

.PARAMETER Description
    仓库描述，可含中文（脚本按 UTF-8 字节提交）。

.PARAMETER Private
    建为私有仓库；默认公开。

.PARAMETER Topics
    话题标签，如 -Topics kaoyan,english-writing

.PARAMETER Owner
    仓库归属账号；默认用令牌调 /user 自动探测。

.PARAMETER Message
    提交信息；默认 "Initial publish from <目录名>"。多行可用 here-string。

.PARAMETER SkipVerify
    跳过克隆校验（不推荐）。

.EXAMPLE
    # 推荐：用 scriptblock 调用，绕开执行策略限制
    $sb = [scriptblock]::Create((Get-Content .\scripts\publish.ps1 -Raw))
    & $sb -RepoDir 'C:\proj\demo' -Name 'demo-repo' -Description '演示仓库' -Topics demo,tools

.EXAMPLE
    # 也可以直接以文件运行（需放开执行策略）
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1 `
      -RepoDir 'C:\proj\demo' -Name 'demo-repo' -Private
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoDir,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Description = '',
    [switch]$Private,
    [string[]]$Topics = @(),
    [string]$Message,
    [string]$Owner,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:Failures = @()

function Write-Step { param([string]$m) Write-Host "`n$m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  v $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "  x $m" -ForegroundColor Red; $script:Failures += $m }

# --------------------------------------------------------------------------
# 1. 认证
# --------------------------------------------------------------------------
function Get-GitHubToken {
    <# 用 .NET 进程显式写 stdin。
       切勿用 PowerShell 字符串管道喂 git credential fill —— 会间歇性报
       "refusing to work with credential missing protocol field"。 #>
    for ($i = 1; $i -le 6; $i++) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = 'git'
        $psi.Arguments              = 'credential fill'
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write("protocol=https`nhost=github.com`n`n")
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit(25000) | Out-Null

        $pw = @($out -split "`r?`n" | Where-Object { $_ -like 'password=*' })
        if ($pw.Count -ge 1) {
            $t = (($pw[0] -split '=', 2)[1]).Trim()
            if ($t) {
                try {
                    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -TimeoutSec 20 -Headers @{
                        Authorization = "Bearer $t"; 'User-Agent' = 'dsh-skill'; Accept = 'application/vnd.github+json'
                    }
                    Write-Ok "凭据有效（$($me.login)，前缀 $($t.Substring(0,4))***，长度 $($t.Length)）"
                    return @{ Token = $t; Login = $me.login }
                } catch { Write-Warn2 "第 $i 次凭据未通过校验，重试" }
            }
        } else { Write-Warn2 "第 $i 次未取到凭据，重试" }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

# --------------------------------------------------------------------------
# 2. 建仓库
# --------------------------------------------------------------------------
function Ensure-Repo {
    param($H, [string]$Owner, [string]$Name, [string]$Description, [bool]$Private)

    $api = "https://api.github.com/repos/$Owner/$Name"
    try { $null = Invoke-RestMethod -Uri $api -Headers $H -TimeoutSec 20; Write-Ok "仓库已存在，复用 $Owner/$Name"; return }
    catch { }

    $body = @{
        name         = $Name
        description  = $Description
        private      = $Private
        has_issues   = $true
        has_wiki     = $false
        has_projects = $false
        auto_init    = $false
    } | ConvertTo-Json -Depth 3

    try {
        # 必须发 UTF-8 字节，否则中文 description 会变乱码
        $repo = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post -Headers $H `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 40
        Write-Ok "已创建 $($repo.full_name)（$($repo.visibility)）"
        Start-Sleep -Seconds 2
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 422) { Write-Ok '仓库已存在（422），继续' }
        else { Write-Err "创建仓库失败 HTTP $code : $($_.ErrorDetails.Message)"; return }
    }
}

function Set-RepoTopics {
    param($H, [string]$Owner, [string]$Name, [string[]]$Topics)
    if (-not $Topics -or $Topics.Count -eq 0) { return }
    try {
        $b = @{ names = @($Topics) } | ConvertTo-Json
        $h2 = @{ Authorization = $H.Authorization; 'User-Agent' = 'dsh-skill'
                 Accept = 'application/vnd.github.mercy-preview+json' }
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Name/topics" -Method Put `
            -Headers $h2 -Body ([Text.Encoding]::UTF8.GetBytes($b)) `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 | Out-Null
        Write-Ok "话题标签: $($Topics -join ', ')"
    } catch { Write-Warn2 "话题标签跳过: $($_.Exception.Message)" }
}

# --------------------------------------------------------------------------
# 3. 提交
# --------------------------------------------------------------------------
function Invoke-LocalCommit {
    param([string]$RepoDir, [string]$Message)
    Set-Location -LiteralPath $RepoDir

    if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
        git init -b main | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'git init 失败'; return $null }
        Write-Ok 'git init (main)'
    }
    git add -A
    $staged = @(git diff --cached --name-only).Count
    if ($staged -eq 0) { Write-Ok '无新变更'; }
    else {
        $msgPath = Join-Path $env:TEMP ("_ghpub_" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
        [System.IO.File]::WriteAllText($msgPath, $Message, [System.Text.UTF8Encoding]::new($false))
        git commit -q -F $msgPath
        $rc = $LASTEXITCODE
        Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
        if ($rc -ne 0) { Write-Err 'git commit 失败'; return $null }
        Write-Ok "已提交 $staged 个文件"
    }
    return (git rev-parse --abbrev-ref HEAD).Trim()
}

# --------------------------------------------------------------------------
# 4. 推送
# --------------------------------------------------------------------------
function Push-Repo {
    param([string]$Owner, [string]$Name, [string]$Branch, [string]$Token)
    $plain = "https://github.com/$Owner/$Name.git"
    $remotes = @(git remote)
    if ($remotes -contains 'origin') { git remote set-url origin $plain } else { git remote add origin $plain }

    git push -u origin $Branch 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -eq 0) { Write-Ok "已推送到 $plain"; return $true }

    Write-Warn2 '常规推送失败，改用令牌临时地址重试'
    git remote set-url origin "https://x-access-token:$Token@github.com/$Owner/$Name.git"
    try { git push -u origin $Branch 2>&1 | ForEach-Object { Write-Host "    $_" }; $ok = ($LASTEXITCODE -eq 0) }
    finally {
        git remote set-url origin $plain          # 无论成败都必须还原，绝不留下令牌
        Write-Ok 'origin 已还原为不含令牌的地址'
    }
    if (-not $ok) { Write-Err '推送失败'; return $false }
    return $true
}

# --------------------------------------------------------------------------
# 5. 校验
# --------------------------------------------------------------------------
function Test-Publication {
    param([string]$RepoDir, [string]$Owner, [string]$Name)
    $tmp = Join-Path $env:TEMP ("ghpub-verify-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    git clone -q --depth 1 "https://github.com/$Owner/$Name.git" $tmp 2>&1 | Out-Null
    if (-not (Test-Path $tmp)) { Write-Err '克隆校验失败'; return }

    $rh = (git -C $tmp  rev-parse HEAD).Trim()
    $lh = (git -C $RepoDir rev-parse HEAD).Trim()
    if ($rh -eq $lh) { Write-Ok "HEAD 一致 ($($lh.Substring(0,7)))" } else { Write-Err "HEAD 不一致: 远端 $rh / 本地 $lh" }

    $bad = 0; $n = 0
    foreach ($rel in @(git -C $tmp ls-files)) {          # 注意：需 -c core.quotepath=false 才可读中文名
        $n++
        $rf = Join-Path $tmp      ($rel -replace '/', '\')
        $lf = Join-Path $RepoDir  ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $lf)) { Write-Err "仅远端有: $rel"; $bad++ }
        elseif ((Get-FileHash -LiteralPath $rf).Hash -ne (Get-FileHash -LiteralPath $lf).Hash) { Write-Err "内容不同: $rel"; $bad++ }
    }
    if ($bad -eq 0) { Write-Ok "$n/$n 个文件哈希一致" }

    # 令牌泄露检查
    $cfg = Get-Content (Join-Path $RepoDir '.git\config') -Raw
    if ($cfg -match 'gho_|ghp_|github_pat_|x-access-token') { Write-Err '!!! .git/config 残留令牌' }
    else { Write-Ok '.git/config 干净' }
    $leak = @(git -C $RepoDir grep -l -I -E "(gho_|ghp_|github_pat_)[A-Za-z0-9_]{20,}" HEAD 2>$null)
    if ($leak.Count) { Write-Err "!!! 提交内容残留令牌: $($leak -join ',')" } else { Write-Ok '提交内容无令牌' }
    if (@(git -C $RepoDir status --porcelain).Count -gt 0) { Write-Warn2 '工作区有未提交改动' }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ==========================================================================
# 主流程
# ==========================================================================
Write-Host "`n=== 发布到 GitHub: $Name ===" -ForegroundColor White

if (-not (Test-Path -LiteralPath $RepoDir)) { Write-Err "目录不存在: $RepoDir"; exit 1 }
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
Write-Host "  目录: $RepoDir"

Write-Step '[1/5] 取得 GitHub 凭据 ...'
$auth = Get-GitHubToken
if (-not $auth) { Write-Err '无法取得可用凭据。需要缓存的 GCM 凭据或一个 PAT。'; exit 1 }
$H = @{ Authorization = "Bearer $($auth.Token)"; 'User-Agent' = 'dsh-skill'; Accept = 'application/vnd.github+json' }
if (-not $Owner) { $Owner = $auth.Login }
Write-Host "  账号: $Owner"

Write-Step '[2/5] 确保远端仓库存在 ...'
Ensure-Repo -H $H -Owner $Owner -Name $Name -Description $Description -Private $Private.IsPresent
Set-RepoTopics -H $H -Owner $Owner -Name $Name -Topics $Topics

Write-Step '[3/5] 本地提交 ...'
if (-not $Message) { $Message = "Publish $(Split-Path $RepoDir -Leaf) to GitHub" }
$branch = Invoke-LocalCommit -RepoDir $RepoDir -Message $Message
if (-not $branch) { exit 1 }

Write-Step "[4/5] 推送到 origin/main（当前分支 $branch）..."
Push-Repo -Owner $Owner -Name $Name -Branch $branch -Token $auth.Token | Out-Null

if ($SkipVerify) { Write-Warn2 '已跳过校验' }
else {
    Write-Step '[5/5] 克隆回来校验 ...'
    Test-Publication -RepoDir $RepoDir -Owner $Owner -Name $Name
}

Write-Host ''
if ($script:Failures.Count -eq 0) {
    Write-Host "完成: https://github.com/$Owner/$Name" -ForegroundColor Green
} else {
    Write-Host "有 $($script:Failures.Count) 项失败:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
