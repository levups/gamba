# Contributing

Thank you for helping. PrawnX is maintained by Level UP Solutions, two developers who use it in production
every day: small, focused pull requests get reviewed fastest.

## Before you start

- **Bugs**: open an issue with the smallest input that reproduces it. PrawnX replaces Prawn: when the output
  differs from Prawn's, say so and show both.
- **Features**: open an issue first, so we can agree on the scope before you write the code. Being a drop-in
  replacement comes first: a feature that changes what existing code renders or returns stays off by default.
- **Security issues** never go in a public issue: see [SECURITY.md](SECURITY.md).

## Supported Rubies

Every CRuby version the Ruby core team still maintains, down to the gem's floor (`required_ruby_version`), runs
in CI and must pass. A version leaves CI and the floor in the release after its end of life. `ruby-head`, and
JRuby or TruffleRuby where the gem already runs on them, are tested too, but a failure there does not block a
release. A pull request that makes a gem run on JRuby or TruffleRuby without slowing CRuby down is welcome.

## Pull requests

- The repository's README says how to run its tests, its corpus and its benchmarks. CI runs the same.
- A bug fix comes with a test that fails without it; a new behaviour with tests of its own.
- A performance change states its numbers (before, after, Ruby version, with and without YJIT) and proves the
  output did not change.
- Code follows [STYLE.md](STYLE.md) and the RuboCop config (`bundle exec rubocop`).
- One change per pull request, titled for users: the changelog is written from it when releasing. Leave
  `CHANGELOG.md` alone: pull requests editing it conflict with each other.

Using an AI assistant is fine, as long as you have read and understood every line you submit and answer the review
yourself. Say so in the description.

By contributing, you agree that your work is released under the repository's license, and to follow our
[code of conduct](CODE_OF_CONDUCT.md).
