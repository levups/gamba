# Gamba

Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 rewritten for speed: same API, same pages pixel for pixel, lighter
files. `lib/prawn*.rb` and `lib/pdf` answer Prawn's requires; the code lives in `lib/gamba`.

`README.md` covers usage, `STYLE.md` code style, `CONTRIBUTING.md` contributions; this file adds what they leave out.

## Commands

```sh
bundle install && BUNDLE_GEMFILE=oracle/Gemfile bundle install  # Prawn runs from its own bundle
bundle exec rake corpus:fetch                                   # Prawn's manual and data, into corpus/cache
bundle exec rake test                                           # needs: brew install mupdf-tools poppler qpdf zbar dmtx-utils
ORACLE_CANDIDATE=prawn FUZZ_CASES=0 bundle exec rake test       # Prawn against itself: proves the oracle
FUZZ_SEED=42 FUZZ_CASES=500 bundle exec ruby -Itest test/fuzz_test.rb
INPUT_FUZZ_SEED=42 INPUT_FUZZ_CASES=400 bundle exec ruby -Itest test/input_fuzz_test.rb
LAYOUT_FUZZ_SEED=42 LAYOUT_FUZZ_CASES=1000 bundle exec ruby -Itest test/layout_fuzz_test.rb
bundle exec rubocop
bundle exec rake bench                                          # Prawn against Gamba, and Gamba tagged, writes docs/benchmarks.json
```

CI also runs `ruby-head` and `truffleruby-head`, and the oracle and the three fuzzers on a fresh seed.

## Traps

- Prawn's public API, listed in `test/contract/prawn-2.5.0.yml`, keeps working; exceptions are settled in
  `test/contract/decisions.yml`.
- Valid documents give pages identical to Prawn's. Anything that would move pixels (ligatures, kerning, PDF/A) is
  opt-in.
- Never reproduce a Prawn bug: a crash, an invalid PDF, or behaviour contradicting Prawn's documentation or the PDF
  specification. Each fix is a declared divergence: an entry with its proof in `test/divergences.yml`, a row in
  `docs/compatibility.html`, and a **Fixed** changelog entry at release.
- `Prawn::VERSION` stays `2.5.0`, the API we reproduce; `Gamba::VERSION` is the gem's own.
- Without `corpus/cache`, the oracle, fuzz and determinism tests skip: fetch it before trusting a green run.
- An example in `test/oracle_passing.txt` must stay identical to Prawn's; one that becomes identical joins the list.
- PDF/A tests use veraPDF when installed, and Mustang (`MUSTANG_JAR`, `JAVA`) for Factur-X.
- Gamba refuses to load with the prawn gem in the same bundle: Prawn only ever runs from `oracle/Gemfile`.

## Rules for all our gems

This section and the next two read the same in super-slim, gamba, crumbly, agentry and maptain: change all five
together.

You are the owner and long-term maintainer of this codebase, and its design is up to you. Its public API is a
promise to its users; everything behind it is yours to reshape when that serves them.

- Every maintained Ruby and Rails (https://endoflife.date), nothing older. The oldest sets `required_ruby_version`,
  `TargetRubyVersion` and the Rails floor, and leaves in the release after its end of life.
- CI runs RuboCop and the tests on each maintained Ruby. No macOS job: we test on our Macs.
- `.claude/hooks/rubocop.sh` autocorrects each Ruby file you edit.
- Measure performance without JIT and with YJIT. A Performance cop the numbers contradict is disabled on its line,
  with the reason. A pure performance change pins no internals in tests.
- Test and bench data are anonymized: `alice`, `Post`, `example.com`.
- `docs/llms.txt` (an index for coding agents) and `docs/llms-full.txt` (the README and
  the pages of `docs/`, in Markdown) come from `bundle exec rake docs:llms`: run it after changing the README or a page of
  `docs/`. CI checks them.
- Everything in the repository is in English (code, comments, commits, pull requests, issues, reviews, replies),
  whatever the conversation's language.
- No AI attribution in anything people read; commits flag AI help with `Assisted-by`, never `Co-Authored-By`.

## Pull requests and issues

- `main` takes no direct push: every change, releases included, goes through a pull request that merges itself once
  CI is green (`gh pr merge --auto --squash`).
- Drafts run no CI. Confident: open it ready, auto-merge on. Not yet: a draft, then `gh pr ready` when it needs CI.
- Never edit `CHANGELOG.md` in a pull request, they would all conflict: it is written at release time.
- Title: the change as a user sees it (an issue: the finding), in plain words, under 70 characters.
- Body, no headings: two short paragraphs, the problem then the change (an issue: what to do); 3 to 5 bullets, each
  opening with a **bold 2–4 word lead-in**; the proof (reproduction, tests, benchmarks) folded in one `<details>`.
  Nothing the diff or CI already says.
- Never hard-wrap a pull request, an issue or a comment: GitHub renders every line break. One line per paragraph and
  per bullet.

## Releases

The user is needed once: one click approving the `release` environment on GitHub. No key, no Mac.

1. Another session may have just released: `git fetch --tags origin`, and `gh pr list --search "head:release/"`
   must be empty. Unreleased changes: `git log --first-parent --oneline $(git describe --tags --abbrev=0 origin/main)..origin/main`,
   then `gh pr view <n>` for each.
2. Write the release under `## [Unreleased]` in `CHANGELOG.md`, uncommitted: a one-sentence lede, then **Breaking**,
   **New**, **Faster** (measured), **Fixed**, only those with entries. One entry per change users see, written for
   them; CI, refactoring, docs and tests get none. No version, date or link: `bin/release` adds them.
3. Show it to the user, wait for their go. From `main` level with `origin/main`, `CHANGELOG.md` its only change:
   `bin/release minor --dry-run`, then `bin/release minor --yes` (or `patch`, `major`). It opens `release/vX.Y.Z`,
   waits for it to merge itself, then opens the release run. Interrupted: `bin/release --wait X.Y.Z`. Where `gh pr`
   can't run, `bin/release minor --write` writes the changes: commit them, open the pull request with auto-merge.
4. The merge runs `release.yml`, which waits for the user to approve the `release` environment, then tags the merge
   commit `vX.Y.Z` and publishes to RubyGems and GitHub. Send them the run's link, where they click Review
   deployments, `release`, Approve (from their phone too). Then check RubyGems. A failed run runs again from its page,
   or with `gh workflow run release.yml`: each step skips what is done.

Only a merged pull request publishes: a version with notes in `CHANGELOG.md` and no tag yet. RubyGems trusts only
that workflow: never `gem push`, except a new gem name's first version, pushed by hand while its run waits for
approval. `bin/release` and `release.yml` are identical in all five gems.
