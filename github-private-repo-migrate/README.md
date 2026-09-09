# GitHub Private Repository Migrate

当前稳定版本：**v5.3**

用于在两个 **GitHub 个人账号**之间迁移私有仓库，重点解决普通 `git push --mirror` 只能搬 Git 数据、无法安全处理 Actions 配置和 Secret 的问题。

工具采用中文交互，一次执行可连续迁移多个仓库；只有确实需要用户判断或输入 Secret 时才会停下来询问。详细 Git / GitHub 技术输出写入迁移状态目录中的日志文件。

## 适用范围

当前版本面向：

- GitHub.com；
- 个人账号 → 个人账号；
- 私有仓库；
- Classic PAT；
- macOS / Bash 3.2 兼容环境。

不用于组织账号仓库迁移，也不等价于 GitHub 官方 Repository Transfer。

## 前置安装

macOS：

```bash
brew install gh jq git-lfs
```

初始化 Git LFS：

```bash
git lfs install
```

确认依赖：

```bash
git --version
gh --version
jq --version
git lfs version
```

## PAT 权限

准备两个 GitHub **Classic PAT**：

### 源账号

```text
repo
```

### 目标账号

```text
repo
workflow
```

脚本运行时会隐藏输入 PAT。

PAT 只在当前脚本进程中使用，不写入状态目录或日志。

不要求提前执行 `gh auth login`；脚本会显式使用交互输入的 PAT。

## 第一次执行前授权

进入本目录：

```bash
cd github-private-repo-migrate
```

给脚本执行权限：

```bash
chmod +x github-private-repo-migrate.sh
```

## 运行

```bash
./github-private-repo-migrate.sh
```

随后按照中文提示输入：

1. 源账号 PAT；
2. 目标账号 PAT；
3. 源仓库名；
4. 目标仓库名（默认与源仓库同名）；
5. 最终切换前确认源仓库已经停止修改；
6. 如有 Secret，按提示重新填写；
7. 如存在真实且无法自动迁移的平台配置，确认是否接受差异。

完成一个仓库后，工具会明确显示：

```text
✅ 已成功迁移仓库：仓库名
```

然后询问是否继续迁移下一个仓库。继续时可以复用上一组 PAT。

## 自动处理的主要内容

工具会处理或校验：

- Git commit 历史；
- branches；
- tags；
- Git LFS 对象；
- 默认分支；
- 一组安全的 Repository metadata；
- Topics；
- GitHub Actions repository permissions；
- 默认 `GITHUB_TOKEN` workflow permissions；
- selected Actions allowlist（如有）；
- reusable workflow access；
- Repository Variables；
- Environments；
- Environment Variables；
- Actions Repository Secret 名称与目标端补齐校验；
- Environment Secret 名称与目标端补齐校验；
- Dependabot Secret 名称与目标端补齐校验。

## 安全机制

### 1. 目标 Actions 先关闭

目标仓库创建后会先关闭 GitHub Actions，再写入 workflow 与其他内容，避免目标仓库在 Secret 和配置尚未恢复时意外执行 workflow。

### 2. 最终同步

初始迁移完成后，工具会要求停止修改源仓库，再做一次最终 Git/LFS 同步和 refs 校验。

### 3. Secret 不伪造迁移

GitHub 不允许读取 Secret 明文，因此工具只读取 Secret 名称，并要求在目标仓库重新填写。

Secret 未补齐时不会开启目标 Actions。

### 4. Unknown 不等于 Empty

关键 GitHub API 如果因为权限、网络或服务异常无法读取，工具不会把“读取失败”解释为“没有配置”。

### 5. Actions 最后恢复

只有最终 Git 校验、Secret 校验和必要配置恢复通过后，才恢复目标仓库 Actions。恢复或最终验证失败时，会尽力重新保持 Actions 关闭。

## 不自动完整迁移的 GitHub 托管状态

下列内容不属于 Git mirror，也不会被本工具承诺为完整迁移：

- Issues；
- Pull Requests；
- Discussions；
- Stars / Watchers；
- GitHub Projects；
- Actions 历史运行记录与 artifacts；
- Release 页面与附件（Git Tag 本身会迁移）；
- Wiki 内容与历史；
- GitHub Pages 配置；
- Webhooks；
- Deploy keys；
- Rulesets / Branch protection 等需要人工确认的保护策略；
- Collaborators 等 GitHub 平台关系。

工具会尽量区分：

- **确认存在但未自动迁移**：明确点名并说明影响；
- **API 无法读取、状态未知**：明确说明无法确认；
- **套餐/仓库条件明确不适用**：不作为风险打扰用户。

## 迁移状态与日志

每个仓库会在当前目录生成类似：

```text
gh-migrate-source-owner-repo-to-destination-owner-repo/
```

其中包含迁移状态、配置快照和日志。

这些目录默认已被仓库根目录 `.gitignore` 忽略。

如果迁移中断，通常不需要删除目标仓库；重新运行同一个脚本，工具会根据状态继续或重新校验。

## 迁移完成后的本地开发目录

原来的本地工作目录不需要重新 clone。

进入原工作目录，把 `origin` 改成新仓库：

```bash
git remote set-url origin https://github.com/NEW_OWNER/REPO.git
git fetch origin
git status
```

未提交文件、本地 commit、本地 branch、stash、worktree 都仍保留在本地。

如果存在尚未 push 的本地 commit，可检查：

```bash
git log --oneline origin/main..HEAD
```

确认后正常 push 到新仓库即可。

## 注意

真正的 GitHub Repository Transfer 能保留 Issues、PR、Stars、fork network、URL redirect 等更多 GitHub 托管状态。本工具主要面向：

> **代码历史 + Git LFS + 常用 Actions 配置 + Variables / Environments / Secret 安全恢复**

在官方 Transfer 不可用、失败或不值得继续排查时，作为可控的替代迁移方式。
