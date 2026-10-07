# 故障排查：GitHub 发布流程

全部条目都是在 Windows + PowerShell 7 + 无 `gh` CLI 的真实环境里**实际撞到过**的错误。
按报错原文检索即可。

---

## 1. 取凭据

### `fatal: refusing to work with credential missing protocol field`

**现象**：`git credential fill` 有时成功、有时报这个，同一段代码反复跑结果不一致。

**原因**：用 PowerShell 字符串管道喂 stdin：

```powershell
# 会间歇性失败
$cred = "protocol=https`nhost=github.com`n`n" | git credential fill
```

PowerShell 向原生程序写 stdin 的分块行为不可靠，git 偶尔读不到第一行 `protocol=`。

**修复**：用 .NET 进程显式写 stdin，完全确定：

```powershell
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'git'; $psi.Arguments = 'credential fill'
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardInput.Write("protocol=https`nhost=github.com`n`n")
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit(25000) | Out-Null
```

### `Method invocation failed because [System.Object[]] does not contain a method named 'Trim'`

**原因**：`Where-Object` 返回多行（或零行）时 `.Trim()` 落在数组上。

**修复**：用 `@(...)` 包起来并取 `[0]`：

```powershell
$pw = @($out -split "`r?`n" | Where-Object { $_ -like 'password=*' })
$tok = (($pw[0] -split '=', 2)[1]).Trim()
```

### `401 Unauthorized`（凭据明明存在）

**原因**：上一步取到的 `$tok` 是空值或数组，脚本继续跑了。

**修复**：取到后**先验证再用**，并重试几次：

```powershell
Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers @{ Authorization = "Bearer $tok" }
```

只打印长度与前 4 位确认存在，**绝不打印令牌本身**。

---

## 2. 执行策略 / 脚本运行

### `File ... cannot be loaded because running scripts is disabled on this system.`

**原因**：PowerShell 执行策略禁止运行 `.ps1`。

**修复**（不需要改机器策略）：

```powershell
# 方式 A：读成 scriptblock 再调用（推荐，可以带参数）
$sb = [scriptblock]::Create((Get-Content .\scripts\publish.ps1 -Raw))
& $sb -RepoDir 'C:\proj' -Name 'my-repo'

# 方式 B：子进程显式 bypass
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -RepoDir 'C:\proj' -Name 'my-repo'

# 方式 C：不带动参直接求值
Invoke-Expression (Get-Content .\scripts\publish.ps1 -Raw)
```

### `Unexpected token '??' in expression or statement`

**原因**：想用 C# 的空合并写法。PowerShell 7 虽然支持 `??`，但**不能**塞进字符串插值的子表达式里：

```powershell
"结果: $(($a | Where-Object {...}) -join ', ' ?? '无')"   # 解析失败
```

**修复**：先算好再插值：

```powershell
$v = if ($a.Count) { $a -join ', ' } else { '无' }
"结果: $v"
```

### `git commit -F - <<< $msg` 解析失败

**原因**：`<<<` 是 bash here-string，PowerShell 没有。

**修复**：写成 UTF-8 文件再 `-F`（中文提交信息也必须走文件，`-m` 在部分环境会乱码）：

```powershell
[System.IO.File]::WriteAllText($msgPath, $msg, [System.Text.UTF8Encoding]::new($false))
git commit -q -F $msgPath
```

### `NativeCommandError` 让脚本中途终止

**原因**：`$ErrorActionPreference = 'Stop'` 会把原生程序写到 stderr 的内容升级成终止性异常 —— 即使退出码是 0（比如 `git push` 的正常进度输出走 stderr）。

**修复**：流程脚本里用 `'Continue'`，逐个检查 `$LASTEXITCODE`：

```powershell
$ErrorActionPreference = 'Continue'
git push -u origin main 2>&1 | ForEach-Object { Write-Host "    $_" }
if ($LASTEXITCODE -ne 0) { ... }
```

---

## 3. 建仓库 / 调 API

### 中文 `description` 变乱码

**原因**：`Invoke-RestMethod -Body $string` 的编码不确定。

**修复**：发 UTF-8 字节并显式声明 charset：

```powershell
Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post `
  -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
  -ContentType 'application/json; charset=utf-8'
```

### HTTP 422

仓库已存在。**当成正常分支处理**，直接复用，让整个流程幂等。
先用 `GET /repos/<owner>/<name>` 判断更干净。

### 话题标签设置失败

需要专用 Accept 头：

```
Accept: application/vnd.github.mercy-preview+json
PUT /repos/<owner>/<name>/topics
{ "names": ["kaoyan","english-writing"] }
```

---

## 4. 校验阶段

### `414 Request-URI Too Large` / `URI Too Long`（路径很短也报）

**现象**：`Invoke-WebRequest` 一连串调用里，第一个成功，后面全 414 或超时。

**原因**：keep-alive 连接复用出问题，跟 URL 长度无关。

**修复**：换 `curl.exe`，或改用 `contents` / `git trees` API 而不是逐个 raw 下载。

### `git ls-files` 输出 `"markdown/\345\205\250\351\203\250..."`

**原因**：git 默认 `core.quotepath=true`，非 ASCII 路径被转义成八进制。

**修复**：

```powershell
git -c core.quotepath=false ls-files
```

### `Test-Path : Illegal characters in path`

**原因**：上面那串八进制转义路径直接传给了 `Test-Path`。

**修复**：用 `-c core.quotepath=false` 取到真实路径，并且用 `-LiteralPath`
（中文名还含有 `.` / `[]` 之类字符时，`-Path` 会当通配符解析）。

### 逐文件比对时出现「全部缺失」+「全部多出」

**原因**：用字符串替换剥路径前缀（`$_.FullName.Replace("$tmp\","")`）没匹配上，
两边 key 格式不一致，于是每个文件都被判成"仅本地有"和"仅远端有"。

**修复**：不要做前缀字符串替换，直接**按 `git ls-files` 的相对路径**拼绝对路径比对：

```powershell
foreach ($rel in @(git -C $tmp ls-files)) {
    $rf = Join-Path $tmp      ($rel -replace '/', '\')
    $lf = Join-Path $RepoDir  ($rel -replace '/', '\')
    ...
}
```

### 最省事的校验：比 commit SHA

远端和本地 `git rev-parse HEAD` 相同 ⇒ 整棵树逐字节相同。
一个哈希就能证明，不必逐文件比。逐文件比对留作内容抽查。

---

## 5. 网络（中国大陆常见）

| 域名 | 通常可达 | 说明 |
|---|---|---|
| `github.com` | ✅ | 网页、git 操作 |
| `api.github.com` | ✅ | REST API |
| `codeload.github.com` | ✅ | clone / tarball |
| `raw.githubusercontent.com` | ❌ 常被阻断 | 网页上点 "Raw"、raw 下载会失败 |
| `*.github.io` | ❌ 常被阻断 | GitHub Pages 打不开 |

**结论**：不要因为推送成功就顺手开 GitHub Pages —— 先测 `curl.exe -s -o NUL -w "%{http_code}" --max-time 12 https://<user>.github.io`，
否则站点对用户本人不可用。

网页上 "Raw" 按钮失效是网络问题，**不是仓库坏了**。用 `git clone` 取文件即可。

---

## 6. 安全清单（每次发布后过一遍）

```powershell
# 1) remote 必须是不含令牌的干净地址
git -C $root remote -v

# 2) .git/config 不能残留令牌
$cfg = Get-Content "$root\.git\config" -Raw
if ($cfg -match 'gho_|ghp_|github_pat_|x-access-token') { '!!! 有残留' }

# 3) 提交内容里不能有令牌
git -C $root grep -l -I -E "(gho_|ghp_|github_pat_)[A-Za-z0-9_]{20,}" HEAD

# 4) 工作区干净
git -C $root status --short --branch
```

推送前还要确认 `git add -A` 会暂存什么，避免把 `.env`、私钥、令牌文件一起推上去。
