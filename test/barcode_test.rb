# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# Linear barcodes drawn as vector bars, read back by zbar from the rendered page.
class BarcodeTest < Minitest::Test
  SEED = Integer(ENV.fetch("BARCODE_SEED", "20261113"))
  ZBAR_MISSING = "zbarimg is not installed: apt-get install zbar-tools or brew install zbar"
  ZBAR_NAMES = {code128: "CODE-128", ean13: "EAN-13", ean8: "EAN-8", code39: "CODE-39", itf14: "I2/5"}.freeze

  def test_every_type_reads_back_as_written_check_digits_included
    skip ZBAR_MISSING unless zbar?

    random = Random.new(SEED)
    digits = ->(count) { Array.new(count) { random.rand(10) }.join }
    samples = {
      code128: ["Hello, World!", "1234567890", "A1234567B", "12345", "x\tY", "0", *Array.new(6) { Array.new(1 + random.rand(24)) { (32 + random.rand(95)).chr }.join }],
      ean13: ["4006381333931", "400638133393", *Array.new(4) { digits.call(12) }],
      ean8: ["96385074", "9638507", *Array.new(4) { digits.call(7) }],
      code39: ["CODE 39-$/+%.", "alice", digits.call(10)],
      itf14: ["15400141288763", "1540014128876", *Array.new(4) { digits.call(13) }]
    }
    samples.each do |type, texts|
      texts.each do |text|
        symbol = nil
        pdf = Prawn::Document.new { symbol = barcode text, type:, module_size: 1.5 }.render

        assert_equal "#{ZBAR_NAMES.fetch(type)}:#{symbol.text}", read_back(pdf), "#{type} #{text.inspect}"
      end
    end
  end

  def test_check_digits_are_added_and_checked
    assert_equal "4006381333931", Gamba::Barcodes::Linear.new("400638133393", type: :ean13).text
    assert_equal "96385074", Gamba::Barcodes::Linear.new("9638507", type: :ean8).text
    assert_equal "15400141288763", Gamba::Barcodes::Linear.new("1540014128876", type: :itf14).text
    assert_equal "4006381333932 ends in 2, but its check digit is 1", assert_raises(ArgumentError) { Gamba::Barcodes::Linear.new("4006381333932", type: :ean13) }.message
  end

  def test_sets_switch_where_they_save_room
    assert_equal (6 * 11) + 13, Gamba::Barcodes::Linear.new("12345678", type: :code128).length, "start C, four pairs and the check, then the stop"
    assert_equal Gamba::Barcodes::Linear.new("ab", type: :code128).length, Gamba::Barcodes::Linear.new("12", type: :code128).length + 11
  end

  def test_contents_a_type_cannot_hold_raise
    assert_raises(ArgumentError) { Gamba::Barcodes::Linear.new("café", type: :code128) }
    assert_raises(ArgumentError) { Gamba::Barcodes::Linear.new("", type: :code128) }
    assert_raises(ArgumentError) { Gamba::Barcodes::Linear.new("12345", type: :ean13) }
    assert_raises(ArgumentError) { Gamba::Barcodes::Linear.new("a_b", type: :code39) }
    assert_raises(ArgumentError) { Gamba::Barcodes::Linear.new("1", type: :upc) }
    assert_raises(ArgumentError) { Prawn::Document.new.barcode("1") }
  end

  def test_a_symbol_is_one_fill_its_width_counting_the_quiet_zones
    symbol = nil
    document = Prawn::Document.new { symbol = barcode "4006381333931", type: :ean13, at: [0, 700], width: 113, height: 40 }
    content = uncompressed(document.render)[/stream\n(.*?)endstream/m, 1]
    bars = content.scan(/^([\d.]+) ([\d.]+) ([\d.]+) 40.0 re$/).map { |x, _y, width| [x.to_f, width.to_f] }

    assert_equal 113, symbol.quiet_zones.sum + symbol.length
    assert_equal 1, content.scan(/^f$/).size
    assert_equal 30, bars.size
    assert_equal [36 + 11, 36 + 11 + 95], [bars.first.first, bars.last.sum]
  end

  def test_the_text_goes_under_the_bars_and_the_cursor_below_it
    document = Prawn::Document.new do
      barcode "alice", type: :code128, module_size: 1, height: 30, text: true
    end
    cursor = document.cursor
    glyphs = Tempfile.create(["barcode", ".pdf"]) do |file|
      file.binmode
      file.write(document.render)
      file.flush
      Oracle.text_layout(file.path).first.glyphs
    end

    assert_equal "alice", glyphs.map(&:first).join
    assert_equal [8.0], glyphs.map { _1[2] }.uniq
    assert_in_delta 720 - 30 - 2 - 8, cursor, 0.001
  end

  def test_the_native_api_draws_a_barcode_as_a_box
    skip ZBAR_MISSING unless zbar?

    document = Gamba.document do |yielded|
      yielded.row do |row|
        row.text "Parcel"
        row.barcode "00012345678905", type: :itf14, width: 200, height: 50, align: :right
      end
    end

    assert_equal "I2/5:00012345678905", read_back(document.to_s)
  end

  private

  def zbar?
    system("zbarimg", "--version", out: File::NULL, err: File::NULL)
  end

  def read_back(pdf)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "code.pdf"), pdf)
      Oracle.mutool("draw", "-r", "150", "-o", File.join(directory, "page.png"), File.join(directory, "code.pdf"))
      output, _status = Open3.capture2("zbarimg", "--quiet", "-Si25.enable", "-Scode39.enable", File.join(directory, "page.png"), err: File::NULL)
      output.chomp
    end
  end

  def uncompressed(pdf)
    Tempfile.create(["barcode", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Open3.capture2("qpdf", "--qdf", "--object-streams=disable", file.path, "-").first.b
    end
  end
end
