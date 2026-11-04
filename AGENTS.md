# PrawnX

Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 rewritten for speed: same API, same pages pixel for pixel, lighter
files. `lib/prawn*.rb` and `lib/pdf` answer Prawn's requires; the code lives in `lib/prawnx`. By Level UP Solutions,
in the next-gen-gems organization.

## Compatibility

- Every maintained Ruby (endoflife.date), nothing older: the oldest sets `required_ruby_version`,
  `TargetRubyVersion` and the CI floor. Today 3.3, so no bare `it`: blocks name their parameter, `_1` only in a
  one-expression block where a name adds nothing, never nested. A Ruby leaves in the release after its end of life.
- Prawn's public API, listed in `test/contract/prawn-2.5.0.yml`, keeps working; exceptions are settled in
  `test/contract/decisions.yml`.
- Pages stay identical to Prawn's for valid documents: what would move pixels (ligatures, kerning, PDF/A) is opt-in.
  Prawn's bugs (crashes, invalid PDFs) are never reproduced: each one goes in `test/divergences.yml` with its proof,
  and the oracle and the fuzzer accept it from there.
- `Prawn::VERSION` stays `2.5.0` (the API reproduced); `PrawnX::VERSION` is the gem's.

## Commands

```sh
bundle install && BUNDLE_GEMFILE=oracle/Gemfile bundle install # Prawn runs from its own bundle
bundle exec rake corpus:fetch   # Prawn's manual and data into the ignored corpus/cache
bundle exec rake test           # needs mutool, pdftoppm, qpdf: brew install mupdf-tools poppler qpdf
ORACLE_CANDIDATE=prawn FUZZ_CASES=0 bundle exec rake test # Prawn against itself: proves the oracle
FUZZ_SEED=42 FUZZ_CASES=500 bundle exec ruby -Itest test/fuzz_test.rb
INPUT_FUZZ_SEED=42 INPUT_FUZZ_CASES=400 bundle exec ruby -Itest test/input_fuzz_test.rb
bundle exec rubocop             # Standard's rules + every rubocop-performance cop
bundle exec rake bench          # Prawn vs PrawnX on bench/documents, writes docs/benchmarks.json
```

CI (`.github/workflows/ci.yml`) runs RuboCop, then Ruby 3.3, 3.4, 4.0, ruby-head and truffleruby-head, with the
oracle, the suite and both fuzzers on a fresh seed; not on drafts. No macOS job: we run the tests on Macs.

## Traps

- Without `corpus/cache` the oracle, fuzz and determinism tests skip: fetch it before trusting a green run.
- An example of `test/oracle_passing.txt` must stay identical to Prawn's; one that becomes identical joins the list.
- PDF/A tests use veraPDF when installed, and Mustang (`MUSTANG_JAR`, `JAVA`) for Factur-X.
- PrawnX refuses to load when the prawn gem is in the same bundle: Prawn only ever runs from `oracle/Gemfile`.
- A hot-path change is measured with `rake bench`, without JIT and with YJIT. A pure performance change does not
  pin internals in tests.
- `.claude/hooks/rubocop.sh` autocorrects each Ruby file after an edit.

## Code style

Follow `STYLE.md` (naming, method size, comments, dead code): what RuboCop can't settle.

## Changelog and releases

- Never edit `CHANGELOG.md` in a PR: any two PRs adding a line there conflict. The changelog is written when
  releasing, from the PRs merged since the last tag; a PR title says what changes for users.
- To release, read every PR merged since the last tag (`git log --first-parent --oneline <tag>..origin/main`,
  squash merges end in `(#n)`, then `gh pr view n`), and write the release under `## [Unreleased]` without
  committing it: a one-sentence lede, then **Breaking**, **New**, **Faster** (measured, with and without YJIT)
  and **Fixed**, only those with entries. One entry per change users can see, written for them: several PRs may
  make one, CI, refactoring, docs and tests make none. Show it to the user, then `bin/release` commits it with
  the version. No version heading, date or link by hand: `bin/release` writes them.
- `main` takes no direct push, ours included: every change, a release too, goes through a pull request that merges
  itself once the required CI checks are green (`gh pr merge --auto --squash`).
- `bin/release patch|minor|major` cuts a release from a green, up-to-date `main` through such a pull request, then
  tags its merge commit (README, Releasing), and `.github/workflows/release.yml` publishes it. Both are the same in
  every next-gen-gems gem: change them in all four at once.
- RubyGems trusts the Release workflow (trusted publishing): never `gem push` from a machine.
