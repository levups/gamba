# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# QR codes drawn as vector rectangles, read back by zbar from the rendered page: what is encoded must be what a
# phone reads.
class QRCodeTest < Minitest::Test
  SEED = Integer(ENV.fetch("QR_CODE_SEED", "20261113"))
  ZBAR_MISSING = "zbarimg is not installed: apt-get install zbar-tools or brew install zbar"

  def test_every_mode_and_level_reads_back_as_written
    skip ZBAR_MISSING unless zbar?

    random = Random.new(SEED)
    texts = ["https://example.com/pay/INV-2026-0001", "0123456789" * 3, "HELLO WORLD $%*+-./:", "Café €, 日本 — alice@example.com", ""]
    texts += [1, 20, 120, 400].map { |length| Array.new(length) { (32 + random.rand(95)).chr }.join }
    Gamba::Barcodes::QRCode::LEVELS.each do |level|
      texts.each do |text|
        assert_equal text, read_back(Prawn::Document.new { qr_code text, level:, module_size: 2 }.render), "#{text.inspect} at level #{level}"
      end
    end
  end

  def test_the_smallest_version_that_holds_the_text_is_chosen_up_to_the_standard_capacities
    capacities = {["1" * 41, :l] => 1, ["1" * 42, :l] => 2, ["a" * 14, :m] => 1, ["a" * 15, :m] => 2, ["1" * 7089, :l] => 40, ["A" * 4296, :l] => 40, ["a" * 2953, :l] => 40, ["a" * 1273, :h] => 40}

    capacities.each { |(text, level), version| assert_equal version, Gamba::Barcodes::QRCode.new(text, level:).version, "#{text.size} characters at level #{level}" }
    assert_match(/\A1274 bytes do not fit a QR code at level :h: /, assert_raises(ArgumentError) { Gamba::Barcodes::QRCode.new("a" * 1274, level: :h) }.message)
  end

  def test_large_versions_read_back
    skip ZBAR_MISSING unless zbar?

    text = Array.new(1500) { |index| (65 + (index % 26)).chr }.join.downcase
    pdf = Prawn::Document.new { qr_code text, level: :l, size: 500 }.render

    assert_equal 28, Gamba::Barcodes::QRCode.new(text, level: :l).version
    assert_equal text, read_back(pdf)
  end

  def test_a_symbol_is_one_path_and_one_fill_its_size_counting_the_quiet_zone
    symbol = nil
    document = Prawn::Document.new { symbol = qr_code "alice", at: [100, 700], size: 116 }
    content = uncompressed(document.render)[/stream\n(.*?)endstream/m, 1]
    rectangles = content.scan(/^([\d.]+) ([\d.]+) ([\d.]+) 4.0 re$/)
    lefts = rectangles.map { _1[0].to_f }
    tops = rectangles.map { _1[1].to_f + 4 }

    assert_equal 21, symbol.size
    assert_equal 1, content.scan(/^f$/).size
    assert_equal [36 + 100 + 16, 36 + 700 - 16], [lefts.min, tops.max]
    assert_equal 36 + 100 + 16 + 84, rectangles.map { _1[0].to_f + _1[2].to_f }.max
  end

  def test_without_at_a_code_flows_as_an_image_does
    document = Prawn::Document.new do
      text "Pay"
      qr_code "alice", module_size: 3, position: :right, quiet_zone: false
    end

    assert_in_delta 720 - document.height_of("Pay") - 63, document.cursor, 0.001
    assert_includes uncompressed(document.render), "549.0 "
  end

  def test_wrong_options_raise
    assert_raises(ArgumentError) { Prawn::Document.new.qr_code("alice", level: :x) }
    assert_raises(ArgumentError) { Gamba.document.qr_code("alice", sise: 10) }
    assert_raises(ArgumentError) { Gamba.document.qr_code("alice", align: :middle) }
  end

  def test_the_native_api_draws_a_code_as_a_box
    skip ZBAR_MISSING unless zbar?

    cursor = nil
    document = Gamba.document do |yielded|
      yielded.row do |row|
        row.text "Scan to pay"
        row.qr_code "https://example.com/pay/INV-2026-0001", size: 100, align: :right
      end
      cursor = yielded.prawn.cursor
      yielded.text "after"
    end

    assert_equal "https://example.com/pay/INV-2026-0001", read_back(document.to_s)
    assert_in_delta 720 - 100, cursor, 0.001
  end

  private

  def zbar?
    system("zbarimg", "--version", out: File::NULL, err: File::NULL)
  end

  # What zbar reads on the first page drawn at 150 dpi.
  def read_back(pdf)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "code.pdf"), pdf)
      Oracle.mutool("draw", "-r", "150", "-o", File.join(directory, "page.png"), File.join(directory, "code.pdf"))
      output, _status = Open3.capture2("zbarimg", "--quiet", "--raw", "-Sbinary", File.join(directory, "page.png"), err: File::NULL)
      output.chomp.force_encoding(Encoding::UTF_8)
    end
  end

  def uncompressed(pdf)
    Tempfile.create(["qr", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Open3.capture2("qpdf", "--qdf", "--object-streams=disable", file.path, "-").first.b
    end
  end
end
