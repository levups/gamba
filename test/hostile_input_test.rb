# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "timeout"
require "zlib"

# Documents built from what users send (fonts, images, markup, PDFs to combine, metadata) must render or fail
# with an error Gamba names, quickly: never hang, never write an invalid PDF, never leak what they encrypt.
class HostileInputTest < Minitest::Test
  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")
  CFF_FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/Bodoni-Book.otf")
  SECONDS = 10

  def test_a_composite_glyph_containing_itself_ends_the_component_walk
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    file = Gamba::TrueType::File.new(File.binread(FONT))
    composites = {5 => 5, 6 => 7, 7 => 6}.transform_values { [-1, 0, 0, 0, 0].pack("s>5") + [0x0002, _1, 0, 0].pack("n2c2") }
    file.define_singleton_method(:glyph_data) { |glyph| composites.fetch(glyph, "".b) }
    subset = Gamba::TrueType::Subset.new(file)
    [5, 6].each { subset.glyph_for(_1) }

    Timeout.timeout(SECONDS) { subset.add_components([5, 6]) }
    assert_equal [0, 5, 6, 7], subset.original_glyphs
  end

  def test_overlapping_format_4_segments_are_refused
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    segments = 80
    subtable = [4, 0, 0, segments * 2, 0, 0, 0].pack("n7") + ([0xFFFF] * segments).pack("n*") + "\0\0".b +
      ([0] * segments).pack("n*") + ([1] * segments).pack("n*") + ([0] * segments).pack("n*")
    subtable[2, 2] = [subtable.bytesize].pack("n")
    error = assert_raises(Gamba::TrueType::Error) { Gamba::TrueType::File.new(font_with_table("cmap", [0, 1, 3, 1, 12].pack("n4N") + subtable)) }
    assert_match(/cmap maps/, error.message)
  end

  def test_overlapping_format_12_groups_are_refused
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    cmap = [0, 1, 3, 10, 12].pack("n4N") + [12, 0, 0, 0, 8].pack("n2N3") + ([0, 0x10FFFF, 1].pack("N3") * 8)
    assert_raises(Gamba::TrueType::Error) { Gamba::TrueType::File.new(font_with_table("cmap", cmap)) }
  end

  def test_a_name_table_with_records_past_its_end_leaves_the_font_usable
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    [[0, 0xFFFF, 6].pack("n3"), [0, 1, 18, 3, 1, 0x409, 6].pack("n7")].each do |name|
      Tempfile.create(["name", ".ttf"]) do |file|
        file.binmode
        file.write(font_with_table("name", name))
        file.close
        assert pdf_valid?(Prawn::Document.new {
          font file.path
          text "alice"
        }.render)
      end
    end
  end

  def test_fonts_are_embedded_by_their_outlines_whatever_their_extension
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT) && File.exist?(CFF_FONT)

    {FONT => ".otf", CFF_FONT => ".ttf"}.each do |source, extension|
      Tempfile.create(["outlines", extension]) do |file|
        file.binmode
        file.write(File.binread(source))
        file.close
        assert pdf_valid?(Prawn::Document.new {
          font file.path
          text "alice"
        }.render), "#{File.basename(source)} as #{extension}"
      end
    end
  end

  def test_the_parsed_font_cache_keeps_a_bounded_number_of_files
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    Dir.mktmpdir do |directory|
      (Gamba::TrueType::File::MAXIMUM_CACHED_FILES + 5).times do |index|
        path = File.join(directory, "alice-#{index}.ttf")
        FileUtils.cp(FONT, path)
        Gamba::TrueType::File.open(path)
      end
    end
    assert_operator Gamba::TrueType::File::FILES_BY_KEY.size, :<=, Gamba::TrueType::File::MAXIMUM_CACHED_FILES
  end

  def test_truncated_or_empty_jpegs_raise_a_format_error
    sof = "\xFF\xD8\xFF\xC0\x00\x11\x08".b
    ["\xFF\xD8\xFF\xE0".b, "\xFF\xD8\xFF\xC0\x00\x11\x08\x00".b, sof + [0, 10, 3].pack("nnC"), sof + [10, 0, 3].pack("nnC"),
      "\xFF\xD8\xFF\xC0\x00\x11\x00".b + [10, 10, 3].pack("nnC")].each do |jpeg|
      assert_raises(Prawn::Images::JPG::FormatError, jpeg.inspect) { Prawn::Document.new { image StringIO.new(jpeg) }.render }
    end
  end

  def test_a_png_without_a_complete_row_still_writes_its_image_as_a_stream
    [0, 6].each do |color_type|
      png = png(Zlib::Deflate.deflate(""), color_type:)
      assert pdf_valid?(Prawn::Document.new { image StringIO.new(png) }.render), "color type #{color_type}"
    end
  end

  def test_a_short_transparency_chunk_is_ignored
    png = png(Zlib::Deflate.deflate("\x00\x01\x02\x03".b), color_type: 2, extra: chunk("tRNS", "\x00\x01"))
    refute_includes uncompressed(Prawn::Document.new { image StringIO.new(png) }.render), "/Mask"
  end

  def test_an_indexed_png_needs_a_palette_of_1_to_256_colors
    [+"", "\x00" * 771].each do |palette|
      png = png(Zlib::Deflate.deflate("\x00\x00".b), color_type: 3, extra: chunk("PLTE", palette))
      assert_raises(Prawn::Errors::UnsupportedImageType) { Prawn::Document.new { image StringIO.new(png) }.render }
    end
  end

  def test_packed_palette_indices_take_the_opacity_of_their_color
    # Two rows of 10 pixels at 2 bits, colors 0, 1, 2, 3 in turn; color 1 is transparent and color 2 half opaque.
    rows = ["\x00\x1B\x1B\x10".b, "\x00\xE4\xE4\xE0".b]
    png = png(Zlib::Deflate.deflate(rows.join), width: 10, height: 2, color_type: 3, bits: 2,
      extra: chunk("PLTE", "\x00" * 12) + chunk("tRNS", "\xFF\x00\x80".b))
    image = Prawn::Images::PNG.new(png).build_pdf_object(Prawn::Document.new)
    opacity = [0xFF, 0x00, 0x80, 0xFF]
    expected = [[0, 1, 2, 3, 0, 1, 2, 3, 0, 1], [3, 2, 1, 0, 3, 2, 1, 0, 3, 2]].flatten.map { opacity[_1] }.pack("C*")
    assert_equal expected, image.data[:SMask].stream
  end

  def test_unclosed_tags_tokenize_in_linear_time
    Timeout.timeout(SECONDS) { Prawn::Text::Formatted::Parser.format("<a" * 200_000) }
  end

  def test_tokens_are_the_ones_the_parser_regex_finds
    pieces = ["<", ">", "a", "<a", "<b>", "</b>", "<link href='x'>", "</link>", "\n", "<color rgb='ff0000'>", "x>y", "é", "&lt;"]
    random = Random.new(42)
    2_000.times do
      string = Array.new(random.rand(12)) { pieces.sample(random:) }.join
      assert_equal string.scan(Prawn::Text::Formatted::Parser::PARSER_REGEX), Prawn::Text::Formatted::Parser.tokens(string), string
    end
  end

  def test_a_style_opened_again_and_again_stays_one_style
    fragments = Prawn::Text::Formatted::Parser.format("<b>alice" * 1_000)
    assert_equal [[:bold]], fragments.map { _1[:styles] }.uniq
  end

  def test_an_encrypted_identifier_tells_nothing_without_the_password
    invoice = lambda do |amount, password|
      Prawn::Document.new { text "Amount due: #{amount} EUR" }.tap { _1.encrypt_document(user_password: password) }.render
    end
    victim = invoice.call(4217, "alice's secret")[%r{/ID\s*\[\s*<(\h+)>}, 1]

    refute_equal victim, invoice.call(4217, "")[%r{/ID\s*\[\s*<(\h+)>}, 1]
    assert_equal victim, invoice.call(4217, "alice's secret")[%r{/ID\s*\[\s*<(\h+)>}, 1]
  end

  def test_pdf_a_metadata_refuses_what_xml_cannot_hold
    ["alice\u0001", "caf\xE9".b].each do |title|
      assert_raises(Prawn::Errors::PdfAViolation, title.inspect) { Prawn::Document.new(pdf_a: true, info: {Title: title}).render }
    end
  end

  def test_combined_pages_never_write_infinite_numbers
    box = "[0 0 #{"9" * 400}.0 100]"
    [{}, {page_size: [100, 100]}, {orientation: :landscape}].each do |options|
      combined = Gamba.combine([one_page_pdf(box)], **options)
      assert pdf_valid?(combined), options.inspect
      refute_match(/\b(?:NaN|Inf(?:inity)?)\b/, uncompressed(combined), options.inspect)
    end
  end

  private

  def png(idat, width: 1, height: 1, color_type: 0, bits: 8, extra: "".b)
    "\x89PNG\r\n\x1A\n".b + chunk("IHDR", [width, height, bits, color_type, 0, 0, 0].pack("NNCCCCC")) + extra +
      chunk("IDAT", idat) + chunk("IEND", "")
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data.b + [Zlib.crc32(type + data.b)].pack("N")
  end

  # DejaVu Sans with one table replaced: the directory is rewritten to point at the new bytes, appended last.
  def font_with_table(tag, bytes)
    font = File.binread(FONT)
    record = (0...font.unpack1("@4 n")).map { |index| 12 + (index * 16) }.find { |offset| font.byteslice(offset, 4) == tag }
    font[record + 8, 8] = [font.bytesize, bytes.bytesize].pack("N2")
    font + bytes
  end

  def one_page_pdf(media_box)
    objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox #{media_box} /Contents 4 0 R >>", "<< /Length 8 >>\nstream\n0 0 m S \nendstream"]
    output = +"%PDF-1.7\n"
    offsets = objects.each_with_index.map do |body, index|
      output.bytesize.tap { output << "#{index + 1} 0 obj\n#{body}\nendobj\n" }
    end
    start = output.bytesize
    output << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { format("%010d 00000 n \n", _1) }.join
    output << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{start}\n%%EOF\n"
  end

  def uncompressed(pdf)
    Tempfile.create(["hostile", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.close
      output, status = Open3.capture2("qpdf", "--qdf", "--object-streams=disable", file.path, "-")
      assert status.success?
      output.b
    end
  end

  def pdf_valid?(pdf)
    Tempfile.create(["hostile", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.close
      _output, status = Open3.capture2e("qpdf", "--check", file.path)
      _draw, errors, = Open3.capture3("mutool", "draw", "-q", "-o", File::NULL, file.path)
      status.success? && !errors.match?(/error/i)
    end
  end
end
