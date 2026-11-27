# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "open3"
require "tempfile"

class EncryptionTest < Minitest::Test
  def test_the_catalog_of_an_encrypted_document_is_outside_the_object_stream
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    with_file(encrypted_document) do |path|
      root_identifier = qpdf("--show-object=trailer", path)[%r{/Root (\d+) 0 R}, 1]

      assert_match(/^#{root_identifier}\/0: uncompressed/, qpdf("--show-xref", path))
    end
  end

  def test_the_strings_of_an_encrypted_catalog_read_back_in_clear
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    with_file(encrypted_document) do |path|
      root_identifier = qpdf("--show-object=trailer", path)[%r{/Root (\d+) 0 R}, 1]

      assert_includes qpdf("--show-object=#{root_identifier}", path), "/Lang (en-US)"
    end
  end

  def test_the_strings_of_an_encrypted_stream_dictionary_read_back_in_clear
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    pdf = Prawn::Document.new
    form = pdf.ref!({Type: :XObject, Subtype: :Form, BBox: [0, 0, 10, 10], PieceInfo: {Private: PDF::Core::LiteralString.new("alice")}}, "0 0 m")
    pdf.encrypt_document(user_password: "", owner_password: "owner")

    with_file(pdf.render) do |path|
      assert_includes qpdf("--show-object=#{form.identifier}", path), "/Private (alice)"
    end
  end

  # 2026-11, macOS 27.2: Preview, Safari and Quick Look read PDFs through Core Graphics, which sees no page in an
  # encrypted file whose catalog sits in an object stream.
  def test_core_graphics_opens_an_encrypted_document
    skip "Core Graphics runs on macOS only" unless RUBY_PLATFORM.include?("darwin")

    with_file(encrypted_document) do |path|
      assert_equal "612.000", Open3.capture2("sips", "-g", "pixelWidth", path).first[/pixelWidth: (\S+)/, 1]
    end
  end

  private

  def encrypted_document
    pdf = Prawn::Document.new(lang: "en-US")
    pdf.text "Hello, alice"
    pdf.encrypt_document(user_password: "", owner_password: "owner", permissions: {copy_contents: false})
    pdf.render
  end

  def with_file(bytes)
    Tempfile.create(["encrypted", ".pdf"]) do |file|
      file.binmode
      file.write(bytes)
      file.close
      yield file.path
    end
  end

  def qpdf(*arguments)
    Open3.capture2("qpdf", *arguments).first
  end
end
