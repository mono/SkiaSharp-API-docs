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
      docs_base_branch:
        description: "Docs branch the PR targets and stubs align to (default main). Point at an older branch to demo add-at-scale."
        required: false
        default: "main"
        type: string
      docs_head_branch:
        description: "Throwaway PR head branch the agent commits to (force-recreated each run)."
        required: false
        default: "automation/write-api-docs"
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
      - name: Align docs to base branch
        shell: bash
        env:
          DOCS_BASE_BRANCH: ${{ inputs.docs_base_branch || 'main' }}
        run: |
          cd docs
          git fetch origin "$DOCS_BASE_BRANCH"
          git checkout -B stub-base FETCH_HEAD
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
# Primary: this docs repo only, pinned to docs_base_branch — NOT the dispatch ref.
# The stubs are regenerated against docs_base_branch and the PR targets it too, so
# checking the working tree out at the same ref keeps all three in agreement; without
# this pin, dispatching on a feature branch would review the wrong base and produce a
# polluted diff. SkiaSharp is cloned separately in pre-agent-steps.
checkout:
  - fetch-depth: 1
    ref: ${{ inputs.docs_base_branch || 'main' }}
timeout-minutes: 120
concurrency:
  group: auto-api-docs-writer
  cancel-in-progress: true

# -- Engine (pin the run model) ---------------------------------------
# Single agent, single model. The gh-aw sandbox does not honor per-sub-agent
# model routing (the task tool's `model` param is not plumbed through to the
# actual API call — verified via the api-proxy token-usage log), so there is no
# point fanning out into per-role sub-agents. One capable model does the whole
# run: add + review + fix + PR.
engine:
  id: copilot
  model: claude-opus-4.7

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
    base-branch: ${{ inputs.docs_base_branch || 'main' }}
    preserve-branch-name: true
    recreate-ref: true

# -- Pre-agent steps (host) -------------------------------------------
pre-agent-steps:
  # The primary checkout already put the working tree on docs_base_branch (see the
  # checkout block). gh-aw leaves that on the dispatch ref's branch name, and the
  # agent will commit there; safe-outputs (recreate_ref) then force-overwrites that
  # ref. If that branch were the workflow's own source (a dev/* branch under review),
  # the force-push would destroy it. So move onto a throwaway head branch up-front —
  # every commit and the PR head land there, never on the dispatch ref. The base
  # content is unchanged (still docs_base_branch); only the branch name changes.
  - name: Use a dedicated PR branch (never the dispatch ref)
    env:
      DOCS_HEAD_BRANCH: ${{ inputs.docs_head_branch || 'automation/write-api-docs' }}
    run: |
      git checkout -B "$DOCS_HEAD_BRANCH"
      echo "Working branch: $(git branch --show-current)"

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

# -- Post-agent steps (host) ------------------------------------------
# Format docs AFTER the agent edits the XML in place. Runs on host outside the
# sandbox so it has full access to the SkiaSharp cake scripts.
post-steps:
  - name: Format docs
    run: cd skiasharp && dotnet cake --target=docs-format-docs
---

# Auto API Docs Writer

This workflow is a **trigger** for the SkiaSharp **api-docs** skill, run daily as a two-pass pipeline.
**Load the skill and let it drive** — it is the single source of truth for *how* to add and review docs.
Do the whole job yourself in the foreground; do **not** launch sub-agents.

**Read first:** `skiasharp/.agents/skills/api-docs/SKILL.md` (the router). It points to
`references/adding.md` (add pass), `references/reviewing.md` (review pass), and the fact tables. Follow
those procedures — everything below is only the run-specific wiring the skill does not cover.

## This run: format → work → format

The deterministic gate `docs-format-docs` is **also your work-finder**: it lints every type file and prints a
`[docs] <class> | file | docId | message` line per fixable defect. Run it **first** to collect the to-do
list, **work** the files, then run it **again** to validate. It is **only the lint layer** — the real
correctness work is the three reviewers in `references/reviewing.md`, which it cannot do.

1. **Collect.** `cd skiasharp && dotnet cake --target=docs-format-docs && cd ..` — capture its `[docs]`
   findings (obsolete-in-example, accessor-verb, spelling, repeated-word, …). Those, plus any newly-introduced
   `To be added.` placeholders (uncommitted stub changes under `SkiaSharpAPI/`) and the files changed vs the
   base, are your work set. The run also reformats in place (idempotent, harmless).

2. **Work, source-first, per the skill.** For each file in the set:
   - **Add** — fill `To be added.` placeholders per `references/adding.md` (read the C# source first).
   - **Review** — run all three correctness reviewers from `references/reviewing.md`: **A. Factual** (claims
     vs source, cite `path:line`), **B. Examples** (every snippet compiles, real APIs, **no obsolete
     members**), **C. Quality** (.NET conventions, completeness, style). The deterministic findings only seed
     this — the factual/example/quality errors are yours to find and are where the real problems hide.
   - **Fix** CRITICAL findings (and every obsolete-in-example) by editing the XML directly; where a central
     type is example-poor, add one correct, non-obsolete example. Touch only `<Docs>` content.
   Work in batches of ~25–40 files. **Timebox fixing to ~10 minutes**, then stop — a smaller PR beats none.

3. **Validate.** Re-run `cd skiasharp && dotnet cake --target=docs-format-docs && cd ..` and fix anything it
   still reports. It **fails the run on broken XML/CDATA**, so every file you touched must stay well-formed.
   (The host re-runs it after you as a backstop, but you own getting it green.)

## Paths in this workflow

The **docs repo is the workspace root**; the SkiaSharp clone (skill, cake scripts, `binding/` source) is at
`skiasharp/`, with `skiasharp/docs/SkiaSharpAPI` symlinked to the workspace `SkiaSharpAPI/`. Translate
SKILL.md paths accordingly:

| SKILL.md reference | Here |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (workspace root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/`, `binding/HarfBuzzSharp/` | `skiasharp/binding/...` |

## Commit and open the PR

1. **Commit on the branch you are already on** — the host prepared a dedicated throwaway PR branch before you
   started; it is **not** the dispatch ref. Do **not** `git checkout` or create another branch: safe-outputs
   force-overwrites the branch you commit on, so committing on the dispatch ref would destroy the workflow
   source. Stage only hand-edited type docs and drop the generated files:
   ```bash
   git add SkiaSharpAPI/
   git reset -q -- SkiaSharpAPI/index.xml 'SkiaSharpAPI/ns-*.xml' SkiaSharpAPI/_filter.xml SkiaSharpAPI/FrameworksIndex/
   git commit -m "Fill and review API documentation"
   ```
2. **Open the PR** with the `create_pull_request` tool — title `Fill and review API documentation`; body:
   what you filled (file count), what you reviewed (file count), a **Findings summary** (counts by severity +
   the machine `FINDING |` block from `references/reviewing.md`), and what you fixed vs deferred. If there are
   no changes, call `noop` instead — but print the Findings summary first.

**COMPLETION GATE:** the run is not done until you have called `create_pull_request` or `noop`.
