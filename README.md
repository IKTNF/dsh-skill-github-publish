# github-publish

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 用的 **Skill**：
把本地目录发布到 GitHub，**不需要安装 `gh` CLI**。

Windows / PowerShell 场景实测可用，覆盖了从取凭据到校验的全流程，
并把一路踩过的坑（凭据读取不稳定、执行策略拦截、编码乱码、网络阻断）都写在文档里。

## 它解决什么

| 场景 | 没有这个 Skill 时 | 有这个 Skill 时 |
|---|---|---|
| 机器上没装 `gh` | 建不了仓库，只能让用户手动去网页点 | 用已缓存的 GCM 凭据直接调 REST API 建仓库 |
| 取 Git 凭据 | `"..." \| git credential fill` 间歇性报 `missing protocol field` | 用 .NET 进程显式写 stdin，确定性成功 |
| 推送完算不算成功 | 看退出码是 0 就以为好了 | 克隆回来比 commit SHA + 逐文件哈希 |
| 令牌会不会泄漏 | 容易留在 `.git/config` 或提交里 | 强制还原 remote，并有专门的泄露检查 |
| 中文文件名 / 中文描述 | 乱码、路径转义读不出来 | 明确用 UTF-8 字节提交、`core.quotepath=false` 读 |

## 安装

Skill 目录本身就是仓库，直接克隆到 DSH 的 user skill 根目录即可
（`$DSH_HOME` 默认是 `~/.dsh`，本机是 `D:\DeepSeekHarness\home`）：

```powershell
# 确认你的 DSH_HOME
echo $env:DSH_HOME

# 克隆进 skills 根目录下的 github-publish/
git clone https://github.com/IKTNF/dsh-skill-github-publish.git "$env:DSH_HOME\skills\github-publish"
```

装完即生效 —— DSH 的文件系统 skill provider 会监视 `<dshHome>/skills`，
新目录一出现就自动进入模型可见的 skill 目录，**不需要重启**。

验证：

```powershell
Test-Path "$env:DSH_HOME\skills\github-publish\SKILL.md"   # 应为 True
```

更新：

```powershell
git -C "$env:DSH_HOME\skills\github-publish" pull
```

## 目录结构

```
github-publish/
├─ SKILL.md                      # 主指令：五步流程 + 五条硬性规则 + 坑表
├─ scripts/
│  └─ publish.ps1                # 可直接调用的完整实现
└─ references/
   └─ troubleshooting.md         # 按报错原文检索的故障排查
```

## 用法

### 1. 让 Agent 用它

直接说需求即可，Agent 会根据 `SKILL.md` 的 description 自动加载：

> 把这个目录推送到我的 GitHub 上，私有仓库

### 2. 手动调用脚本

执行策略通常禁止直接跑 `.ps1`，用 scriptblock 方式绕开且能带参数：

```powershell
$sb = [scriptblock]::Create((Get-Content "$env:DSH_HOME\skills\github-publish\scripts\publish.ps1" -Raw))
& $sb -RepoDir 'C:\Users\me\Desktop\my-project' `
      -Name 'my-project' `
      -Description '项目说明，可含中文' `
      -Topics tools,automation `
      -Private
```

或者显式 bypass：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:DSH_HOME\skills\github-publish\scripts\publish.ps1" `
  -RepoDir 'C:\path\to\dir' -Name 'repo-name'
```

脚本会依次做：取凭据 → 建仓库（幂等，422 当已存在）→ 设话题标签 →
`git init`/`add`/`commit` → 推送（失败才回退到令牌地址，且必定还原）→
克隆回来校验 → 检查令牌泄漏。最后打印仓库地址。

## 前提条件

- `git` 已安装
- **Git Credential Manager 里已缓存 GitHub 凭据**（用过一次 `git push` 到 GitHub 就会有）：
  ```powershell
  cmdkey /list | Select-String github
  ```
- 没有缓存凭据的话，准备一个 Personal Access Token（需要 `repo` 权限），
  跑一次 `git push` 让它被记住

脚本**不会**读取、打印或存储明文令牌；只在内存里用过即弃。

## 已知边界

- **网络**：`raw.githubusercontent.com` 与 `*.github.io` 在中国大陆常被阻断
  （`github.com` / `api.github.com` / `codeload.github.com` 正常）。
  Skill 里写了：**先测再决定要不要开 GitHub Pages**，否则站点对用户本人不可用。
- 面向 Windows + PowerShell 编写；GitHub API 部分跨平台通用，PowerShell 部分需改写为 bash + curl。
- 凭据缓存机制依赖 Git Credential Manager，未覆盖 SSH key 流程。

## License

MIT
