# Installer simplification

Reduce maintained code substantially while preserving the documented package
coverage, public options, automatic architecture, unattended execution, exit codes,
reports, cleanup, and trust boundaries. Baseline: 5,515 lines / six runtime files.

The selected approach consolidates repeated implementation. A package-manager
rewrite would introduce a different dependency and package-source model; removing
selection or verification would reduce functionality. Neither is required here.

1. Capture baseline help and static analysis. Add dependency-free regression checks
   for selection, metadata rejection, downloads, verification, restart handling,
   workspace deletion, launcher forwarding, and report privacy.
2. Replace console layout wrappers with one wrapping primitive and concise,
   data-driven screens. Preserve the menu and completion/report workflow. Have a
   UI implementer handle this isolated module, then review its contracts and code.
3. Make Bootstrap a forwarding shim. Keep Start's immutable four-file manifest,
   exact GitHub URL checks, syntax validation, and guarded cleanup. Share native
   process argument handling with the installer after source validation.
4. Consolidate common download/verify/install loops and option handling in
   RuntimeInstaller. Keep package discovery rules and cryptographic requirements.
   Simplify orchestration and report construction in Install.
5. Run regression checks, all-file parser validation, offline help for all entry
   points, configured PSScriptAnalyzer, and live metadata resolution. Inspect actual
   terminal output. Native Windows verification must be reported separately.
6. Review the complete diff, update documentation, measure lines/bytes/functions,
   commit intended changes, fetch/rebase, push without force, and verify upstream
   equality and repository workflow/deployment state.

Keep code readable: four-space indentation, explicit validation, no minification,
no payloads, and Windows PowerShell 5.1 compatibility. Fix any demonstrated defect
in the affected path and add a focused regression for it.
