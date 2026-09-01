# README Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the GitHub README into a Reddit-style beginner guide while retaining a compact, accurate technical reference for advanced users.

**Architecture:** Apply progressive disclosure within one documentation file: beginner-facing purpose, packages, quick start, menu use, and safety first; automation and technical reference second. Preserve installer behavior and the public launcher exactly, and verify every material claim against the current PowerShell source.

**Tech Stack:** GitHub Flavored Markdown, Windows PowerShell 5.1-compatible project scripts, PSScriptAnalyzer, Git, GitHub CLI

---

### Task 1: Establish the documentation baseline

**Files:**
- Read: `README.md`
- Read: `Start.ps1`
- Read: `Install.ps1`
- Read: `src/ConsoleUI.psm1`
- Read: `src/RuntimeInstaller.psm1`
- Read: `config/packages.psd1`

- [ ] **Step 1: Confirm the new beginner section does not exist yet**

Run:

```bash
if rg -q '^## What it installs$' README.md; then exit 1; fi
```

Expected: exit `0`, proving the planned Reddit-style section is absent before the rewrite.

- [ ] **Step 2: Record the existing launcher and relevant source behavior**

Run:

```bash
sed -n '7,20p' README.md
rg -n "Read-InstallerSelection|Write-InstallerCompletionScreen|OPTIONAL TECHNICAL REPORT|Get-TargetArchitecture|Get-DotNetSdkPackage|Assert-TrustedMicrosoftSignature|Test-AllowedMicrosoftUri" Install.ps1 src/ConsoleUI.psm1 src/RuntimeInstaller.psm1
```

Expected: the current launcher block is visible, along with the implementation points supporting menu, report, architecture, package resolution, signature, and host claims.

### Task 2: Rewrite the README using progressive disclosure

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the existing README organization and prose**

Use this heading order and content contract:

```text
# Microsoft Runtime Installer
## What it installs
## Quick start
## Using the installer
## Safety checks
## Advanced command-line use
## Architecture selection
## Requirements
## Exit codes
## Verification
## Feedback and problems
## Project notes
```

The opening must plainly state that the repository contains no bundled Microsoft installers or archives, downloads selected packages from official Microsoft HTTPS sources, verifies them before execution, installs unattended, and removes temporary downloads by default.

`What it installs` must describe the latest stable SDK from each selected supported .NET channel, the final Visual C++ 2005-2013 releases plus the latest supported v14 runtime, and DirectX End-User Runtimes (June 2010). It must explain automatic x86/x64/ARM64 selection and why x86 plus x64 Visual C++ packages are installed on 64-bit Windows.

`Quick start` must preserve the existing `bat` launcher byte-for-byte and use the Reddit post's three explicit Administrator Command Prompt steps.

`Using the installer` must state the default selections, keys `1` through `5`, blank `Selection` behavior, `A`, `K`, and `Q`, unattended behavior, manual restart policy, cleanup/result summary, optional `R` report, and PowerShell 7 preference with Windows PowerShell 5.1 fallback.

`Safety checks` must retain approved HTTPS hosts, .NET SHA-512, fixed-package SHA-256, Microsoft Authenticode, Visual C++ v14 version floor, immutable GitHub revision, pre-execution plan resolution, and guarded temporary cleanup in short bullets.

The advanced reference must preserve the supported switches, examples, architecture matrix, requirements, exit codes, source-audit links, Reddit offline-project link, third-party notice, non-affiliation statement, and GitHub issue guidance without repeating the beginner workflow.

`Verification` must list current repeatable project checks and explicitly say native Windows installation behavior is not established by Linux-only checks. Remove revision-specific historical validation claims that can become stale.

- [ ] **Step 2: Confirm the launcher is unchanged**

Run:

```bash
before_launcher=$(git show 519267a:README.md | sed -n '/^```bat$/,/^```$/p')
after_launcher=$(sed -n '/^```bat$/,/^```$/p' README.md)
test "$before_launcher" = "$after_launcher"
```

Expected: exit `0` with no output.

- [ ] **Step 3: Confirm the new structure and removed stale wording**

Run:

```bash
rg -n '^## (What it installs|Quick start|Using the installer|Safety checks|Advanced command-line use|Architecture selection|Requirements|Exit codes|Verification|Feedback and problems|Project notes)$' README.md
if rg -q 'preceding revision|confirmation is pending' README.md; then exit 1; fi
```

Expected: all eleven headings are found in order and the command exits `0`.

### Task 3: Validate the documentation and repository

**Files:**
- Verify: `README.md`
- Verify: `Start.ps1`
- Verify: `Bootstrap.ps1`
- Verify: `Install.ps1`
- Verify: `src/ConsoleUI.psm1`
- Verify: `src/RuntimeInstaller.psm1`
- Verify: `config/packages.psd1`

- [ ] **Step 1: Check Markdown structure and whitespace**

Run:

```bash
test "$(rg -c '^```' README.md)" -eq 8
git diff --check
```

Expected: both commands exit `0`; the README has four balanced fenced blocks and the diff has no whitespace errors.

- [ ] **Step 2: Render the README with GitHub's Markdown API and inspect the result**

Run:

```bash
jq -Rs '{text: ., mode: "gfm", context: "slyfox1186/msft-visual-c-and-directx-offline-installer"}' README.md | gh api markdown --input - | rg '<h1|<h2|<pre|<table|href='
```

Expected: exit `0` with rendered headings, code blocks, tables, and links visible in the returned HTML.

- [ ] **Step 3: Run help without elevation or downloads**

Run:

```bash
pwsh -NoProfile -File ./Install.ps1 -Help
```

Expected: exit `0` and complete usage, options, rules, examples, and exit-code help.

- [ ] **Step 4: Parse every PowerShell source and data file**

Run:

```bash
pwsh -NoProfile -Command '$failed = $false; Get-ChildItem -Path . -Recurse -File | Where-Object { $_.Extension -in ".ps1", ".psm1", ".psd1" } | ForEach-Object { $tokens = $null; $errors = $null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors); if ($errors.Count -gt 0) { $failed = $true; $errors | ForEach-Object { Write-Error ("{0}: {1}" -f $_.Extent.File, $_.Message) } } }; if ($failed) { exit 1 }'
```

Expected: exit `0` with no parser errors.

- [ ] **Step 5: Run the configured static analyzer**

Run:

```bash
pwsh -NoProfile -Command 'Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
```

Expected: exit `0` with no analyzer findings.

- [ ] **Step 6: Inspect the complete change set**

Run:

```bash
git diff -- README.md
git status --short
```

Expected: only the planned README rewrite is uncommitted during implementation, and no payloads, archives, generated assets, or unrelated files are present.

### Task 4: Commit and publish the verified rewrite

**Files:**
- Commit: `README.md`

- [ ] **Step 1: Commit the README**

Run:

```bash
git add README.md
git diff --cached --check
git commit -m "docs: simplify installer readme"
```

Expected: a new documentation commit is created and the staged diff has no whitespace errors.

- [ ] **Step 2: Fetch and rebase safely onto the live default branch**

Run:

```bash
git fetch origin
git rebase origin/main
```

Expected: exit `0`; local commits are based on the latest `origin/main` without force-pushing.

- [ ] **Step 3: Re-run final verification after rebase**

Repeat Task 3 Steps 1, 3, 4, and 5.

Expected: every command exits `0` on the exact commit that will be pushed.

- [ ] **Step 4: Push and verify GitHub state**

Run:

```bash
git push origin main
git fetch origin
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git status --short --branch
gh api repos/slyfox1186/msft-visual-c-and-directx-offline-installer/readme --jq '.html_url'
```

Expected: push succeeds, local `HEAD` equals `origin/main`, the worktree is clean, and GitHub returns the published README URL.

- [ ] **Step 5: Inspect the published README**

Run:

```bash
gh api repos/slyfox1186/msft-visual-c-and-directx-offline-installer/readme -H 'Accept: application/vnd.github.raw+json' | rg -n '^#|^```bat$|^start "Microsoft Runtime Installer"|GitHub issue|THIRD-PARTY-NOTICES'
```

Expected: the live README contains the intended heading structure, exact launcher, support link, and licensing link.

Native Windows UAC, installer switches, Authenticode, installation, cleanup, and console rendering are deliberately not rerun for this documentation-only change unless a disposable Windows environment is available.
