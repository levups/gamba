# Gamba

Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 rewritten for speed: same API, same pages pixel for pixel, lighter
files. `lib/prawn*.rb` and `lib/pdf` answer Prawn's requires; the code lives in `lib/gamba`.

Read `README.md` for usage, `STYLE.md` for code style and `CONTRIBUTING.md` for contributions; this file only
adds what they leave out.

## Commands

```sh
bundle install && BUNDLE_GEMFILE=oracle/Gemfile bundle install  # Prawn runs from its own bundle
bundle exec rake corpus:fetch                                   # Prawn's manual and data, into corpus/cache
bundle exec rake test                                           # needs: brew install mupdf-tools poppler qpdf
ORACLE_CANDIDATE=prawn FUZZ_CASES=0 bundle exec rake test       # Prawn against itself: proves the oracle
FUZZ_SEED=42 FUZZ_CASES=500 bundle exec ruby -Itest test/fuzz_test.rb
INPUT_FUZZ_SEED=42 INPUT_FUZZ_CASES=400 bundle exec ruby -Itest test/input_fuzz_test.rb
bundle exec rubocop
bundle exec rake bench                                          # Prawn against Gamba, writes docs/benchmarks.json
```

CI also runs `ruby-head` and `truffleruby-head`, and the oracle and both fuzzers on a fresh seed.

## Traps

- Prawn's public API, listed in `test/contract/prawn-2.5.0.yml`, keeps working. Exceptions are settled in
  `test/contract/decisions.yml`.
- Pages stay identical to Prawn's for valid documents. Anything that would move pixels (ligatures, kerning, PDF/A)
  is opt-in.
- Never reproduce a Prawn bug: a crash, an invalid PDF, or behaviour that contradicts Prawn's own documentation or
  the PDF specification. Each fix is a declared divergence: an entry in `test/divergences.yml` with its proof, a row
  in `docs/compatibility.html`, and a **Fixed** changelog entry at release.
- `Prawn::VERSION` stays `2.5.0`, the API we reproduce. `Gamba::VERSION` is the gem's own.
- Without `corpus/cache`, the oracle, fuzz and determinism tests skip: fetch it before trusting a green run.
- An example listed in `test/oracle_passing.txt` must stay identical to Prawn's. One that becomes identical joins
  the list.
- PDF/A tests use veraPDF when it is installed, and Mustang (`MUSTANG_JAR`, `JAVA`) for Factur-X.
- Gamba refuses to load when the prawn gem is in the same bundle: Prawn only ever runs from `oracle/Gemfile`.

## Rules for all our gems

This section and the next two read the same in super-slim, gamba, crumbly and agentry: change all four together.

- Every maintained Ruby and Rails (https://endoflife.date), nothing older. The oldest sets `required_ruby_version`,
  `TargetRubyVersion` and the Rails floor, and leaves in the release after its end of life.
- CI runs RuboCop and the tests on each maintained Ruby. No macOS job: we test on our Macs.
- `.claude/hooks/rubocop.sh` autocorrects each Ruby file you edit.
- Measure performance without JIT and with YJIT. A Performance cop the numbers contradict is disabled on its line,
  with the reason. A pure performance change pins no internals in tests.
- Test and bench data are anonymized: `alice`, `Post`, `example.com`.
- Everything in the repository is in English (code, comments, commits, pull requests, issues, reviews, replies),
  whatever the language of the conversation.
- No AI attribution in anything people read.

## Pull requests and issues

- `main` takes no direct push. Every change, releases included, goes through a pull request that merges itself
  once CI is green: `gh pr merge --auto --squash`.
- Drafts run no CI. Confident in the change? Open it ready for review, auto-merge on. Not yet? Open a draft, then
  `gh pr ready` when it needs CI.
- Never edit `CHANGELOG.md` in a pull request: they would all conflict. It is written at release time.
- Title: the change as a user sees it (for an issue, the finding), in plain words, under 70 characters.
- Body, no headings: two short paragraphs, the problem then the change (for an issue, what to do); 3 to 5 bullets,
  each opening with a **bold 2–4 word lead-in**; the proof (reproduction, tests, benchmarks) folded in one
  `<details>`. Nothing the diff or CI already says.
- Never hard-wrap a pull request, an issue or a comment: GitHub renders every line break. One line per paragraph
  and per bullet.

## Releases

1. List the pull requests merged since the last tag: `git log --first-parent --oneline <tag>..origin/main`, then
   `gh pr view <n>` for each.
2. Write the release under `## [Unreleased]` in `CHANGELOG.md`, uncommitted: a one-sentence lede, then
   **Breaking**, **New**, **Faster** (measured) and **Fixed**, only those with entries. One entry per change users
   can see, written for them; CI, refactoring, docs and tests get none. No version, date or link: `bin/release`
   adds them.
3. Show it to the user. Then `bin/release patch|minor|major` (try `--dry-run` first) commits it through a pull
   request, waits for the merge and tags it; the tag runs `.github/workflows/release.yml`, which publishes the gem.

RubyGems trusts only that workflow: never `gem push` from a machine, except the very first version of a new gem
name. `bin/release` and `release.yml` are the same in all four gems.
