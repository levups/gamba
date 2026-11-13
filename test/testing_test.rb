# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "fileutils"
require "open3"
require "rbconfig"
require "gamba/minitest"

# The assertions an application's tests get from require "gamba/minitest" or "gamba/rspec": the oracle's checks,
# failing in words that name the page and the glyph, and never passing when a tool is missing.
class TestingTest < Minitest::Test
  INVOICE = Prawn::Document.new do
    text "Invoice INV-2026-0001", size: 18
    start_new_page
    text_box "Total 1 234,00", at: [100, 600]
  end.render.freeze

  def teardown
    Gamba::Testing.missing_tools = :fail
  end

  def test_text_is_found_on_any_page_or_the_one_told_and_where_told
    assert_pdf_text INVOICE, "Invoice INV-2026-0001"
    assert_pdf_text INVOICE, "Total  1 234,00", page: 2
    assert_pdf_text INVOICE, /INV-\d{4}-\d{4}/, page: 1
    assert_pdf_text INVOICE, "Total", page: 2, at: [136, 164.6]
  end

  def test_missing_text_fails_saying_what_the_page_reads
    failure = assert_raises(Minitest::Assertion) { assert_pdf_text INVOICE, "Invoice", page: 2 }
    assert_equal "\"Invoice\" is not on page 2: it reads\nTotal 1 234,00", failure.message

    assert_raises(Minitest::Assertion) { assert_pdf_text INVOICE, "Total", page: 2, at: [36, 164.6] }
    assert_match(/\Athe PDF has 2 pages, not 3/, assert_raises(Minitest::Assertion) { assert_pdf_text INVOICE, "Total", page: 3 }.message)
  end

  def test_pages_are_the_same_or_their_differences_are_named
    assert_same_pages INVOICE, INVOICE.dup
    moved = Prawn::Document.new do
      text "Invoice INV-2026-0001", size: 18
      start_new_page
      text_box "Total 1 234,00", at: [101, 600]
    end.render

    failure = assert_raises(Minitest::Assertion) { assert_same_pages INVOICE, moved }
    assert_match(/\Athe pages differ:\npage 2: glyph 0 is \["T", "Helvetica", 12.0, 137.0, [\d.]+\] instead of \["T", "Helvetica", 12.0, 136.0, [\d.]+\]$/, failure.message)
    assert_includes failure.message, "pixel rows differ at 150 dpi in Poppler"
  end

  def test_validity_is_checked_by_qpdf_and_poppler
    assert_valid_pdf INVOICE
    broken = INVOICE.sub(/startxref\s+\d+/, "startxref\n1")

    assert_match(/\Athe PDF is not valid: /, assert_raises(Minitest::Assertion) { assert_valid_pdf broken }.message)
  end

  def test_paths_work_as_well_as_bytes
    Tempfile.create(["invoice", ".pdf"]) do |file|
      file.binmode
      file.write(INVOICE)
      file.flush

      assert_pdf_text file.path, "Invoice"
      assert_same_pages Pathname.new(file.path), INVOICE
    end
  end

  def test_a_missing_tool_fails_with_its_install_command_or_skips_when_told
    without_tools do
      failure = assert_raises(Minitest::Assertion) { assert_valid_pdf INVOICE }
      assert_equal "qpdf is not installed: brew install qpdf, or apt-get install qpdf", failure.message

      Gamba::Testing.missing_tools = :skip
      assert_raises(Minitest::Skip) { assert_pdf_text INVOICE, "Invoice" }
    end
    assert_raises(ArgumentError) { Gamba::Testing.missing_tools = :pass }
  end

  def test_the_rspec_matchers_pass_fail_and_skip_as_the_assertions_do
    spec = <<~RUBY
      require "prawn"
      require "gamba/rspec"
      PDF = Prawn::Document.new { text "Invoice INV-2026-0001" }.render
      RSpec.describe "an invoice" do
        it("has its number") { expect(PDF).to have_pdf_text("INV-2026-0001", page: 1) }
        it("is valid") { expect(PDF).to be_a_valid_pdf }
        it("has the same pages") { expect(PDF).to have_same_pages_as(PDF.dup) }
        it("lacks a total") { expect(PDF).not_to have_pdf_text("Total") }
        it("fails with what the page reads") { expect(PDF).to have_pdf_text("Total") }
        it("skips when told and qpdf is missing") do
          Gamba::Testing.missing_tools = :skip
          Gamba::PdfCheck.instance_variable_set(:@found, nil)
          ENV["PATH"] = ""
          expect(PDF).to be_a_valid_pdf
        end
      end
    RUBY
    output = Dir.mktmpdir do |directory|
      File.write(File.join(directory, "invoice_spec.rb"), spec)
      `#{RbConfig.ruby} -I#{File.expand_path("../lib", __dir__)} -S rspec #{File.join(directory, "invoice_spec.rb")} 2>&1`
    end

    assert_includes output, "6 examples, 1 failure, 1 pending"
    assert_includes output, "qpdf is not installed: brew install qpdf, or apt-get install qpdf"
    assert_includes output, "\"Total\" is not on the PDF: it reads\n       Invoice INV-2026-0001"
  end

  def test_capture_pdfs_compares_two_directories_with_the_same_checks
    output, status = Dir.mktmpdir do |directory|
      %w[prawn gamba].each { FileUtils.mkdir_p(File.join(directory, _1)) }
      File.binwrite(File.join(directory, "prawn/same.pdf"), INVOICE)
      File.binwrite(File.join(directory, "gamba/same.pdf"), INVOICE)
      File.binwrite(File.join(directory, "prawn/only.pdf"), INVOICE)
      Open3.capture2e(RbConfig.ruby, File.expand_path("../script/capture_pdfs.rb", __dir__), File.join(directory, "prawn"), File.join(directory, "gamba"))
    end

    assert_equal 1, status.exitstatus
    assert_match(%r{\Aonly.pdf: missing from .*/gamba\n2 PDFs, 1 differing\n\z}, output)
  end

  private

  def without_tools
    path = ENV.fetch("PATH")
    ENV["PATH"] = ""
    Gamba::PdfCheck.instance_variable_set(:@found, nil)
    yield
  ensure
    ENV["PATH"] = path
    Gamba::PdfCheck.instance_variable_set(:@found, nil)
  end
end
