---
description: "Daily API documentation pipeline — regenerates XML stubs from CI NuGets, then AI fills 'To be added.' placeholders by editing the mdoc XML directly."

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

  # Build the managed binding so the example reviewer can compile-check snippets
  # against a real SkiaSharp.dll. C#-only — externals-download fetches prebuilt
  # natives (no native changes here). Non-fatal: a build hiccup must not sink the
  # whole docs run, since reviewers also verify examples by reading source.
  - name: Bootstrap SkiaSharp binding for snippet checks
    continue-on-error: true
    run: |
      cd skiasharp
      dotnet cake --target=externals-download
      dotnet build binding/SkiaSharp/SkiaSharp.csproj -c Release

# -- Post-agent steps (host) ------------------------------------------
# Format docs AFTER the agent edits the XML in place. Runs on host outside the
# sandbox so it has full access to the SkiaSharp cake scripts.
post-steps:
  - name: Format docs
    run: cd skiasharp && dotnet cake --target=docs-format-docs
---

# Auto API Docs Writer

You are the **orchestrator** for the `add` workflow. Read these first, then drive the phases below:

- `skiasharp/.agents/skills/api-docs/SKILL.md` — the router.
- `skiasharp/.agents/skills/api-docs/workflows/add.md` — the direct-XML add pipeline you are running.
- `skiasharp/.agents/skills/api-docs/workflows/review.md` — the review pass **and the per-role model table**.
- `skiasharp/.agents/skills/api-docs/workflows/validation.md` — the post-edit gates.

The stub regeneration (mdoc) already ran as a pre-step, so the placeholder `*.xml` files are present in
`SkiaSharpAPI/` as uncommitted working-tree changes. There is **no extract/merge JSON step** — agents read
and **edit the mdoc XML directly**; safety comes from the structural validator, not a merge guard.

## Model routing

You run on the default `engine.model` (cheap orchestrator). You do **not** write docs yourself. Launch every
sub-agent **via the `task` tool with an explicit `model`**, reading the per-role value from the table in
`workflows/review.md` and each agent file's `Model:` header (writer + examples → `claude-opus-4.6`;
factual → `gpt-5.5` per the eval bake-off; quality + synthesizer → `claude-sonnet-4.6`). If the sandbox does
not honor per-sub-agent `model` (the parent overrides it), proceed on `engine.model` for all roles and note
it in the PR body — do not abort.

## Scope environment

`docs-tool.ps1` lives in the SkiaSharp clone, so by default it would look for docs under
`skiasharp/docs`. In this workflow the **docs repo is the primary checkout** and the regenerated XML is
in `SkiaSharpAPI/` at the workspace root. Point the tool at it by exporting these on every
`docs-tool.ps1` call (they make `resolve-scope new`, `lint`, and `validate` use the docs repo for git
baselines/diffs while source lookups still use the SkiaSharp clone):

```bash
DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI"
```

## Execution order

1. **Discover (lightweight).** Resolve the placeholder files into an explicit list and shard it into
   ~25–40-file batches. Do **not** pre-read source or XML — the writer does its own discovery.
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 resolve-scope new && cd ..
   ```

2. **Write (per batch).** For each batch, launch the **writer** sub-agent (`agents/writer.md`, model from its
   header) with the resolved file list. It reads the C# source, fills only the empty/`To be added.` fields,
   and edits the XML in place. A type it cannot document with certainty keeps its placeholder (a `DEFERRED`
   line) so the next run re-detects it.

3. **Review (per batch).** Run the deterministic linter, then launch the **three** reviewers in parallel
   (`reviewer-factual`, `reviewer-examples`, `reviewer-quality`), each on the batch's files with its assigned
   model. Feed all findings to `review-synthesizer`.
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 lint new && cd ..
   ```

4. **Fix CRITICAL findings** by editing the XML directly. Skip MINOR/style for the automated run.

5. **Validate (replaces merge).** This is the gate that makes direct editing safe — it must pass before the PR:
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 validate new && cd ..
   ```
   It asserts each changed file is well-formed, has unchanged signature counts, and changed **only** inside
   `<Docs>`. Do **not** run `docs-format-docs` — formatting runs automatically as a post-step.

6. **Commit and PR.** Commit the XML changes and open a pull request:
   ```bash
   git checkout -b automation/write-api-docs
   git add SkiaSharpAPI/
   git commit -m "Fill API documentation placeholders"
   ```
   Then use the `create_pull_request` tool:
   - Branch: `automation/write-api-docs`
   - Title: `Fill API documentation placeholders`
   - Body: `Automated AI-generated documentation for XML API docs with 'To be added.' placeholders.`

If there are no documentation changes after validation, call the `noop` tool instead.

## Critical rules

- **Edit the mdoc XML directly.** There is no JSON round-trip. Touch only `<Docs>` content — never
  `MemberSignature`/`TypeSignature`, attributes, or generated files (`index.xml`, `ns-*.xml`, `_filter.xml`,
  `FrameworksIndex/`). The structural validator enforces this; a failure means you edited outside `<Docs>`.
- **Step 5 (validate) MUST pass before the PR.** If you skip it, a malformed or surface-changing edit can ship.
- **Sub-agents must NOT spawn their own sub-agents.** Each agent does all its work directly — nested sub-agents
  hit the depth limit and time out.
- **Do NOT run `docs-format-docs`** — formatting runs automatically as a post-step.
- **Budget awareness:** Fix CRITICAL findings and proceed to validate + PR promptly. Do not re-run reviewers
  unless necessary. **If you're past 10 minutes and haven't reached step 5, skip review (step 3) entirely and
  go straight to validate + PR.** A validated PR without review beats no PR — but never skip step 5.
- **NEVER end a turn without a tool call while waiting for agents.** When you launch a background agent, you
  MUST call `read_agent` with `wait: true` in the SAME response. Outputting "waiting" and ending the turn
  terminates the session and loses all work.
  - **Single agent:** `task(background)` + `read_agent(id, wait=true)` in the same response.
  - **Multiple agents:** launch all, then `read_agent` the first with `wait: true`; when it returns, read the
    next, and so on. Keep an active `read_agent` call at all times until all agents complete.
  - **FORBIDDEN:** launching agents → "Waiting for them to complete" → ending the turn. This KILLS the session.
- **COMPLETION GATE:** Your session is NOT complete until you have called `create_pull_request` or `noop`. If
  you think you're done but called neither, retrace your steps and finish the remaining phases.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
