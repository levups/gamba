# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require_relative "support/oracle"

CORPUS_MISSING_MESSAGE = "corpus/cache is empty: run `bundle exec rake corpus:fetch`"

module Minitest
  class Test
    # veraPDF checks PDF/A and PDF/UA: a missing one skips locally, and fails in CI, which installs it.
    def require_verapdf
      return if system("which verapdf", out: File::NULL)

      ENV["CI"] ? flunk("veraPDF is not installed: CI installs it, see .github/workflows/ci.yml") : skip("veraPDF is not installed (brew install verapdf)")
    end
  end
end
