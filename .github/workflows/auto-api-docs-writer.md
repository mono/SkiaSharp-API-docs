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
      review_scope:
        description: "Review-pass scope: an inventory mode (all/new/changed/file:PATH) or a plain-English theme the agent resolves (e.g. text, image filters)."
        required: false
        default: "text"
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
# Primary: this docs repo only. SkiaSharp is cloned in pre-agent-steps.
checkout:
  - fetch-depth: 1
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
  # gh-aw's checkout step makes the dispatch ref the working branch. If the agent
  # commits there, safe-outputs (recreate_ref) force-overwrites that ref — which
  # destroys the workflow's own source branch when the run is dispatched from a
  # feature branch (e.g. a dev/* branch under review). Rename the working branch
  # up-front so every commit and the PR head land on a throwaway branch, no matter
  # which ref triggered the run. The branch name is the `docs_head_branch` input
  # (default automation/write-api-docs). This is the host-side guarantee that backs
  # up the "commit on the branch you're already on" rule in the prompt.
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

  # The review half of the pipeline audits a scope of EXISTING docs (not just the
  # newly-filled placeholders). The scope is baked here rather than as a dispatch
  # input so the workflow stays dispatchable on a feature branch (workflow_dispatch
  # validates inputs against the default branch). It can be an inventory mode
  # (all/new/changed/file:PATH) or a plain-English theme the agent resolves; the
  # daily default is the high-value `text` theme. Use `changed` to review just-touched docs.
  - name: Record review scope
    env:
      REVIEW_SCOPE: ${{ inputs.review_scope || 'text' }}
    run: |
      printf '%s' "$REVIEW_SCOPE" > review-scope.txt
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

You are the agent for the unified `add` + `review` pipeline. You run **two passes** in one job:
**(A) Add** — fill `To be added.` placeholders on newly-regenerated stubs; **(R) Review** — audit and improve
a scope of **existing** docs. You do the whole job yourself — there is **no sub-agent fan-out**. Read these
first, then drive the phases below:

- `skiasharp/.agents/skills/api-docs/SKILL.md` — the router.
- `skiasharp/.agents/skills/api-docs/references/adding.md` — the direct-XML add procedure (pass A).
- `skiasharp/.agents/skills/api-docs/references/reviewing.md` — the review procedure + checks (pass R).
- `skiasharp/.agents/skills/api-docs/references/validation.md` — the post-edit gates.

The stub regeneration (mdoc) already ran as a pre-step, so the placeholder `*.xml` files are present in
`SkiaSharpAPI/` as uncommitted working-tree changes. You read and **edit the mdoc XML directly**; safety
comes from the post-step `docs-format-docs` gate (it fails the run on broken XML), not a merge guard.

## Where the files are

The docs repo is the **primary checkout** at the workspace root; the regenerated and edited mdoc XML lives
under `SkiaSharpAPI/`. The SkiaSharp clone (cake scripts + skill + `binding/` source) is at `skiasharp/`,
and `skiasharp/docs/SkiaSharpAPI` is symlinked to the workspace `SkiaSharpAPI/`, so the post-step
`docs-format-docs` gate checks your edits directly. Discover files with plain `git`/`find` against the
workspace checkout — there is no scope/lint cake target to call.

## Execution order

### Pass A — Add (fill placeholders)

A1. **Discover.** The regenerated stubs are uncommitted working-tree changes. List the changed type docs
   that still hold a `To be added.` placeholder (excluding generated files), and shard into ~25–40-file
   batches:
   ```bash
   git status --porcelain -- SkiaSharpAPI/ | awk '{print $2}' \
     | grep -E '\.xml$' | grep -vE '(^|/)(index|_filter|ns-[^/]*)\.xml$|/FrameworksIndex/' \
     | xargs -r grep -l 'To be added\.'
   ```

A2. **Write (per batch), yourself.** Following `references/adding.md`, for each file read the C# source first,
   then fill only the empty/`To be added.` fields and edit the XML in place. A type you cannot document with
   certainty keeps its placeholder (note it as a `DEFERRED` line) so the next run re-detects it. Process the
   batches one at a time so each stays in working memory.

A3. **Review the written batch.** Review the batch's files against the checks in `references/reviewing.md`
   and note the findings. To surface the deterministic findings (`obsolete-in-example`, accessor-verb,
   spelling, …) you may run `cd skiasharp && dotnet cake --target=docs-format-docs && cd ..` — it prints
   `[docs] <class> | …` lines and also formats (harmless, idempotent).

A4. **Fix CRITICAL findings yourself** by editing the XML directly. Skip MINOR/style for the automated run.

> If no changed `*.xml` still contains `To be added.` (the common case once docs are filled), pass A is a
> no-op — skip straight to pass R.

### Pass R — Review existing docs (a scope, not just placeholders)

The review scope is in `review-scope.txt` at the workspace root — either an inventory mode (`all` /
`new` / `changed` / `file:PATH`) or a plain-English theme. This audits docs that are **already filled**,
which is where freshness/accuracy/example problems live.

R1. **Turn the review scope into a concrete file list** with plain `git`/`find` against the workspace docs
   (always drop generated files: `index.xml`, `ns-*.xml`, `_filter.xml`, `FrameworksIndex/`).
   ```bash
   SCOPE="$(cat review-scope.txt)"
   ```
   - `changed` / `new`: the working-tree diff — `git status --porcelain -- SkiaSharpAPI/ | awk '{print $2}'`.
   - `all`: every non-generated type doc — `find SkiaSharpAPI -name '*.xml'`.
   - `file:PATH`: that one path.
   - Otherwise `$SCOPE` is a **plain-English theme** (e.g. `text`). List `all`, then select the files whose
     type/namespace fits the theme yourself. For `text` that is the `SKFont*` / `SKTextBlob*` /
     `SKFontMetrics` / `SKPaint` / `SKCanvas` text APIs (~16 files, one batch).

   Shard >40 files into batches and process them one at a time.

R2. **(Optional) Surface deterministic findings.** Run `cd skiasharp && dotnet cake --target=docs-format-docs
   && cd ..` to print the `[docs] <class> | …` findings (obsolete-in-example, accessor-verb, spelling,
   repeated word, …) across the tree. This is the same deterministic check the post-step gate runs; it also
   formats (harmless). Fold its output into your own review below.

R3. **Review, yourself.** For each file in the resolved list, follow `references/reviewing.md`: read the C#
   source first, then run the factual / example / quality checks against the `<Docs>` blocks. Collect the
   deterministic findings plus your own into one deduped list.

R4. **Fix (gated) yourself** by editing the XML directly. Priority order: (a) all **CRITICAL** findings,
   (b) **obsolete-in-example** findings (text APIs often carry legacy `paint.TextSize` / `TextAlign` /
   `DrawText(string,x,y,paint)` examples — migrate them to `SKFont`), (c) where a central type is example-poor
   (`SKFont`, `SKTypeface`, `SKPaint`), add one correct, **compiling** example, porting the `SKCanvas`/
   `SKShader` quality bar. **Budget:** timebox fixing to ~10 minutes — then stop and open the PR. A smaller
   PR beats none.

### Finalize

V. **The validation gate is automatic.** The host post-step runs `docs-format-docs`, which formats every doc
   and **fails the run on broken XML/CDATA** (`malformed-xml` / `broken-cdata`) — so a malformed edit can
   never ship a PR. You do **not** run it as your final step. Just make sure every file you touched stays
   well-formed and you changed only `<Docs>` content (signatures are owned by mdoc regeneration).

C. **Commit and PR.** If any pass produced edits, **commit on the branch you are already on** — the host
   prepared a dedicated throwaway PR branch for you before you started (it is **not** the dispatch ref). Do
   **not** switch or create another branch. Stage **only** hand-edited type docs under `SkiaSharpAPI/`, and
   **unstage the generated files** (stub regeneration rewrites them; they must never appear in the PR):
   ```bash
   git add SkiaSharpAPI/
   git reset -q -- SkiaSharpAPI/index.xml 'SkiaSharpAPI/ns-*.xml' SkiaSharpAPI/_filter.xml SkiaSharpAPI/FrameworksIndex/
   git commit -m "Fill and review API documentation"
   ```
   **Never `git checkout` the branch the workflow was dispatched from.** That branch may be the workflow's own
   source branch, and `safe-outputs` (`recreate_ref: true`) force-overwrites the PR head ref — committing on the
   dispatch ref would destroy the workflow source. Staging only `SkiaSharpAPI/` also keeps any workflow files out
   of the PR. Then use the `create_pull_request` tool:
   - Branch: the current working branch (leave the `create_pull_request` branch to the host default — do not
     hardcode a name)
   - Title: `Fill and review API documentation`
   - Body: include (a) what pass A filled (file count) and what pass R reviewed (scope + file count), (b) a
     short **Findings summary** (counts by severity + the machine `FINDING |` block), and (c) what you fixed
     vs deferred.

If there are no documentation changes, call the `noop` tool instead — but still print the Findings summary
to stdout first.

## Critical rules

- **Edit the mdoc XML directly.** Touch only `<Docs>` content — never
  `MemberSignature`/`TypeSignature`, attributes, or generated files (`index.xml`, `ns-*.xml`, `_filter.xml`,
  `FrameworksIndex/`). Signatures are owned by mdoc regeneration and are visible in the PR diff.
- **The post-step `docs-format-docs` gate MUST pass.** Any `malformed-xml` / `broken-cdata` error fails the
  run and blocks the PR, so keep every edit well-formed.
- **You need not run `docs-format-docs` yourself** — formatting and the deterministic checks run automatically
  as the post-step. You *may* run it mid-pass to read its findings (it is idempotent), but never rely on it as
  your final step.
- **Every code example you add or change must compile** against the real `SkiaSharp.dll` (bootstrapped in a
  pre-step) and use **no obsolete members** (see `references/obsolete-api-map.md`). A non-compiling example is
  worse than none.
- **Do everything yourself, in the foreground.** Do **not** launch sub-agents — discovery, writing, review,
  fixing, committing, and PR creation are all your own work. The gh-aw sandbox does not honor
  per-sub-agent models, and backgrounding a terminal agent and then ending your turn before the PR is created
  kills the session with no PR.
- **Budget awareness:** Prioritize reaching the PR. Pass A (add) is usually a no-op now, so spend the budget
  on pass R. **Timebox your fixing to ~10 minutes; if you exceed it, stop fixing and open the PR.** A smaller
  PR beats none — the post-step gate still validates whatever you ship.
- **Always commit on the branch you are already on** (the host prepared a dedicated throwaway PR branch before
  you started) and **never `git checkout` the branch you were dispatched from.** `safe-outputs` preserves the
  branch you commit on and force-overwrites it (`recreate_ref: true`). If you commit on the dispatch ref (which
  can be the workflow's own source branch), that branch is destroyed. Do not switch or create another branch
  even when the current branch looks like a feature branch ahead of `main`, and stage only `SkiaSharpAPI/`.
- **COMPLETION GATE:** Your session is NOT complete until you have called `create_pull_request` or `noop`.
  If you think you're done but did neither, retrace your steps and finish.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
