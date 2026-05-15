---
description: "Daily API documentation pipeline — regenerates XML stubs from CI NuGets, then AI fills 'To be added.' placeholders."

# -- Triggers ----------------------------------------------------------
on:
  schedule:
    - cron: "0 8 * * *"
  push:
    branches: [main]
    paths:
      - ".github/workflows/auto-api-docs-writer*"
  pull_request:
    paths:
      - ".github/workflows/auto-api-docs-writer*"
  workflow_dispatch:

# -- Custom jobs -------------------------------------------------------
# Stub regeneration requires Windows (mdoc.exe is .NET Framework).
# Checks out SkiaSharp (public), runs mdoc, uploads result as artifact.
jobs:
  regenerate-stubs:
    runs-on: windows-latest
    steps:
      - name: Checkout SkiaSharp
        uses: actions/checkout@v4
        with:
          repository: mono/SkiaSharp
          fetch-depth: 1
          submodules: recursive
      - name: Align docs to latest main
        shell: bash
        run: |
          cd docs
          git fetch origin main
          git checkout -B automation/write-api-docs origin/main
          cd ..
      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
          cache: true
      - name: Cache GTK# installer
        id: cache-gtk
        uses: actions/cache@v4
        with:
          path: ${{ runner.temp }}\gtk-sharp.msi
          key: gtk-sharp-2.12.45
      - name: Download GTK# 2
        if: steps.cache-gtk.outputs.cache-hit != 'true'
        shell: pwsh
        run: |
          $msiUrl = "https://github.com/mono/gtk-sharp/releases/download/2.12.45/gtk-sharp-2.12.45.msi"
          Invoke-WebRequest -Uri $msiUrl -OutFile "$env:RUNNER_TEMP\gtk-sharp.msi"
      - name: Install GTK# 2
        shell: pwsh
        run: |
          Start-Process msiexec.exe -ArgumentList "/i", "$env:RUNNER_TEMP\gtk-sharp.msi", "/quiet", "/norestart" -Wait -NoNewWindow
      - name: Restore tools
        run: dotnet tool restore
      - name: Cache NuGet package_cache
        uses: actions/cache@v4
        with:
          path: externals/package_cache
          key: docs-package-cache-${{ hashFiles('scripts/infra/shared/shared.cake') }}
          restore-keys: |
            docs-package-cache-
      - name: Download latest NuGet packages
        run: dotnet cake --target=docs-download-output
      - name: Regenerate API docs
        run: dotnet cake --target=update-docs
      - name: Upload regenerated docs
        uses: actions/upload-artifact@v4
        with:
          name: docs-regenerated
          path: docs/SkiaSharpAPI/
          retention-days: 1

# -- Checkout ----------------------------------------------------------
# Primary: this docs repo only. SkiaSharp is cloned in pre-agent-steps.
checkout:
  - fetch-depth: 1
timeout-minutes: 120
concurrency:
  group: auto-api-docs-writer
  cancel-in-progress: true

# -- Agent tools -------------------------------------------------------
tools:
  github:
    toolsets: [repos]
    allowed-repos: ["mono/skiasharp", "mono/skiasharp-api-docs"]
    min-integrity: none
  bash: ["*"]
  edit:

# -- Network allowlist -------------------------------------------------
network:
  allowed:
    - defaults
    - github
    - dotnet

# -- Permissions -------------------------------------------------------
permissions:
  contents: read

# -- Safe outputs ------------------------------------------------------
safe-outputs:
  create-pull-request:
    draft: false
    base-branch: main
    preserve-branch-name: true
    recreate-ref: true

# -- Pre-agent steps (host) -------------------------------------------
pre-agent-steps:
  - name: Download regenerated docs
    uses: actions/download-artifact@v4
    with:
      name: docs-regenerated
      path: SkiaSharpAPI/

  - name: Clone SkiaSharp (shallow, with submodules)
    run: |
      git clone --depth 1 --branch mattleibow/dev-simplify-api-docs-workflow \
        --recurse-submodules --shallow-submodules \
        https://github.com/mono/SkiaSharp.git skiasharp
      ln -sfn "$(pwd)" skiasharp/docs
      cd skiasharp && dotnet tool restore

  - name: Extract placeholders
    run: |
      mkdir -p output/docs-work
      pwsh skiasharp/.agents/skills/api-docs/scripts/docs-tool.ps1 extract SkiaSharpAPI/ -Output output/docs-work/
---

# Auto API Docs Writer

**Read `skiasharp/.agents/skills/api-docs/SKILL.md` for reference.** Follow the phases below — this workflow pre-computes Phases 1–2, so start at Phase 3.

## Execution order

1. **Phase 3 (Discover)** — read JSON files in `output/docs-work/`, read source code for context.
2. **Phase 4 (Write)** — fill placeholders in the JSON files. Follow the rules in SKILL.md Phase 4.
3. **Phase 5 (Review)** — launch the two background review agents described in SKILL.md Phase 5 (Fabrication Detector and Quality Reviewer). Wait for both to complete, then fix all CRITICAL issues. **Important: tell each review agent that it must do all its work directly — it must NOT spawn its own sub-agents or delegate to further background agents.**
4. **Phase 6 (Merge)** — this is the critical step. Run:
   ```bash
   cd skiasharp && pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 merge ../output/docs-work/ && dotnet cake --target=docs-format-docs && cd ..
   ```
5. **Commit and PR** — commit the XML changes and create a pull request:
   ```bash
   git add -A
   git commit -m "Fill API documentation placeholders"
   ```
   Then use the `create_pull_request` tool:
   - Branch: `automation/write-api-docs`
   - Title: `Fill API documentation placeholders`
   - Body: `Automated AI-generated documentation for XML API docs with 'To be added.' placeholders.`

If there are no documentation changes after merging, call the `noop` tool instead.

## Critical rules

- **Review agents must NOT spawn their own sub-agents.** Each review agent must do all its work directly. Nested sub-agents hit the depth limit and cause timeouts.
- **Do NOT edit XML files directly** — edit only the JSON files in `output/docs-work/`.
- **Phase 6 MUST run.** If you skip it, no PR is created and the entire run is wasted.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
| `dotnet cake --target=docs-format-docs` | `cd skiasharp && dotnet cake --target=docs-format-docs && cd ..` |
