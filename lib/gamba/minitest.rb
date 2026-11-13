# frozen_string_literal: true

require "gamba/testing"

module Gamba
  # require "gamba/minitest": assertions on PDFs, as bytes or a file's path, in every Minitest::Test.
  module Minitest
    def assert_pdf_text(pdf, text, page: nil, at: nil)
      gamba_check { Gamba::Testing.text_failure(pdf, text, page:, at:) }
    end

    def assert_same_pages(expected, actual)
      gamba_check { Gamba::Testing.pages_failure(expected, actual) }
    end

    def assert_valid_pdf(pdf)
      gamba_check { Gamba::Testing.validity_failure(pdf) }
    end

    def assert_pdf_a(pdf, flavour: "3b")
      gamba_check { Gamba::Testing.pdf_a_failure(pdf, flavour:) }
    end

    private

    def gamba_check
      failure = yield
      assert failure.nil?, failure
    rescue Gamba::PdfCheck::ToolMissing => error
      (Gamba::Testing.missing_tools == :skip) ? skip(error.message) : flunk(error.message)
    end
  end
end

Minitest::Test.include(Gamba::Minitest) if defined?(Minitest::Test)
