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
    inputs:
      skiasharp_branch:
        description: "SkiaSharp branch to use for scripts and references"
        required: false
        default: "main"
        type: string

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
          ref: ${{ inputs.skiasharp_branch || 'main' }}
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
      - name: Cache NuGet global packages
        uses: actions/cache@v4
        with:
          path: ${{ env.USERPROFILE }}\.nuget\packages
          key: nuget-global-${{ hashFiles('scripts/VERSIONS.txt', 'scripts/infra/shared/shared.cake') }}
          restore-keys: |
            nuget-global-
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
          key: docs-package-cache-${{ hashFiles('scripts/VERSIONS.txt', 'scripts/infra/shared/shared.cake') }}
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
    env:
      SKIASHARP_BRANCH: ${{ inputs.skiasharp_branch || 'main' }}
    run: |
      git clone --depth 1 --branch "$SKIASHARP_BRANCH" \
        --recurse-submodules --shallow-submodules \
        https://github.com/mono/SkiaSharp.git skiasharp
      mkdir -p skiasharp/docs
      ln -sfn "$(pwd)/SkiaSharpAPI" skiasharp/docs/SkiaSharpAPI
      cd skiasharp && dotnet tool restore

  - name: Extract placeholders and manifest
    run: |
      mkdir -p output/docs-work
      pwsh skiasharp/.agents/skills/api-docs/scripts/docs-tool.ps1 extract SkiaSharpAPI/ -Output output/docs-work/

# -- Post-agent steps (host) ------------------------------------------
# Format docs AFTER the agent merges JSON→XML. Runs on host outside the
# sandbox so it has full access to the SkiaSharp cake scripts.
post-steps:
  - name: Format docs
    run: cd skiasharp && dotnet cake --target=docs-format-docs
---

# Auto API Docs Writer

**Read `skiasharp/.agents/skills/api-docs/SKILL.md` for reference.** Follow the phases below — this workflow pre-computes Phases 1–2, so start at Phase 3.

## Execution order

1. **Phase 3 (Discover — lightweight)** — you are an **orchestrator**, not a writer. Read ONLY:
   - `output/docs-work/manifest.json` — file list and field counts
   - `skiasharp/.agents/skills/api-docs/references/patterns.md` — formatting rules
   - `skiasharp/.agents/skills/api-docs/references/skia-patterns.md` — domain knowledge
   
   **Do NOT pre-read JSON files or source code.** The writer agent handles its own discovery. Move to Phase 4 immediately after reading the manifest and references.

2. **Phase 4 (Write — 1 agent)** — launch **1** background `general-purpose` agent:
   - Use the writer prompt from SKILL.md Phase 4
   - The single writer reads ALL JSON files + corresponding C# source and fills documentation
   - Wait for the writer to complete before Phase 5

3. **Phase 5 (Review — 3 independent agents)** — launch **three** background `general-purpose` agents in parallel as described in SKILL.md Phase 5:
   - **Factual Claim Verifier** — reads source FIRST, then challenges every factual claim
   - **Code Example Verifier** — verifies every code example uses real APIs
   - **Quality Reviewer** — checks style, completeness, and patterns
   
   Wait for all three to complete, then fix all CRITICAL issues directly in the JSON files.

4. **Phase 6 (Merge)** — this is the critical step. Run:
   ```bash
   cd skiasharp && pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 merge ../output/docs-work/ && cd ..
   ```
   Do NOT run `docs-format-docs` — it runs automatically as a post-step after the agent finishes.

5. **Commit and PR** — commit the XML changes and create a pull request:
   ```bash
   git checkout -b automation/write-api-docs
   git add SkiaSharpAPI/
   git commit -m "Fill API documentation placeholders"
   ```
   Then use the `create_pull_request` tool:
   - Branch: `automation/write-api-docs`
   - Title: `Fill API documentation placeholders`
   - Body: `Automated AI-generated documentation for XML API docs with 'To be added.' placeholders.`

If there are no documentation changes after merging, call the `noop` tool instead.

## Critical rules

- **Sub-agents must NOT spawn their own sub-agents.** Each agent (writer and reviewers) must do all its work directly. Nested sub-agents hit the depth limit and cause timeouts.
- **Do NOT edit XML files directly** — edit only the JSON files in `output/docs-work/`.
- **Phase 6 MUST run.** If you skip the merge, no PR is created and the entire run is wasted.
- **Do NOT run `docs-format-docs`** — formatting runs automatically as a post-step.
- **Budget awareness:** After the writer completes and reviewers report, fix CRITICAL issues and proceed to merge+PR immediately. Do not re-run reviewers unless absolutely necessary.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
