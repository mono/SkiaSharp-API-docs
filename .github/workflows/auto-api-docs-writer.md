---
description: "Daily API documentation pipeline — regenerates XML stubs from CI NuGets, then AI (1) fills 'To be added.' placeholders [add] and (2) reviews & improves a scope of existing docs [review], editing the mdoc XML directly."

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

# -- Engine (pin the run model) ---------------------------------------
# Per-role model routing is cosmetic in the gh-aw sandbox: the task tool's
# `model` param is not plumbed through to the actual API call (verified via the
# api-proxy token-usage log — every call was claude-sonnet-4.6 regardless of the
# requested per-agent model). So pin one good model for the whole run — the
# orchestrator and every sub-agent — rather than pretend to route per role.
engine:
  id: copilot
  model: claude-sonnet-4.6

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

  # The review half of the pipeline audits a scope of EXISTING docs (not just the
  # newly-filled placeholders). The scope is baked here rather than as a dispatch
  # input so the workflow stays dispatchable on a feature branch (workflow_dispatch
  # validates inputs against the default branch). For the daily common path this is
  # the high-value text/font slice; change to `changed` to review just-touched docs.
  - name: Record review scope
    run: |
      printf '%s' "group:text" > review-scope.txt
      echo "Review scope (existing docs): $(cat review-scope.txt)"

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

You are the **orchestrator** for the unified `add` + `review` pipeline. You run **two passes** in one job:
**(A) Add** — fill `To be added.` placeholders on newly-regenerated stubs; **(R) Review** — audit and improve
a scope of **existing** docs. Read these first, then drive the phases below:

- `skiasharp/.agents/skills/api-docs/SKILL.md` — the router.
- `skiasharp/.agents/skills/api-docs/workflows/add.md` — the direct-XML add pipeline (pass A).
- `skiasharp/.agents/skills/api-docs/workflows/review.md` — the review pipeline (pass R). Its per-role model
  table is **local-only**; on CI ignore it and run every role on the pinned `engine.model` (see Model routing).
- `skiasharp/.agents/skills/api-docs/workflows/scope-resolution.md` — how a scope selector resolves to files.
- `skiasharp/.agents/skills/api-docs/workflows/validation.md` — the post-edit gates.

The stub regeneration (mdoc) already ran as a pre-step, so the placeholder `*.xml` files are present in
`SkiaSharpAPI/` as uncommitted working-tree changes. There is **no extract/merge JSON step** — agents read
and **edit the mdoc XML directly**; safety comes from the structural validator, not a merge guard.

## Model routing

The orchestrator **and** every sub-agent run on the single run model (`engine.model`, pinned to
`claude-sonnet-4.6`). Launch sub-agents via the `task` tool **without** a per-role `model` parameter — they
inherit the run model. You delegate **bulk** writing (pass-A placeholder fill) and all reviewing to
sub-agents, but you perform the **terminal** fixes, validation, commit, and PR **yourself** (see Critical
rules).

> Per-role model routing (premium models for writer/factual/examples) is a **skill feature that only takes
> effect on hosts that honor the `task` tool's `model` parameter** (e.g. the local Copilot CLI). The gh-aw CI
> sandbox does **not** plumb per-sub-agent models to the actual API call, so passing them here is cosmetic and
> only adds risk. Do not pass per-role models, and do not emit a routing report on CI.

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

### Pass A — Add (fill placeholders)

A1. **Discover (lightweight).** Resolve the placeholder files into an explicit list and shard it into
   ~25–40-file batches. Do **not** pre-read source or XML — the writer does its own discovery.
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 resolve-scope new && cd ..
   ```

A2. **Write (per batch).** For each batch, launch the **writer** sub-agent (`agents/writer.md`) as a
   background `task` (no per-role model) with the resolved file list, and await it with
   `read_agent(wait: true)`. It reads the C# source, fills only the empty/`To be added.` fields, and edits the
   XML in place. A type it cannot document with certainty keeps its placeholder (a `DEFERRED` line) so the
   next run re-detects it.

A3. **Review the written batch.** Run the deterministic linter, then launch the **three** reviewers as
   background `task`s in parallel (`reviewer-factual`, `reviewer-examples`, `reviewer-quality`) on the
   batch's files (no per-role model), awaiting them per the anti-termination rule. **You** synthesize their
   findings — there is no synthesizer sub-agent.

A4. **Fix CRITICAL findings yourself** — **you (the orchestrator) edit the XML directly** in the foreground.
   Do **not** launch a sub-agent for these fixes. Skip MINOR/style for the automated run.

> If `resolve-scope new` returns **no** placeholder files (the common case once docs are filled), pass A is a
> no-op — skip straight to pass R.

### Pass R — Review existing docs (a scope, not just placeholders)

The review scope is in `review-scope.txt` at the workspace root (a selector like `group:text`). This audits
docs that are **already filled**, which is where freshness/accuracy/example problems live.

R1. **Resolve the review scope** (fuzzy selectors need `-Confirm:$false` in CI):
   ```bash
   SCOPE="$(cat review-scope.txt)"
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 resolve-scope "$SCOPE" -Confirm:$false && cd ..
   ```
   Shard >40 files into batches; the text/font slice is ~16 files (one batch).

R2. **Lint** the scope (deterministic, no model):
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 lint "$SCOPE" && cd ..
   ```

R3. **Review (three reviewers in parallel)** on the resolved file list as background `task`s (no per-role
   model), awaiting them per the anti-termination rule; they report only. **You** synthesize the linter
   output + all three reviewers' findings yourself — there is no synthesizer sub-agent.

R4. **Fix (gated) yourself** — **you (the orchestrator) edit the XML directly** in the foreground; do **not**
   launch a sub-agent. Priority order: (a) all **CRITICAL** findings, (b) **obsolete-in-example** findings (the
   text/font slice has legacy `paint.TextSize` / `TextAlign` / `DrawText(string,x,y,paint)` examples — migrate
   them to `SKFont`), (c) where a central type is example-poor (`SKFont`, `SKTypeface`, `SKPaint`), add one
   correct, **compiling** example, porting the `SKCanvas`/`SKShader` quality bar. **Budget:** once the
   reviewers report, timebox fixing to ~10 minutes — then stop, validate what you have, and open the PR. A
   smaller validated PR beats none.

### Finalize

V. **Validate (replaces merge).** This gate makes direct editing safe — it must pass before the PR, and it
   covers **all** edits from both passes:
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 validate new && cd ..
   ```
   `new` resolves to every changed `.xml` (placeholders + reviewed files) via the working-tree diff. It asserts
   each is well-formed, has unchanged signature counts, and changed **only** inside `<Docs>`. Do **not** run
   `docs-format-docs` — formatting runs automatically as a post-step.

C. **Commit and PR.** If any pass produced edits, **always move to the dedicated `automation/write-api-docs`
   branch first** — use `-B` so it works whether or not the branch exists, and stage **only** `SkiaSharpAPI/`:
   ```bash
   git checkout -B automation/write-api-docs
   git add SkiaSharpAPI/
   git commit -m "Fill and review API documentation"
   ```
   **Do this even if you are already on a feature branch that is ahead of `main`.** Never commit doc changes
   onto the branch the workflow was dispatched from: that branch may be the workflow's own source branch, and
   `safe-outputs` (`recreate_ref: true`) force-overwrites the PR head ref — committing on the dispatch ref
   would destroy the workflow source. Staging only `SkiaSharpAPI/` also keeps any workflow files out of the PR.
   Then use the `create_pull_request` tool:
   - Branch: `automation/write-api-docs`
   - Title: `Fill and review API documentation`
   - Body: include (a) what pass A filled (file count) and what pass R reviewed (scope + file count), (b) a
     short **Findings summary** (counts by severity + the machine `FINDING |` block), and (c) what you fixed
     vs deferred.

If there are no documentation changes after validation, call the `noop` tool instead — but still print the
Findings summary to stdout first.

## Critical rules

- **Edit the mdoc XML directly.** There is no JSON round-trip. Touch only `<Docs>` content — never
  `MemberSignature`/`TypeSignature`, attributes, or generated files (`index.xml`, `ns-*.xml`, `_filter.xml`,
  `FrameworksIndex/`). The structural validator enforces this; a failure means you edited outside `<Docs>`.
- **The validate gate (step V) MUST pass before the PR.** If you skip it, a malformed or surface-changing edit can ship.
- **Sub-agents must NOT spawn their own sub-agents.** Each agent does all its work directly — nested sub-agents
  hit the depth limit and time out.
- **Do NOT run `docs-format-docs`** — formatting runs automatically as a post-step.
- **Every code example you add or change must compile** against the real `SkiaSharp.dll` (bootstrapped in a
  pre-step) and use **no obsolete members** (see `references/obsolete-api-map.md`). A non-compiling example is
  worse than none.
- **No terminal background agent.** The only sub-agents you launch are the pass-A **writer** (bulk placeholder
  fill) and the **reviewers**. ALL fixing, synthesis, validation, committing, and PR creation is **your own
  foreground work** — never delegate the terminal fix/validate/PR to a sub-agent. The failure mode this avoids:
  backgrounding a "fixer" sub-agent and then ending your turn before it (and the PR) complete, which kills the
  session with no PR.
- **Budget awareness:** Prioritize reaching validate + PR. Pass A (add) is usually a no-op now, so spend the
  budget on pass R. Do not re-run reviewers unnecessarily. **Once the reviewers report, timebox your fixing to
  ~10 minutes; if you exceed it, stop fixing, validate what you have, and open the PR.** A smaller validated PR
  beats none — but never skip step V.
- **NEVER end a turn without a tool call while waiting for agents.** When you launch a background agent, you
  MUST call `read_agent` with `wait: true` in the SAME response. Outputting "waiting" and ending the turn
  terminates the session and loses all work.
  - **Single agent:** `task(background)` + `read_agent(id, wait=true)` in the same response.
  - **Multiple agents:** launch all, then `read_agent` the first with `wait: true`; when it returns, read the
    next, and so on. Keep an active `read_agent` call at all times until all agents complete.
  - **FORBIDDEN:** launching agents → "Waiting for them to complete" → ending the turn. This KILLS the session.
- **Always commit on the dedicated `automation/write-api-docs` branch (`git checkout -B`), never on the branch
  you were dispatched from.** `safe-outputs` preserves the branch you commit on and force-overwrites it
  (`recreate_ref: true`). If you commit on the dispatch ref (which can be the workflow's own source branch),
  that branch is destroyed. Switch branches before committing even when already on a feature branch ahead of
  `main`, and stage only `SkiaSharpAPI/`.
- **COMPLETION GATE:** Your session is NOT complete until **you** have called `create_pull_request` or `noop`
  yourself. If you think you're done but did neither, retrace your steps and finish. Reaching this gate is your
  own job, not a sub-agent's.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
