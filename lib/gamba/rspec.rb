# frozen_string_literal: true

require "gamba/testing"

module Gamba
  # require "gamba/rspec": matchers on PDFs, as bytes or a file's path, in every example group.
  module RSpec
    # A matcher whose check returns nil when it passes, or the failure's words.
    class Matcher
      def initialize(description, &check)
        @description = description
        @check = check
      end

      def matches?(pdf)
        @failure = @check.call(pdf)
        @failure.nil?
      rescue Gamba::PdfCheck::ToolMissing => error
        raise if Gamba::Testing.missing_tools == :fail

        ::RSpec::Core::Pending.mark_skipped!(::RSpec.current_example, error.message) if defined?(::RSpec::Core::Pending)
        raise ::RSpec::Core::Pending::SkipDeclaredInExample, error.message
      end

      def does_not_match?(pdf)
        !matches?(pdf)
      end

      def failure_message
        @failure
      end

      def failure_message_when_negated
        "expected the PDF not to #{@description}"
      end

      attr_reader :description
    end

    def have_pdf_text(text, page: nil, at: nil)
      Matcher.new("have the text #{text.inspect}") { |pdf| Gamba::Testing.text_failure(pdf, text, page:, at:) }
    end

    def have_same_pages_as(expected)
      Matcher.new("have the same pages") { |actual| Gamba::Testing.pages_failure(expected, actual) }
    end

    def be_a_valid_pdf
      Matcher.new("be a valid PDF") { |pdf| Gamba::Testing.validity_failure(pdf) }
    end

    def be_pdf_a(flavour: "3b")
      Matcher.new("be PDF/A-#{flavour}") { |pdf| Gamba::Testing.pdf_a_failure(pdf, flavour:) }
    end
  end
end

RSpec.configure { |config| config.include(Gamba::RSpec) } if defined?(RSpec.configure)
