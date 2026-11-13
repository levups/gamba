# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"
require "stringio"

# A page of another PDF drawn like an image, or under every page: what a viewer shows of it, written once.
class PdfPageTest < Minitest::Test
  A4 = [595.28, 841.89].freeze
  FONTS = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts")

  def test_a_page_drawn_at_its_size_from_the_corner_gives_the_pixels_of_the_page_alone
    source = letterhead
    drawn = Prawn::Document.new(page_size: "A4", margin: 0) { pdf_page source, at: [0, A4[1]] }.render

    assert_same_pixels source, drawn
  end

  def test_a_rotated_or_cropped_page_appears_as_a_viewer_shows_it
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    rotated = qpdf(letterhead, %w[--rotate=+90])
    assert_same_pixels rotated, Prawn::Document.new(page_size: A4.reverse, margin: 0) { pdf_page rotated, at: [0, A4[0]] }.render

    # Poppler draws a page's media box: the page as shown is the same one with its media box cut to the crop box,
    # whole pixels wide at the oracle's resolution so that no edge is antialiased.
    content = {4 => stream("0 0 1 rg 0 0 612 792 re f BT /F1 24 Tf 72 700 Td (alice) Tj ET")}
    cropped = classic_pdf("4 0 R", content, page: "/CropBox [50 650 338 746] /Rotate 270")
    shown = classic_pdf("4 0 R", content, page: "/Rotate 270", media_box: "50 650 338 746")
    assert_same_pixels shown, Prawn::Document.new(page_size: [96, 288], margin: 0) { pdf_page cropped, at: [0, 288] }.render
  end

  def test_a_page_is_placed_and_sized_as_an_image_is
    source = letterhead
    info = nil
    document = Prawn::Document.new do
      info = pdf_page source, width: 297.64, position: :center
    end

    assert_equal [595.28, 841.89, 297.64, 420.945], [info.width, info.height, info.scaled_width, info.scaled_height]
    assert_in_delta 720 - 420.945, document.cursor, 0.001
    assert_includes uncompressed(document.render), "0.5 0.0 0.0 0.5 157.18 335.055 cm"
  end

  def test_a_page_used_on_every_page_is_written_once_and_pages_of_a_file_share_their_resources
    source = letterhead(pages: 2)
    many = Prawn::Document.new(background_pdf: source) do
      49.times { start_new_page }
      pdf_page source, page: 2, width: 100
    end.render
    objects = uncompressed(many)

    assert_equal 2, objects.scan("/Subtype /Form").size
    assert_equal 1, objects.scan("/BaseFont /Helvetica").size
  end

  def test_the_document_background_is_under_every_page_unless_a_page_names_another_or_none
    source = letterhead(pages: 2)
    document = Prawn::Document.new(background_pdf: source, background_pdf_page: 2) do
      text "first"
      start_new_page(background_pdf: false)
      text "second"
      start_new_page(background_pdf: StringIO.new(source))
      start_new_page
    end

    assert_equal [["Page 2"], [], ["Page 1"], ["Page 2"]], text_lines(document.render).map { _1 - %w[first second] }
  end

  def test_several_content_streams_are_joined_wherever_they_were_divided
    divided = classic_pdf("[4 0 R 6 0 R]", {4 => stream("BT /F1 24 Tf 72 700"), 6 => stream("Td (alice) Tj ET")})
    whole = classic_pdf("4 0 R", {4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET")})

    assert_same_pixels whole, Prawn::Document.new(page_size: "LETTER", margin: 0) { pdf_page divided, at: [0, 792] }.render
  end

  def test_sources_that_are_not_a_page_of_a_readable_pdf_raise
    source = letterhead

    assert_equal "page is 2: this PDF has pages 1 to 1", assert_raises(ArgumentError) { Prawn::Document.new.pdf_page(source, page: 2) }.message
    assert_raises(ArgumentError) { Prawn::Document.new.pdf_page(source, page: "1") }
    assert_raises(ArgumentError) { Prawn::Document.new.pdf_page("missing.pdf") }
    assert_raises(Prawn::Errors::MalformedPDF) { Prawn::Document.new.pdf_page(StringIO.new("not a PDF")) }
    if system("qpdf", "--version", out: File::NULL)
      assert_raises(Prawn::Errors::EncryptedPDF) { Prawn::Document.new.pdf_page(qpdf(source, %w[--encrypt alice owner 256 --])) }
    end
  end

  def test_under_pdf_a_a_page_whose_fonts_are_not_embedded_raises
    error = assert_raises(Prawn::Errors::PdfAViolation) { Prawn::Document.new(pdf_a: true).pdf_page(letterhead) }
    assert_equal "PDF/A embeds every font: the page uses Helvetica without its font file", error.message

    skip CORPUS_MISSING_MESSAGE unless File.directory?(FONTS)

    embedded = Prawn::Document.new do
      font "#{FONTS}/DejaVuSans.ttf"
      text "Example SAS"
    end.render
    assert_kind_of Gamba::ImportedPage, Prawn::Document.new(pdf_a: true).pdf_page(embedded)
  end

  def test_the_native_api_takes_a_background_and_draws_a_page_as_a_box
    source = letterhead(pages: 2)
    document = Gamba.document(background_pdf: source) do |yielded|
      yielded.row do |row|
        row.pdf_page source, page: 2, width: 100
        row.text "beside"
      end
      yielded.text "after"
    end
    first_page = text_lines(document.to_s).first

    assert_equal ["Page 1", "Page 2", "beside", "after"], first_page
  end

  private

  # An A4 letterhead in Helvetica, compressed as Prawn writes it, its pages named.
  def letterhead(pages: 1)
    Prawn::Document.new(page_size: "A4", margin: 0, compress: true) do
      pages.times do |index|
        start_new_page unless index.zero?
        fill_color "1f4e79"
        fill_rectangle [0, A4[1]], A4[0], 80
        fill_color "ffffff"
        text_box "Page #{index + 1}", at: [40, A4[1] - 25], size: 24
      end
    end.render
  end

  def assert_same_pixels(expected, actual)
    Dir.mktmpdir do |directory|
      paths = {expected:, actual:}.to_h { |name, pdf| [name, File.join(directory, "#{name}.pdf").tap { File.binwrite(_1, pdf) }] }

      assert_nil Oracle.invalidity(paths[:actual])
      assert_empty Oracle.rendered_pixel_differences(paths[:expected], paths[:actual])
    end
  end

  # The words of each page, by line, top to bottom.
  def text_lines(pdf)
    with_file(pdf) do |path|
      Oracle.text_layout(path).map do |page|
        page.glyphs.group_by(&:last).sort.map { |_y, glyphs| glyphs.map(&:first).join }
      end
    end
  end

  def uncompressed(pdf)
    with_file(pdf) { |path| Open3.capture2("qpdf", "--qdf", "--object-streams=disable", path, "-").first.b }
  end

  def qpdf(pdf, arguments)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "in.pdf"), pdf)
      assert system("qpdf", *arguments, File.join(directory, "in.pdf"), File.join(directory, "out.pdf")), "qpdf #{arguments.join(" ")}"
      File.binread(File.join(directory, "out.pdf"))
    end
  end

  def with_file(pdf)
    Tempfile.create(["pdf_page", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      yield file.path
    end
  end

  def stream(content)
    "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
  end

  # A PDF 1.4 file with an xref table: catalog 1, pages 2, a page 3 in Helvetica (5), its contents.
  def classic_pdf(contents, objects, page: "", media_box: "0 0 612 792")
    bodies = {
      1 => "<< /Type /Catalog /Pages 2 0 R >>",
      2 => "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      3 => "<< /Type /Page /Parent 2 0 R /MediaBox [#{media_box}] #{page} /Contents #{contents} /Resources << /Font << /F1 5 0 R >> >> >>",
      5 => "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    }.merge(objects).sort.to_h
    output = +"%PDF-1.4\n"
    offsets = bodies.to_h { |number, body| [number, output.bytesize].tap { output << "#{number} 0 obj\n#{body}\nendobj\n" } }
    xref = output.bytesize
    output << "xref\n0 #{bodies.keys.max + 1}\n0000000000 65535 f \n"
    (1..bodies.keys.max).each { |number| output << (offsets[number] ? "#{format("%010d", offsets[number])} 00000 n \n" : "0000000000 65535 f \n") }
    output << "trailer\n<< /Size #{bodies.keys.max + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end
end
