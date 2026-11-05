# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "timeout"

# Gamba.combine reads PDFs written by others: the pages must come out as they were drawn, whatever the file's
# structure, and a damaged file must fail with an error Gamba names. COMBINE_FUZZ_SEED and COMBINE_FUZZ_CASES choose
# the damaged files.
class CombineTest < Minitest::Test
  LETTER = [612, 792].freeze
  LABEL = [288, 432].freeze
  A4 = [595.28, 841.89].freeze
  FUZZ_SEED = Integer(ENV.fetch("COMBINE_FUZZ_SEED", "20261103"))
  FUZZ_CASES = Integer(ENV.fetch("COMBINE_FUZZ_CASES", "300"))
  QPDF_VARIANTS = {
    "an xref table" => %w[--object-streams=disable],
    "object streams" => %w[--object-streams=generate],
    "40-bit RC4" => %w[--allow-weak-crypto --encrypt "" owner 40 --],
    "128-bit RC4" => %w[--allow-weak-crypto --encrypt "" owner 128 --use-aes=n --],
    "AES-128" => %w[--encrypt "" owner 128 --use-aes=y --],
    "AES-256" => %w[--encrypt "" owner 256 --]
  }.freeze

  def test_without_options_the_pages_follow_one_another_as_they_were
    alice = document("alice")
    bob = document("bob", pages: 2)

    combined = Gamba.combine([alice, bob])

    assert_equal rasterized(alice) + rasterized(bob), rasterized(combined)
  end

  def test_files_qpdf_rewrote_draw_the_same_pages
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    original = document("alice", pages: 2)
    QPDF_VARIANTS.each do |name, arguments|
      variant = qpdf(original, arguments.map { |argument| (argument == '""') ? "" : argument })

      assert_equal rasterized(original), rasterized(Gamba.combine([variant])), "a file with #{name}"
    end
  end

  def test_a_page_size_scales_each_page_from_its_lower_left_corner_keeping_its_proportions
    source = document("alice", page_size: "LETTER")
    scale = [LABEL[0].to_f / LETTER[0], LABEL[1].to_f / LETTER[1]].min.round(4)

    combined = Gamba.combine([source], page_size: LABEL)

    assert_equal [[0, 0, 288, 432]], media_boxes(combined)
    expected = glyphs(source).map { |character, x, y| [character, x * scale, LABEL[1] - (LETTER[1] - y) * scale] }
    assert_glyphs_near expected, glyphs(combined)
  end

  def test_a_page_the_other_way_round_turns_a_quarter_counterclockwise
    combined = Gamba.combine([document("alice", page_size: "LETTER")], page_size: A4, orientation: :landscape)

    assert_equal [[0, 0, 841.89, 595.28]], media_boxes(combined)
    xs, ys = glyphs(combined).map { _1.drop(1) }.transpose
    assert_in_delta xs.min, xs.max, 0.5, "the line runs upward"
    assert_equal ys.sort.reverse, ys
  end

  def test_a_rotated_page_is_drawn_as_viewers_showed_it
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    rotated = qpdf(document("alice", page_size: "LETTER"), %w[--rotate=+90])

    combined = Gamba.combine([rotated], orientation: :landscape)

    assert_equal [[0, 0, 792, 612]], media_boxes(combined)
    assert_glyphs_near glyphs(rotated), glyphs(combined)
  end

  def test_annotations_move_with_their_page
    source = Prawn::Document.new(page_size: "LETTER", margin: 0) do
      text "alice"
      link_annotation([100, 200, 300, 400], A: {Type: :Action, S: :URI, URI: PDF::Core::LiteralString.new("https://example.com")})
    end.render
    scale = (LABEL[0].to_f / LETTER[0]).round(4)

    combined = Gamba.combine([source], page_size: LABEL)

    reader = PDF::Core::Reader.new(combined)
    _, page = reader.pages.first
    rectangle = reader.resolve(reader.resolve(page[:Annots]).first)[:Rect].map(&:to_f)
    [100, 200, 300, 400].zip(rectangle).each { |original, moved| assert_in_delta original * scale, moved, 0.01 }
  end

  def test_an_annotation_two_pages_share_moves_once
    combined = Gamba.combine([two_rotated_pages_sharing_a_stamp], orientation: :landscape)

    reader = PDF::Core::Reader.new(combined)
    rectangles = reader.pages.map { |_, page| reader.resolve(reader.resolve(page[:Annots]).first)[:Rect].map(&:to_f) }
    assert_equal [[10.0, 10.0, 30.0, 110.0]] * 2, rectangles
  end

  def test_annotation_appearances_turn_with_their_page
    source = two_rotated_pages_sharing_a_stamp

    combined = Gamba.combine([source], orientation: :landscape)

    assert_equal rasterized(source), rasterized(combined)
  end

  def test_a_page_size_without_orientation_is_used_as_given
    assert_equal [[0, 0, 432, 288]], media_boxes(Gamba.combine([document("alice")], page_size: [432, 288]))
  end

  def test_names_that_read_alike_once_escaped_differ_stay_apart
    sources = ["[/F#201]", "[/F 1]"].map do |array|
      classic_pdf({3 => PAGE.sub(/>>\z/, "/Mark 6 0 R >>"), 4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET"), 6 => array})
    end

    reader = PDF::Core::Reader.new(Gamba.combine(sources))
    marks = reader.pages.map { |_, page| PDF::Core.serialize(reader.resolve(page[:Mark])) }
    assert_equal ["[/F#201]", "[/F 1]"], marks
  end

  def test_a_batch_of_identical_labels_stores_what_they_share_once
    batch = Gamba.combine([document("alice")] * 10, page_size: LABEL)

    reader = PDF::Core::Reader.new(batch)
    fonts = reader.pages.map { |_, page| reader.resolve(reader.resolve(page[:Resources])[:Font]).values }
    assert_equal 10, fonts.size
    assert_equal 1, fonts.flatten.uniq.size
  end

  def test_an_incremental_update_replaces_what_it_updates
    original = classic_pdf({4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET")})
    updated = append_update(original, {4 => stream("BT /F1 24 Tf 72 700 Td (bob) Tj ET")})

    assert_equal "bob", glyphs(Gamba.combine([updated])).map(&:first).join
  end

  def test_an_encrypted_file_with_object_streams_and_a_wrong_xref_is_rebuilt
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    original = document("alice")
    encrypted = qpdf(original, ["--object-streams=generate", "--encrypt", "", "owner", "256", "--"])
    broken = encrypted.sub(/startxref\s+\d+/) { |line| line.sub(/\d+\z/) { (_1.to_i - 7).to_s } }

    assert_equal rasterized(original), rasterized(Gamba.combine([broken]))
  end

  def test_a_crypt_filter_without_a_top_level_length_is_128_bits
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)

    original = document("alice")
    encrypted = qpdf(original, ["--object-streams=disable", "--allow-weak-crypto", "--encrypt", "", "owner", "128", "--use-aes=n", "--force-V4", "--"])
    without_length = encrypted.sub(%r{/Length 128(?=[^0-9])}n) { " " * _1.bytesize }

    assert_equal rasterized(original), rasterized(Gamba.combine([without_length]))
  end

  def test_offsets_the_xref_table_got_wrong_are_found_by_scanning_the_file
    original = classic_pdf({4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET")})
    shifted = original.sub("%PDF-1.4\n", "%PDF-1.4\n% inserted after the offsets were counted\n")

    assert_equal "alice", glyphs(Gamba.combine([shifted])).map(&:first).join
  end

  def test_literal_strings_names_and_reals_are_written_back_as_they_mean
    text = "(a\\(b\\)c \\101\\
d) Tj"
    source = classic_pdf({4 => stream("BT /F#31 24 Tf 72.25 700.125 Td #{text} ET")}, font_name: "F#31")

    combined = Gamba.combine([source])

    assert_equal "a(b)c Ad", glyphs(combined).map(&:first).join
    assert_equal [72.25], glyphs(combined).first(1).map { _1[1].round(2) }
  end

  def test_an_empty_object_stream_with_a_predictor_reads_as_empty
    empty = "<< /Type /ObjStm /N 0 /First 0 /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 4 >> " \
      "/Length #{Zlib::Deflate.deflate("").bytesize} >>\nstream\n#{Zlib::Deflate.deflate("")}\nendstream"
    source = classic_pdf({4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET"), 6 => empty})

    # Offsets shifted: the reader rebuilds the xref by scanning, and opens every object stream it finds.
    shifted = source.sub("%PDF-1.4\n", "%PDF-1.4\n% inserted after the offsets were counted\n")

    assert_equal "alice", glyphs(Gamba.combine([shifted])).map(&:first).join
  end

  def test_a_file_that_needs_a_password_is_refused_by_name
    locked = Prawn::Document.new { text "alice" }.tap { _1.encrypt_document(user_password: "secret") }.render

    assert_raises(Prawn::Errors::EncryptedPDF) { Gamba.combine([locked]) }
  end

  def test_something_that_is_not_a_pdf_is_refused_by_name
    assert_raises(Prawn::Errors::MalformedPDF) { Gamba.combine(["alice"]) }
  end

  def test_unknown_options_are_refused
    assert_raises(ArgumentError) { Gamba.combine([], orientation: :sideways) }
    assert_raises(ArgumentError) { Gamba.combine([], page_size: "B42") }
  end

  def test_damaged_files_fail_cleanly
    samples = [document("alice", pages: 2), classic_pdf({4 => stream("BT /F1 24 Tf 72 700 Td (bob) Tj ET")})]
    if system("qpdf", "--version", out: File::NULL)
      samples += QPDF_VARIANTS.values.map { |arguments| qpdf(samples.first, arguments.map { |argument| (argument == '""') ? "" : argument }) }
    end
    random = Random.new(FUZZ_SEED)
    failures = []
    FUZZ_CASES.times do |index|
      damaged = corrupt(samples.sample(random:), random)
      Timeout.timeout(10) { Gamba.combine([damaged], page_size: LABEL, orientation: :portrait) }
    rescue Prawn::Errors::MalformedPDF, Prawn::Errors::EncryptedPDF
      nil
    rescue Exception => exception # rubocop:disable Lint/RescueException -- a timeout or any crash is the finding
      failures << "case #{index}: #{exception.class}: #{exception.message[0, 200]}\n  #{exception.backtrace&.first}"
    end

    assert_empty failures, "seed #{FUZZ_SEED}"
  end

  def test_a_decompression_bomb_is_refused_before_it_fills_memory
    zeros = Zlib::Deflate.deflate("\0" * 4_000_000) # 4 KB, 100 times as much once inflated as the file holds
    bombs = {
      "one filter" => ["/FlateDecode", zeros],
      "a chain of filters" => ["[/FlateDecode /FlateDecode]", Zlib::Deflate.deflate(zeros)]
    }
    bombs.each do |name, (filter, data)|
      bomb = "<< /Type /ObjStm /N 0 /First 0 /Filter #{filter} /Length #{data.bytesize} >>\nstream\n#{data}\nendstream"
      source = classic_pdf({4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET"), 6 => bomb})
      # Offsets shifted: the reader rebuilds the xref by scanning, and opens every object stream it finds.
      shifted = source.sub("%PDF-1.4\n", "%PDF-1.4\n% inserted after the offsets were counted\n")

      assert_raises(Prawn::Errors::MalformedPDF, "a bomb behind #{name}") { Gamba.combine([shifted]) }
    end
  end

  def test_predictor_parameters_outside_the_specification_are_refused
    readable = ->(colors, bits) { PDF::Core::Reader.new(packed_catalog_pdf(colors:, bits:)).pages.size }

    assert_equal 1, readable.call(32, 8)
    assert_equal 0, readable.call(33, 8), "33 colours"
    assert_equal 0, readable.call(32, 3), "3 bits per component"
  end

  def test_nesting_deeper_than_any_real_file_is_refused
    deep_array = "[" * 100_000 + "]" * 100_000
    deep_dictionary = "<< /A " * 100_000 + ">>" * 100_000
    [deep_array, deep_dictionary].each do |deep|
      source = classic_pdf({1 => "<< /Type /Catalog /Pages 2 0 R /Deep #{deep} >>", 4 => stream("BT ET")})

      assert_raises(Prawn::Errors::MalformedPDF) { Gamba.combine([source]) }
    end
  end

  def test_stray_delimiters_are_skipped_however_many
    source = classic_pdf({1 => "<< /Type /Catalog /Stray #{")" * 100_000} 0 /Pages 2 0 R >>", 4 => stream("BT ET")})

    assert_equal 1, PDF::Core::Reader.new(Gamba.combine([source])).pages.size
  end

  def test_a_chain_of_lengths_deeper_than_any_real_file_is_refused
    chain = (6..10_005).to_h { |number| [number, "<< /Length #{number + 1} 0 R >>\nstream\nx\nendstream"] }
    source = classic_pdf({4 => "<< /Length 6 0 R >>\nstream\nBT ET\nendstream", 10_006 => "1", **chain})

    assert_raises(Prawn::Errors::MalformedPDF) { Gamba.combine([source]) }
  end

  def test_a_long_list_of_objects_is_copied_whole
    chain = (6..20_005).to_h { |number| [number, "[#{number + 1} 0 R]"] }
    source = classic_pdf({3 => PAGE.sub(">> >>", ">> >> /Next 6 0 R"), 4 => stream("BT ET"), 20_006 => "[]", **chain})
    reader = PDF::Core::Reader.new(Gamba.combine([source]))
    length = 0
    link = reader.pages.first[1][:Next]
    while (list = reader.resolve(link)).is_a?(Array) && !list.empty?
      length += 1
      link = list.first
    end

    assert_equal 20_000, length
  end

  def test_objects_parsed_over_and_over_are_refused
    overlapping = "(" + (1000...3000).map { "#{_1} 0 obj (" }.join
    source = classic_pdf({4 => stream("BT /F1 24 Tf 72 700 Td (alice) Tj ET"), 6 => overlapping})
    shifted = source.sub("%PDF-1.4\n", "%PDF-1.4\n% inserted after the offsets were counted\n")

    assert_raises(Prawn::Errors::MalformedPDF) { Gamba.combine([shifted]) }
  end

  def test_an_object_stream_whose_index_misleads_is_read_in_linear_time
    reader = PDF::Core::Reader.new(packed_catalog_pdf(annotations: 20_000))
    # Linear takes 0.4 s on MRI; quadratic, minutes. The margin is for TruffleRuby before its JIT warms up.
    annotations = Timeout.timeout(10) { reader.resolve(reader.pages.first[1][:Annots]).map { reader.resolve(_1) } }

    assert_equal 20_000, annotations.count { |annotation| annotation.is_a?(Hash) && annotation[:Subtype] }
  end

  def test_a_cross_reference_stream_without_width_is_rebuilt_instead_of_read_forever
    source = packed_catalog_pdf(xref_widths: "[0 0 0] /Size 999999999999")

    assert_equal 1, Timeout.timeout(5) { PDF::Core::Reader.new(Gamba.combine([source])).pages.size }
  end

  def test_loops_in_the_page_tree_and_the_xref_chain_end
    source = classic_pdf({2 => "<< /Type /Pages /Kids [3 0 R 2 0 R] /Count 2 >>", 4 => stream("BT ET")})
    looped = source.sub("/Root 1 0 R", "/Root 1 0 R /Prev #{source[/startxref\s+(\d+)/, 1]}")

    assert_equal 1, Timeout.timeout(5) { PDF::Core::Reader.new(Gamba.combine([looped])).pages.size }
  end

  private

  # Flipped bytes, truncations, and 2 or 4 bytes overwritten with extreme values where a parser may trust them.
  def corrupt(bytes, random)
    bytes = bytes.b.dup
    case random.rand(4)
    when 0 then bytes.byteslice(0, random.rand(bytes.bytesize))
    when 1
      random.rand(1..20).times { bytes.setbyte(random.rand(bytes.bytesize), random.rand(256)) }
      bytes
    when 2
      bytes[random.rand([bytes.bytesize - 4, 1].max), 4] = [[0xFFFFFFFF, 0x7FFFFFFF, 0, 0x10000, random.rand(2**32)].sample(random:)].pack("N")
      bytes
    else
      bytes[random.rand([bytes.bytesize - 2, 1].max), 2] = [[0xFFFF, 0, 0x8000, random.rand(2**16)].sample(random:)].pack("n")
      bytes
    end
  end

  # A PDF 1.5 file whose catalog, and as many annotations as asked, are packed in object stream 6, compressed
  # through a PNG predictor of /Colors colors and bits per component, with a cross-reference stream 7. The xref
  # misplaces each annotation in the object stream, one index too far.
  def packed_catalog_pdf(colors: 1, bits: 8, annotations: 0, xref_widths: "[1 4 2]")
    annotation_numbers = (100...(100 + annotations)).to_a
    packed = {1 => "<< /Type /Catalog /Pages 2 0 R >>"}
    annotation_numbers.each { packed[_1] = "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] >>" }
    page = PAGE.sub("/Contents 4 0 R", "/Contents 4 0 R /Annots [#{annotation_numbers.map { "#{_1} 0 R" }.join(" ")}]")
    plain = {2 => "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", 3 => page, 4 => stream("BT ET"),
             5 => "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}

    body = +""
    header = packed.map { |number, value| "#{number} #{body.bytesize}".tap { body << value << "\n" } }.join(" ") + "\n"
    row_width = (colors * bits * 16 + 7) / 8
    decoded = (header + body).b
    decoded << " " * (-decoded.bytesize % row_width)
    predicted = decoded.bytes.each_slice(row_width).map { [0, *_1].pack("C*") }.join
    data = Zlib::Deflate.deflate(predicted)
    plain[6] = "<< /Type /ObjStm /N #{packed.size} /First #{header.bytesize} /Filter /FlateDecode " \
      "/DecodeParms << /Predictor 12 /Colors #{colors} /BitsPerComponent #{bits} /Columns 16 >> /Length #{data.bytesize} >>\n" \
      "stream\n#{data}\nendstream"

    output = +"%PDF-1.5\n".b
    offsets = plain.to_h { |number, value| [number, output.bytesize].tap { output << "#{number} 0 obj\n#{value}\nendobj\n".b } }
    offsets[7] = output.bytesize
    size = [8, *annotation_numbers.map { _1 + 1 }].max
    rows = (0...size).map do |number|
      if offsets.key?(number) then [1, offsets[number], 0]
      elsif number == 1 then [2, 6, 0]
      elsif number.between?(100, 99 + annotations) then [2, 6, 1 + (number - 100 + 1) % annotations]
      else [0, 0, 0]
      end
    end
    xref = Zlib::Deflate.deflate(rows.map { _1.pack("CNn") }.join)
    output << "7 0 obj\n<< /Type /XRef /Size #{size} /W #{xref_widths} /Root 1 0 R /Filter /FlateDecode /Length #{xref.bytesize} >>\n".b
    output << "stream\n".b << xref << "\nendstream\nendobj\nstartxref\n#{offsets[7]}\n%%EOF\n".b
  end

  def document(name, pages: 1, page_size: "A4")
    Prawn::Document.new(page_size:) do
      pages.times do |index|
        start_new_page unless index.zero?
        text "#{name} #{index + 1}", size: 24
      end
    end.render
  end

  def qpdf(pdf, arguments)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "in.pdf"), pdf)
      assert system("qpdf", *arguments, File.join(directory, "in.pdf"), File.join(directory, "out.pdf")), "qpdf #{arguments.join(" ")}"
      File.binread(File.join(directory, "out.pdf"))
    end
  end

  def rasterized(pdf)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "document.pdf"), pdf)
      Oracle.rasterize(File.join(directory, "document.pdf"), File.join(directory, "page")).map { File.binread(_1) }
    end
  end

  # [character, x, y], y from the top of the page as MuPDF reports it.
  def glyphs(pdf)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "document.pdf"), pdf)
      Oracle.text_layout(File.join(directory, "document.pdf")).flat_map(&:glyphs).map { |character, _, _, x, y| [character, x, y] }
    end
  end

  def assert_glyphs_near(expected, actual)
    assert_equal expected.map(&:first), actual.map(&:first)
    expected.zip(actual).each do |(_, expected_x, expected_y), (character, x, y)|
      assert_in_delta expected_x, x, 0.05, "x of #{character}"
      assert_in_delta expected_y, y, 0.05, "y of #{character}"
    end
  end

  def media_boxes(pdf)
    reader = PDF::Core::Reader.new(pdf)
    reader.pages.map { |_, page| reader.resolve(page[:MediaBox]).map { |value| reader.resolve(value).then { |number| (number.to_f % 1).zero? ? number.to_f.to_i : number.to_f } } }
  end

  PAGE = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"

  # Two 200x400 pages turned a quarter by /Rotate, sharing one /Annots array: a red and green stamp, 100x20.
  def two_rotated_pages_sharing_a_stamp
    page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] /Rotate 90 /Contents 4 0 R /Annots 6 0 R " \
      "/Resources << /Font << /F1 5 0 R >> >> >>"
    stamp = "1 0 0 rg 0 0 100 10 re f 0 1 0 rg 0 10 100 10 re f"
    classic_pdf({
      2 => "<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>", 3 => page, 9 => page,
      4 => stream("BT /F1 24 Tf 20 300 Td (alice) Tj ET"),
      6 => "[7 0 R]",
      7 => "<< /Type /Annot /Subtype /Stamp /Rect [90 10 190 30] /F 4 /AP << /N 8 0 R >> >>",
      8 => "<< /Type /XObject /Subtype /Form /BBox [0 0 100 20] /Length #{stamp.bytesize} >>\nstream\n#{stamp}\nendstream"
    })
  end

  def stream(content)
    "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
  end

  # A PDF 1.4 file with an xref table, as most carriers' label services still write them: catalog 1, pages 2,
  # page 3, its content 4, a standard font 5.
  def classic_pdf(objects, font_name: "F1")
    bodies = {
      1 => "<< /Type /Catalog /Pages 2 0 R >>",
      2 => "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      3 => PAGE.sub("/F1 ", "/#{font_name} "),
      5 => "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    }.merge(objects)
    write_section(+"%PDF-1.4\n", bodies.sort.to_h, size: bodies.keys.max + 1)
  end

  def append_update(pdf, objects)
    previous = pdf.scan(/startxref\s+(\d+)/).last.first
    write_section(pdf.dup, objects, size: 6, previous:)
  end

  def write_section(output, objects, size:, previous: nil)
    offsets = objects.to_h { |number, body| [number, output.bytesize].tap { output << "#{number} 0 obj\n#{body}\nendobj\n" } }
    xref = output.bytesize
    output << "xref\n"
    output << "0 1\n0000000000 65535 f \n" if previous.nil?
    offsets.each { |number, offset| output << "#{number} 1\n#{format("%010d", offset)} 00000 n \n" }
    output << "trailer\n<< /Size #{size} /Root 1 0 R#{" /Prev #{previous}" if previous} >>\nstartxref\n#{xref}\n%%EOF\n"
  end
end
