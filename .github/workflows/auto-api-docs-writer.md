---
description: "Daily API documentation pipeline — regenerates XML stubs from CI NuGets, then AI fills 'To be added.' placeholders."

# -- Triggers ----------------------------------------------------------
on:
  schedule:
    - cron: "0 8 * * *"
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
      - name: Install GTK# 2
        shell: pwsh
        run: |
          $msiUrl = "https://github.com/mono/gtk-sharp/releases/download/2.12.45/gtk-sharp-2.12.45.msi"
          $msiPath = "$env:RUNNER_TEMP\gtk-sharp.msi"
          Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath
          Start-Process msiexec.exe -ArgumentList "/i", $msiPath, "/quiet", "/norestart" -Wait -NoNewWindow
      - name: Restore tools
        run: dotnet tool restore
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
      git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/mono/SkiaSharp.git skiasharp
      ln -sfn "$(pwd)" skiasharp/docs
      cd skiasharp && dotnet tool restore

  - name: Extract placeholders
    run: |
      mkdir -p output/docs-work
      pwsh skiasharp/.agents/skills/api-docs/scripts/docs-tool.ps1 extract SkiaSharpAPI/ -Output output/docs-work/
---

# Auto API Docs Writer

**Read `skiasharp/.agents/skills/api-docs/SKILL.md` and follow Phases 3–5.** Overrides for this workflow:

- **Phases 1–2 are pre-computed** — stub regeneration and JSON extraction already ran. Skip them.
- **Do NOT edit XML files directly** — edit only the JSON files in `output/docs-work/`.
- **Source code reference**: SkiaSharp source is at `skiasharp/` (C# wrappers at `skiasharp/binding/SkiaSharp/`, C headers at `skiasharp/externals/skia/include/c/`).

Your workflow:
1. **Phase 3 (Discover)** — read patterns, study existing good docs in `SkiaSharpAPI/`, read source code in `skiasharp/`
2. **Phase 4 (Write)** — fill JSON files with documentation
3. **Phase 5 (Review)** — launch two background agents, fix issues, repeat until clean
4. **Finalize** — merge, validate, commit, and create the PR (see below)

## Finalize — Merge, Format, and Create PR

After completing Phases 3–5, run Phase 6 from the skill with adjusted paths:

1. **Merge** JSON changes back into XML:
   ```bash
   pwsh skiasharp/.agents/skills/api-docs/scripts/docs-tool.ps1 merge output/docs-work/
   ```

2. **Format** the XML docs using the SkiaSharp build system:
   ```bash
   cd skiasharp && dotnet cake --target=docs-format-docs || true
   cd ..
   ```

3. **Commit**:
   ```bash
   git add -A
   git commit -m "Fill API documentation placeholders"
   ```

4. **Create PR** — use the `create_pull_request` tool:
   - Branch: `automation/write-api-docs`
   - Title: `Fill API documentation placeholders`
   - Body: `Automated AI-generated documentation for XML API docs with 'To be added.' placeholders.`

If there are no documentation changes after merging, skip the commit and PR.
