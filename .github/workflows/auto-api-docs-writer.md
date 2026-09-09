---
description: "Experimental deterministic API documentation pipeline — regenerates ECMA XML from compiler XML sidecars for an explicitly selected SkiaSharp source commit. It does not author prose, merge, or publish."

# -- Triggers ----------------------------------------------------------
on:
  # No pull_request trigger: the writer runs the full agentic pipeline and
  # opens a PR via safe-outputs. On a PR that edits this workflow, that PR
  # creation is blocked (protected workflow files), which red-flags the check.
  # The push-to-main trigger above still validates workflow changes after merge.
  workflow_dispatch:
    inputs:
      skiasharp_commit:
        description: "Exact SkiaSharp commit associated with the selected package build"
        required: true
        type: string
      docs_base_branch:
        description: "Experimental docs branch the generated PR targets"
        required: false
        default: "dev/csharp-docs-canonical"
        type: string
      docs_head_branch:
        description: "Throwaway generated-output PR head branch (force-recreated each run)."
        required: false
        default: "automation/csharp-docs-canonical"
        type: string

# -- Custom jobs -------------------------------------------------------
# Regeneration runs mdoc from compiler XML sidecars. mdoc.exe is a
# .NET Framework tool, so on Linux it runs under Mono (docs.cake invokes it via mono);
# this lets the job run on ubuntu-latest instead of windows-latest. The managed GTK#
# reference assemblies mdoc needs are supplied from NuGet by the cake comparer (as --lib
# paths), so no system GTK# install is required — mono is the only extra dependency.
# Checks out the exact source commit selected with the package build, writes directly
# to this docs checkout through an explicit output root, and uploads the result.
jobs:
  regenerate-stubs:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout experimental docs output
        uses: actions/checkout@v7.0.1
        with:
          ref: ${{ inputs.docs_base_branch || 'dev/csharp-docs-canonical' }}
          fetch-depth: 1
          path: docs-workspace
      - name: Checkout exact SkiaSharp source
        uses: actions/checkout@v7.0.1
        with:
          repository: mono/SkiaSharp
          ref: ${{ inputs.skiasharp_commit }}
          fetch-depth: 1
          submodules: false
          path: skiasharp
      - name: Setup .NET
        uses: actions/setup-dotnet@v6.0.0
        with:
          global-json-file: skiasharp/global.json
      - name: Setup Mono (runs mdoc.exe on Linux)
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends mono-complete
      - name: Cache NuGet global packages
        uses: actions/cache@v6.1.0
        with:
          path: ~/.nuget/packages
          key: nuget-global-${{ hashFiles('skiasharp/scripts/VERSIONS.txt', 'skiasharp/scripts/infra/shared/shared.cake') }}
          restore-keys: |
            nuget-global-
      - name: Cache NuGet package_cache
        uses: actions/cache@v6.1.0
        with:
          path: skiasharp/externals/package_cache
          key: docs-package-cache-${{ hashFiles('skiasharp/scripts/VERSIONS.txt', 'skiasharp/scripts/infra/shared/shared.cake') }}
          restore-keys: |
            docs-package-cache-
      - name: Regenerate API docs
        run: cd skiasharp && bash scripts/infra/docs/generate-api-docs.sh --docs-output-root "$GITHUB_WORKSPACE/docs-workspace"
      - name: Upload regenerated docs
        uses: actions/upload-artifact@v7.0.1
        with:
          name: docs-regenerated
          path: docs-workspace/SkiaSharpAPI/
          retention-days: 1

# -- Checkout ----------------------------------------------------------
# Primary: this docs repo only, pinned to the experimental base branch — NOT the
# dispatch ref. Generated output is never targeted at main or live.
checkout:
  - fetch-depth: 1
    ref: ${{ inputs.docs_base_branch || 'dev/csharp-docs-canonical' }}
timeout-minutes: 120
concurrency:
  group: auto-api-docs-writer
  cancel-in-progress: true

# -- Engine (pin the run model) ---------------------------------------
# The agent only packages deterministic host-generated changes into an
# experimental PR; it must not write prose or edit XML.
model: claude-opus-4.8
engine:
  id: copilot
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
    base-branch: ${{ inputs.docs_base_branch || 'dev/csharp-docs-canonical' }}
    preserve-branch-name: true
    recreate-ref: true
    max-patch-files: 500
    max-patch-size: 7168

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
      DOCS_HEAD_BRANCH: ${{ inputs.docs_head_branch || 'automation/csharp-docs-canonical' }}
    run: |
      # Unattended runs must never block on an interactive git pager or a
      # detached-HEAD advice prompt.
      git config --global core.pager cat
      git config --global advice.detachedHead false
      echo "GIT_PAGER=cat" >> "$GITHUB_ENV"
      echo "PAGER=cat" >> "$GITHUB_ENV"
      git checkout -B "$DOCS_HEAD_BRANCH"
      echo "Working branch: $(git branch --show-current)"

  - name: Download regenerated docs
    uses: actions/download-artifact@v8.0.1
    with:
      name: docs-regenerated
      path: SkiaSharpAPI/

  - name: Clone exact SkiaSharp source for validation
    env:
      SKIASHARP_COMMIT: ${{ inputs.skiasharp_commit }}
    run: |
      git clone --depth 1 --no-recurse-submodules \
        https://github.com/mono/SkiaSharp.git skiasharp
      git -C skiasharp fetch --depth 1 origin "$SKIASHARP_COMMIT"
      git -C skiasharp checkout --detach FETCH_HEAD
      echo "SkiaSharp HEAD: $(git -C skiasharp rev-parse HEAD)"
      cd skiasharp && dotnet tool restore

# -- Post-agent steps (host) ------------------------------------------
# Format docs AFTER the agent edits the XML in place. Runs on host outside the
# sandbox so it has full access to the SkiaSharp cake scripts.
post-steps:
  - name: Format docs
    run: cd skiasharp && dotnet cake --target=docs-format-docs --docsOutputRoot "$GITHUB_WORKSPACE"
---

# Experimental compiler-XML API docs generator

This workflow packages the deterministic host-generated ECMA XML output only.
It is Phase 1 infrastructure validation: do not fill placeholders, author prose,
or edit XML. Phase 2 separately migrates prose into C# source comments.

**Read first:** `skiasharp/.agents/skills/api-docs/SKILL.md` (the router). It points to
`references/adding.md` (add pass), `references/reviewing.md` (review pass), and the fact tables. Follow
those procedures — everything below is only the run-specific wiring the skill does not cover.

## This run: inspect → commit generated output

1. Inspect the generated diff. Do not alter its content.
2. Confirm its base is `dev/csharp-docs-canonical`, never `main` or `live`.
3. Do not use the api-docs skill: source-comment prose migration is out of scope.

## Paths in this workflow

The **docs repo is the workspace root** and generated output is
`SkiaSharpAPI/`. The separate `skiasharp/` checkout is used only to run the
generator and formatting target with `--docsOutputRoot "$GITHUB_WORKSPACE"`.
Never create a symlink between these workspaces.

## Commit and open the PR

1. **Commit generated output on the branch you are already on** — the host prepared a dedicated throwaway PR branch before you
   started; it is **not** the dispatch ref. Do **not** `git checkout` or create another branch: safe-outputs
   force-overwrites the branch you commit on, so committing on the dispatch ref would destroy the workflow
   source. Stage generated type docs and drop generated indexes:
   ```bash
   git add SkiaSharpAPI/
   git reset -q -- SkiaSharpAPI/index.xml 'SkiaSharpAPI/ns-*.xml' SkiaSharpAPI/_filter.xml SkiaSharpAPI/FrameworksIndex/
   git commit -m "Generate API docs from compiler XML"
   ```
2. **Open the PR** with the `create_pull_request` tool — title `Generate API docs from compiler XML`; state
   the exact SkiaSharp commit, package build selected by the dispatcher, and that this is experimental Phase 1
   output with intentionally incomplete compiler documentation. If there are no changes, call `noop`.

**COMPLETION GATE:** the run is not done until you have called `create_pull_request` or `noop`.