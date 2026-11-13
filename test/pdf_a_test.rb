# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tempfile"
require "prawn"

# PDF/A-3b and Factur-X, checked by veraPDF (brew install verapdf) and by Mustang, the Factur-X validator, when
# they are installed: MUSTANG_JAR names Mustang's CLI jar, JAVA the Java it runs on.
class PdfATest < Minitest::Test
  MUSTANG_JAR = ENV.fetch("MUSTANG_JAR", File.expand_path("~/.cache/gamba-tools/Mustang-CLI.jar"))
  JAVA = ENV.fetch("JAVA", ["/opt/homebrew/opt/openjdk/bin/java", "java"].find { system(_1, "-version", err: File::NULL, out: File::NULL) })
  DATA_DIRECTORY = File.join(Oracle::ROOT, "corpus/cache/prawn/data")
  INVOICE_XML = File.read(File.join(__dir__, "fixtures/factur_x_en16931.xml"), encoding: Encoding::UTF_8)

  def setup
    skip CORPUS_MISSING_MESSAGE unless File.directory?(DATA_DIRECTORY)
  end

  def test_a_factur_x_invoice_is_valid_pdf_a_3b
    assert_valid_pdf_a factur_x_invoice
  end

  def test_images_transparency_gradients_and_links_stay_valid_pdf_a_3b
    data = DATA_DIRECTORY
    pdf = Prawn::Document.new(pdf_a: true) do
      font "#{data}/fonts/DejaVuSans.ttf"
      image "#{data}/images/dice.png", width: 150
      transparent(0.5) { fill_circle [300, 500], 40 }
      fill_gradient [0, 300], [200, 300], "ff0000", "0000ff"
      fill_rectangle [0, 300], 200, 50
      formatted_text [{text: "link", link: "https://example.com"}]
    end.render

    assert_valid_pdf_a pdf
  end

  def test_a_factur_x_invoice_passes_mustang_with_french_rules
    skip "Mustang or Java is not installed" unless JAVA && File.exist?(MUSTANG_JAR)

    with_pdf_file(factur_x_invoice) do |path|
      report, = Open3.capture2e(JAVA, "-jar", MUSTANG_JAR, "--action", "validate", "--source", path, "--no-notices")
      summary = report[/Parsed PDF:.*/]
      assert_match(/Parsed PDF:valid XML:valid/, summary, report)
      assert_match(/Errors:\[\]/, summary, report)
    end
  end

  def test_the_invoice_xml_is_attached_as_factur_x_asks
    with_pdf_file(factur_x_invoice) do |path|
      assert_match(/factur-x\.xml/, Open3.capture2("qpdf", "--list-attachments", path).first)
      xml, = Open3.capture2("qpdf", "--show-attachment=factur-x.xml", path)
      assert_equal INVOICE_XML, xml.force_encoding(Encoding::UTF_8)
    end
  end

  def test_the_xmp_metadata_declares_pdf_a_3b_and_the_factur_x_profile
    xmp = factur_x_invoice[%r{<x:xmpmeta.*</x:xmpmeta>}m]

    assert_includes xmp, "<pdfaid:part>3</pdfaid:part>"
    assert_includes xmp, "<pdfaid:conformance>B</pdfaid:conformance>"
    assert_includes xmp, "<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>"
    assert_includes xmp, "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Invoice INV-2026-0001</rdf:li></rdf:Alt></dc:title>"
  end

  def test_standard_fonts_cannot_be_embedded
    error = assert_raises(Prawn::Errors::PdfAViolation) { Prawn::Document.new(pdf_a: true) { text "Helvetica" } }
    assert_match(/TrueType or OpenType/, error.message)
  end

  def test_encryption_is_refused
    assert_raises(Prawn::Errors::PdfAViolation) { Prawn::Document.new(pdf_a: true) { encrypt_document } }
  end

  def test_factur_x_needs_a_pdf_a_document
    assert_raises(Prawn::Errors::PdfAViolation) { Prawn::Document.new { factur_x INVOICE_XML } }
  end

  private

  def factur_x_invoice
    data = DATA_DIRECTORY
    xml = INVOICE_XML
    Prawn::Document.new(pdf_a: true, info: {Title: "Invoice INV-2026-0001", CreationDate: Time.utc(2026, 11, 1)}) do
      font "#{data}/fonts/DejaVuSans.ttf"
      text "Invoice INV-2026-0001"
      table([["Widget", "2", "€2,000.00"]])
      factur_x xml, profile: :en16931
    end.render
  end

  def assert_valid_pdf_a(pdf)
    skip "veraPDF is not installed" unless system("which verapdf", out: File::NULL)

    with_pdf_file(pdf) do |path|
      report, = Open3.capture2e("verapdf", "--flavour", "3b", "--format", "text", path)
      assert report.start_with?("PASS"), report
    end
  end

  def with_pdf_file(pdf)
    Tempfile.create(["pdf_a", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      yield file.path
    end
  end
end
