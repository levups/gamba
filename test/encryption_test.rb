# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "open3"
require "tempfile"

class EncryptionTest < Minitest::Test
  ALGORITHMS = %i[rc4_40 aes_256].freeze

  def test_the_catalog_of_an_encrypted_document_is_outside_the_object_stream
    skip "qpdf is not installed" unless qpdf?

    ALGORITHMS.each do |algorithm|
      with_file(encrypted_document(algorithm:)) do |path|
        assert_match(/^#{root_identifier(path)}\/0: uncompressed/, qpdf("--show-xref", path), algorithm)
      end
    end
  end

  def test_the_strings_of_an_encrypted_catalog_read_back_in_clear
    skip "qpdf is not installed" unless qpdf?

    ALGORITHMS.each do |algorithm|
      with_file(encrypted_document(algorithm:)) do |path|
        assert_includes qpdf("--show-object=#{root_identifier(path)}", path), "/Lang (en-US)", algorithm
      end
    end
  end

  def test_the_strings_of_an_encrypted_stream_dictionary_read_back_in_clear
    skip "qpdf is not installed" unless qpdf?

    ALGORITHMS.each do |algorithm|
      pdf = Prawn::Document.new
      piece = {Private: PDF::Core::LiteralString.new("alice"), Name: "Café", Date: Time.utc(2026, 11, 28, 9, 30)}
      form = pdf.ref!({Type: :XObject, Subtype: :Form, BBox: [0, 0, 10, 10], PieceInfo: piece}, "0 0 m")
      pdf.encrypt_document(user_password: "", owner_password: "owner", algorithm:)

      with_file(pdf.render) do |path|
        dictionary = qpdf("--show-object=#{form.identifier}", path)

        assert_includes dictionary, "/Private (alice)", algorithm
        assert_includes dictionary, "/Name <feff00430061006600e9>", algorithm
        assert_includes dictionary, "/Date (D:20261128093000+00'00')", algorithm
      end
    end
  end

  # veraPDF tries to decrypt a direct dictionary of the cross-reference stream, and warns on each of its strings.
  def test_the_encryption_dictionary_is_an_object_of_its_own_in_clear
    skip "qpdf is not installed" unless qpdf?

    ALGORITHMS.each do |algorithm|
      with_file(encrypted_document(algorithm:)) do |path|
        identifier = qpdf("--show-object=trailer", path)[%r{/Encrypt (\d+) 0 R}, 1]

        assert identifier, algorithm
        assert_match(/^#{identifier}\/0: uncompressed/, qpdf("--show-xref", path), algorithm)
        assert_includes qpdf("--show-object=#{identifier}", path), "/Filter /Standard", algorithm
      end
    end
  end

  # 2026-11, macOS 27.2: Preview, Safari and Quick Look read PDFs through Core Graphics, which sees no page in an
  # encrypted file whose catalog sits in an object stream.
  def test_core_graphics_opens_an_encrypted_document
    skip "Core Graphics runs on macOS only" unless RUBY_PLATFORM.include?("darwin")

    ALGORITHMS.each do |algorithm|
      with_file(encrypted_document(algorithm:)) do |path|
        assert_equal "612.000", Open3.capture2("sips", "-g", "pixelWidth", path).first[/pixelWidth: (\S+)/, 1], algorithm
      end
    end
  end

  def test_aes_256_writes_revision_6_with_its_permissions
    skip "qpdf is not installed" unless qpdf?

    with_file(encrypted_document(algorithm: :aes_256)) do |path|
      encryption = qpdf("--show-encryption", path)

      assert_includes encryption, "R = 6"
      assert_includes encryption, "extract for any purpose: not allowed"
      assert_includes encryption, "print high resolution: allowed"
      assert_includes qpdf("--show-object=#{root_identifier(path)}", path), "/ExtensionLevel 8"
    end
  end

  def test_aes_256_refuses_assembly_and_forms_with_modification_and_annotations_as_rc4_does
    skip "qpdf is not installed" unless qpdf?

    ALGORITHMS.each do |algorithm|
      pdf = Prawn::Document.new
      pdf.encrypt_document(owner_password: "owner", permissions: {modify_contents: false, modify_annotations: false}, algorithm:)

      with_file(pdf.render) do |path|
        encryption = qpdf("--show-encryption", path)

        assert_includes encryption, "modify document assembly: not allowed", algorithm
        assert_includes encryption, "modify forms: not allowed", algorithm
      end
    end
  end

  def test_an_aes_256_password_of_bytes_that_are_no_text_is_hashed_as_bytes
    skip "qpdf is not installed" unless qpdf?

    [Encoding::US_ASCII, Encoding::UTF_8].each do |encoding|
      pdf = Prawn::Document.new
      pdf.text "Hello, alice"
      pdf.encrypt_document(user_password: (+"\xFFab").force_encoding(encoding), owner_password: "owner", algorithm: :aes_256)

      with_file(pdf.render) { |path| assert system("qpdf", "--check", "--password=owner", path, out: File::NULL), encoding }
    end
  end

  def test_an_aes_256_user_password_opens_the_document_as_the_owner_password_does
    skip "qpdf is not installed" unless qpdf?
    skip "Poppler is not installed" unless system("pdftotext", "-v", out: File::NULL, err: File::NULL)

    pdf = Prawn::Document.new
    pdf.text "Hello, alice"
    pdf.encrypt_document(user_password: "alice", owner_password: "owner", algorithm: :aes_256)

    with_file(pdf.render) do |path|
      refute system("qpdf", "--check", path, out: File::NULL, err: File::NULL)
      refute system("qpdf", "--check", "--password=bob", path, out: File::NULL, err: File::NULL)
      {"-upw" => "alice", "-opw" => "owner"}.each do |option, password|
        assert_includes Open3.capture2("pdftotext", "-q", option, password, path, "-").first, "Hello, alice", password
      end
    end
  end

  def test_gamba_reads_back_what_it_encrypted_with_aes_256
    combined = Gamba.combine([encrypted_document(algorithm: :aes_256)])

    assert_equal [["Hello, alice"]], Gamba::PdfCheck.text_lines(combined)
  end

  # Salts and keys derived from the passwords would let anyone test a guess against the public salts with one HMAC,
  # bypassing algorithm 2.B: they are drawn at random, so two renders differ.
  def test_aes_256_draws_its_key_and_salts_at_random
    first, second = Array.new(2) { encrypted_document(algorithm: :aes_256) }

    %w[U O UE OE].each { |entry| refute_equal first[%r{/#{entry} <(\h+)>}, 1], second[%r{/#{entry} <(\h+)>}, 1], entry }
    assert_equal Gamba::PdfCheck.text_lines(Gamba.combine([first])), Gamba::PdfCheck.text_lines(Gamba.combine([second]))
  end

  def test_an_unknown_algorithm_raises
    assert_raises(ArgumentError) { Prawn::Document.new.encrypt_document(algorithm: :aes_128) }
  end

  private

  def encrypted_document(algorithm:)
    pdf = Prawn::Document.new(lang: "en-US")
    pdf.text "Hello, alice"
    pdf.encrypt_document(user_password: "", owner_password: "owner", permissions: {copy_contents: false}, algorithm:)
    pdf.render
  end

  def root_identifier(path)
    qpdf("--show-object=trailer", path)[%r{/Root (\d+) 0 R}, 1]
  end

  def qpdf?
    system("qpdf", "--version", out: File::NULL)
  end

  def with_file(bytes)
    Tempfile.create(["encrypted", ".pdf"]) do |file|
      file.binmode
      file.write(bytes)
      file.close
      yield file.path
    end
  end

  # qpdf's output as bytes: a trailer's /ID holds any, which Ruby 4.1 refuses to match a pattern against as UTF-8.
  def qpdf(*arguments)
    Open3.capture2("qpdf", *arguments).first.b
  end
end
