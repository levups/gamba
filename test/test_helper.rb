# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require_relative "support/oracle"

CORPUS_MISSING_MESSAGE = "corpus/cache is empty: run `bundle exec rake corpus:fetch`"
