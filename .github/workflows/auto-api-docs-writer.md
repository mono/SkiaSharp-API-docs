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
  # No pull_request trigger: the writer runs the full agentic pipeline and
  # opens a PR via safe-outputs. On a PR that edits this workflow, that PR
  # creation is blocked (protected workflow files), which red-flags the check.
  # The push-to-main trigger above still validates workflow changes after merge.
  workflow_dispatch:
    inputs:
      skiasharp_branch:
        description: "SkiaSharp branch to use for scripts and references"
        required: false
        default: "main"
        type: string

# -- Custom jobs -------------------------------------------------------
# Stub regeneration runs mdoc to produce the XML reference stubs. mdoc.exe is a
# .NET Framework tool, so on Linux it runs under Mono (docs.cake invokes it via mono);
# this lets the job run on ubuntu-latest instead of windows-latest. The managed GTK#
# reference assemblies mdoc needs are supplied from NuGet by the cake comparer (as --lib
# paths), so no system GTK# install is required — mono is the only extra dependency.
# Checks out SkiaSharp (public), runs scripts/infra/docs/generate-api-docs.sh, uploads
# the result as an artifact.
jobs:
  regenerate-stubs:
    runs-on: ubuntu-latest
    outputs:
      # 'true' only when the extract produced at least one type JSON with
      # 'To be added.' placeholders. Used to gate (skip) the agent job.
      has_placeholders: ${{ steps.extract.outputs.has_placeholders }}
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
          global-json-file: global.json
      - name: Setup Mono (runs mdoc.exe on Linux)
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends mono-complete
      - name: Cache NuGet global packages
        uses: actions/cache@v4
        with:
          path: ~/.nuget/packages
          key: nuget-global-${{ hashFiles('scripts/VERSIONS.txt', 'scripts/infra/shared/shared.cake') }}
          restore-keys: |
            nuget-global-
      - name: Cache NuGet package_cache
        uses: actions/cache@v4
        with:
          path: externals/package_cache
          key: docs-package-cache-${{ hashFiles('scripts/VERSIONS.txt', 'scripts/infra/shared/shared.cake') }}
          restore-keys: |
            docs-package-cache-
      - name: Regenerate API docs
        run: bash scripts/infra/docs/generate-api-docs.sh
      - name: Extract placeholders and manifest
        id: extract
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Path output/docs-work -Force | Out-Null
          & .agents/skills/api-docs/scripts/docs-tool.ps1 extract docs/SkiaSharpAPI/ -Output output/docs-work/
          # Signal downstream whether there is any work for the agent. The extract
          # writes one JSON per type that still has 'To be added.' placeholders (plus
          # manifest.json); zero such files means every API is already documented and
          # the agent job can be skipped entirely.
          $work = @(Get-ChildItem -Path output/docs-work -Filter *.json |
            Where-Object { $_.Name -ne 'manifest.json' })
          $hasPlaceholders = if ($work.Count -gt 0) { 'true' } else { 'false' }
          Write-Host "has_placeholders=$hasPlaceholders ($($work.Count) file(s) with placeholders)"
          "has_placeholders=$hasPlaceholders" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
      - name: Upload regenerated docs
        uses: actions/upload-artifact@v4
        with:
          name: docs-regenerated
          path: docs/SkiaSharpAPI/
          retention-days: 1
      - name: Upload extracted JSON (immutable baseline)
        uses: actions/upload-artifact@v4
        with:
          name: docs-extracted
          path: output/docs-work/
          retention-days: 7

# -- Agent gating ------------------------------------------------------
# Skip the agentic writer entirely when stub regeneration found no
# 'To be added.' placeholders. Without this gate the agent job still spins
# up (runner + Copilot CLI + sandbox containers) only to discover there is
# nothing to document and no-op. This top-level `if:` is applied to the
# agent job, which already depends on (needs) the regenerate-stubs job, so
# its `has_placeholders` output is available here.
if: ${{ needs.regenerate-stubs.outputs.has_placeholders == 'true' }}

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

  - name: Download pre-extracted JSON
    uses: actions/download-artifact@v4
    with:
      name: docs-extracted
      path: output/docs-work/

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

  - name: Save original JSON to agent artifact cache
    run: |
      mkdir -p /tmp/gh-aw/agent/docs-work-original
      cp -r output/docs-work/* /tmp/gh-aw/agent/docs-work-original/

# -- Post-agent steps (host) ------------------------------------------
# Format docs AFTER the agent merges JSON→XML. Runs on host outside the
# sandbox so it has full access to the SkiaSharp cake scripts.
post-steps:
  - name: Save final JSON to agent artifact cache
    run: |
      mkdir -p /tmp/gh-aw/agent/docs-work-final
      cp -r output/docs-work/* /tmp/gh-aw/agent/docs-work-final/

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
- **Budget awareness:** After the writer completes and reviewers report, fix CRITICAL issues and proceed to merge+PR immediately. Do not re-run reviewers unless absolutely necessary. **If you're past 10 minutes and haven't merged yet, skip Phase 5 (review) entirely and go straight to Phase 6 (merge) + PR. A PR without review is better than no PR.**
- **NEVER end a turn without a tool call while waiting for agents.** When you launch a background agent, you MUST call `read_agent` with `wait: true` in the SAME response. Do NOT output text saying "waiting" and end your turn — the session WILL terminate and all work is lost.
  - **Single agent:** `task(background)` + `read_agent(id, wait=true)` in the same response.
  - **Multiple agents:** Launch all agents, then call `read_agent` for THE FIRST ONE with `wait: true`. When it returns, call `read_agent` for the next, and so on. You MUST have an active `read_agent` call at all times until all agents complete.
  - **FORBIDDEN pattern:** Launching agents → saying "Waiting for them to complete" → ending turn. This KILLS the session.
- **COMPLETION GATE:** Your session is NOT complete until you have called `create_pull_request` or `noop`. If you reach a point where you think you're done but haven't called either, something went wrong — retrace your steps and complete the remaining phases.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
