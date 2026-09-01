# README Simplification Design

## Objective

Rewrite `README.md` so a first-time Windows user can understand and run the installer as easily as they can from the updated Reddit post, without removing the technical reference that advanced users need.

## Audience and information order

The README will use progressive disclosure:

1. Explain the project and its source-only distribution in plain language.
2. Summarize the three package groups and automatic architecture selection.
3. Give the exact Administrator Command Prompt quick-start procedure.
4. Explain the interactive menu, unattended installation, cleanup, restart handling, and optional report.
5. Summarize the security controls in direct, non-specialist language.
6. Retain command-line automation, architecture details, requirements, exit codes, verification notes, support, offline-project context, and licensing below the beginner workflow.

## Content rules

- Preserve the launcher command exactly.
- Keep all user-visible behavior consistent with the current scripts.
- Keep the repository's source-only and online-only distinction clear.
- Preserve material security guarantees without leading with implementation jargon.
- Avoid repeating the same behavior across multiple sections.
- Prefer short paragraphs and bullets over dense prose or wide tables when they improve readability.
- Keep advanced examples useful, but move them after the main installation path.
- Replace revision-specific validation history with concise statements that can be supported by fresh verification.
- Link to the original Reddit post for the separately maintained offline ZIP rather than presenting the ZIP as part of this repository.

## Scope

The implementation changes `README.md` only. It does not change PowerShell behavior, package metadata, security controls, installer payloads, or third-party notices.

This design record and the implementation plan are process documentation for the approved rewrite.

## Verification

- Compare each behavioral claim with `Start.ps1`, `Install.ps1`, `src/ConsoleUI.psm1`, `src/RuntimeInstaller.psm1`, and `config/packages.psd1`.
- Confirm the launcher command is byte-for-byte unchanged.
- Render or structurally inspect the Markdown for headings, lists, tables, links, and code fences.
- Run repository-required PowerShell help, parser, and PSScriptAnalyzer checks because the README documents their behavior.
- Check links and review the final Git diff for unintended changes or whitespace errors.
- Do not claim native Windows installation behavior was retested unless it is actually executed in a disposable Windows environment.
