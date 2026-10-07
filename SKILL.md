---
name: github-publish
description: Publish a local folder to GitHub when the `gh` CLI is unavailable — detect the cached Git Credential Manager credential, create the repository through the REST API, commit, push, and verify the result by re-cloning and comparing commit SHAs. Use this for any "上传到我的 GitHub / push to my GitHub" request, for turning an existing local directory into a new repository, or when a GitHub push or API call fails with 401, 403, or 404.
whenToUse: 用户要求把某个目录或项目推送到 GitHub、新建仓库并上传、给已有仓库推送更新，或排查 GitHub 认证/推送失败时。
---

# Publish a local folder to GitHub

Windows-first workflow for pushing a directory to GitHub **without `gh` installed**. The
reusable implementation is `scripts/publish.ps1` in this skill bundle; read it before
hand-rolling the flow, and copy it out when a project needs its own variant.

## Hard rules

1. **Never print, echo, or commit the token.** Print only its length and a 4-char prefix when you must confirm it exists.
2. **Never leave credentials in the repo.** The remote URL must end up as the plain `https://github.com/<owner>/<repo>.git` form.
3. **Always verify by cloning.** A `git push` exit code of 0 is not proof; see step 5.
4. **Ask before creating.** Repository name and public/private are the user's decisions, not defaults.
5. **Confirm before publishing anything that could contain secrets** (`.env`, tokens, private keys). Check what `git add -A` would stage.

## Step 0 — recon, in one call

```powershell
git --version
gh --version                      # usually absent on Windows; do not assume it exists
git config --global --list        # user.name / user.email for the commit
cmdkey /list | Select-String github
```

To learn the GitHub username, look for a sibling directory that is already a repo and read its remote:

```powershell
Get-ChildItem <parent> -Directory -Force |
  Where-Object { Test-Path "$($_.FullName)\.git" } |
  ForEach-Object { git -C $_.FullName remote -v }
```

Also probe reachability once — it determines how the user will consume the result:

```powershell
foreach ($h in 'github.com','api.github.com','raw.githubusercontent.com','codeload.github.com') {
  "$h -> " + (curl.exe -s -o NUL -w "%{http_code}" --max-time 12 "https://$h")
}
```

`raw.githubusercontent.com` and `*.github.io` are frequently blocked on mainland-China
networks while `github.com` and `api.github.com` work. **Do not enable GitHub Pages
without testing `*.github.io` first** — it may be unusable for the person who asked.

## Step 1 — obtain a token (this is the fragile part)

`git credential fill` reads this request on stdin, terminated by a blank line:

```
protocol=https
host=github.com

```

**Do not pipe a PowerShell string into it.** `` "protocol=https`nhost=github.com`n`n" | git credential fill ``
works intermittently and then fails with:

```
fatal: refusing to work with credential missing protocol field
```

Use .NET process I/O with an explicit stdin instead — this is deterministic:

```powershell
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'git'; $psi.Arguments = 'credential fill'
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardInput.Write("protocol=https`nhost=github.com`n`n")
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit(25000) | Out-Null
$tok = ((@($out -split "`r?`n" | Where-Object { $_ -like 'password=*' })[0]) -split '=',2)[1].Trim()
```

Always **validate before use** and retry the fetch a few times:

```powershell
Invoke-RestMethod -Uri 'https://api.github.com/user' -TimeoutSec 20 -Headers @{
  Authorization = "Bearer $tok"; 'User-Agent' = 'dsh-skill'; Accept = 'application/vnd.github+json'
}
```

| Prefix | Meaning | API + git? |
|---|---|---|
| `gho_` | Git Credential Manager OAuth token | both |
| `ghp_` | classic PAT | both |
| `github_pat_` | fine-grained PAT | both, scope-limited |

If nothing is cached, stop and ask the user for a PAT rather than generating an SSH key
unasked.

## Step 2 — create the repository

`POST https://api.github.com/user/repos`. Send the body as **UTF-8 bytes** — a non-ASCII
`description` mojibakes if you pass a plain string:

```powershell
$body = @{ name=$Name; description=$Desc; private=$false;
           has_issues=$true; has_wiki=$false; has_projects=$false; auto_init=$false } |
        ConvertTo-Json -Depth 3
Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post -Headers $H `
  -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
  -ContentType 'application/json; charset=utf-8'
```

Treat **HTTP 422 as "already exists"** and continue — it makes the whole flow idempotent.
`GET /repos/<owner>/<name>` first is a cheap way to branch cleanly.

Optional topics need a different Accept header:

```
Accept: application/vnd.github.mercy-preview+json
PUT /repos/<owner>/<name>/topics   { "names": ["a","b"] }
```

## Step 3 — commit

`git init -b main` only if `.git` is absent. Set `$ErrorActionPreference = 'Continue'`
and check `$LASTEXITCODE` explicitly — with `'Stop'`, any native command that writes to
stderr raises a terminating `NativeCommandError` and aborts the run.

Commit message with non-ASCII text must go through a UTF-8 file, not `-m`:

```powershell
[System.IO.File]::WriteAllText($msgPath, $msg, [System.Text.UTF8Encoding]::new($false))
git commit -q -F $msgPath
```

**PowerShell has no `<<<` here-string operator.** `git commit -F - <<< $msg` is bash and
will fail to parse.

## Step 4 — push

The plain remote works whenever Git Credential Manager is configured globally (`git config
--show-origin --get-all credential.helper` → `manager`):

```powershell
git remote add origin https://github.com/<owner>/<repo>.git
git push -u origin main
```

Only if that fails, fall back to a token URL and **restore the remote in a `finally`**:

```powershell
git remote set-url origin "https://x-access-token:$tok@github.com/<owner>/<repo>.git"
try { git push -u origin main } finally { git remote set-url origin $PlainRemote }
```

## Step 5 — verify (never skip)

Same commit SHA ⇒ identical tree ⇒ identical content. This is the strongest cheap proof:

```powershell
$tmp = Join-Path $env:TEMP ("verify-" + [guid]::NewGuid().ToString('N').Substring(0,8))
git clone -q --depth 1 https://github.com/<owner>/<repo>.git $tmp
(git -C $tmp rev-parse HEAD) -eq (git -C $root rev-parse HEAD)
```

Then compare per-file hashes by **relative path from `git ls-files`** — do not string-replace
the path prefix, that comparison silently produces a full list of false "missing" rows:

```powershell
foreach ($rel in @(git -C $tmp ls-files)) {
  $rf = Join-Path $tmp  ($rel -replace '/','\')
  $lf = Join-Path $root ($rel -replace '/','\')
  if (-not (Test-Path -LiteralPath $lf)) { "仅远端: $rel" }
  elseif ((Get-FileHash -LiteralPath $rf).Hash -ne (Get-FileHash -LiteralPath $lf).Hash) { "内容不同: $rel" }
}
```

`git ls-files` quotes non-ASCII paths as octal escapes; pass `-c core.quotepath=false` to
read them.

Finally prove the secret did not leak:

```powershell
$cfg = Get-Content "$root\.git\config" -Raw
if ($cfg -match 'gho_|x-access-token') { '!!! token in .git/config' }
git -C $root grep -l -I -E "gho_[A-Za-z0-9]{30,}" HEAD   # must be empty
```

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `refusing to work with credential missing protocol field` | PowerShell string piped into `git credential fill` | .NET process with explicit stdin (step 1) |
| `401 Unauthorized` on API, credential present | token extraction returned empty / array `.Trim()` failed | wrap in `@(...)`, take `[0]`, validate with `/user` |
| `NativeCommandError` aborting mid-script | `$ErrorActionPreference='Stop'` + native stderr | use `'Continue'` and check `$LASTEXITCODE` |
| `cannot be loaded because running scripts is disabled` | PS execution policy | `Invoke-Expression (Get-Content x.ps1 -Raw)`, or `pwsh -ExecutionPolicy Bypass -File` |
| `<>` substituted as `??` / parse error | `??` used inside string interpolation | build the string with `if/else` first |
| `414 Request-URI Too Large` on a short path | `Invoke-WebRequest` reusing a broken keep-alive | use `curl.exe`, or the `contents`/`git trees` API instead |
| `git ls-files` shows `"markdown/\345\205\250..."` | git quotes non-ASCII by default | `-c core.quotepath=false` |
| `gh: command not found` | no GitHub CLI on this machine | this whole API-based flow |

## Reference

`references/troubleshooting.md` in this bundle holds the full transcript-level detail of
each failure above, including the raw error text to match against.
