# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "zlib"

class PngTest < Minitest::Test
  def test_rows_inflate_to_the_size_the_header_announces
    assert_equal "\x00\x7F".b, Prawn::Images::PNG.new(png(Zlib::Deflate.deflate("\x00\x7F"))).img_data
  end

  def test_data_inflating_beyond_the_header_is_refused_without_a_warning
    # Incompressible, so the stream is still unfinished when the first chunk already overflows.
    assert_refused_quietly png(Zlib::Deflate.deflate(Random.new(1).bytes(20_000))), /inflates beyond its 1x1 size/
  end

  def test_a_truncated_stream_is_refused_without_a_warning
    assert_refused_quietly png(Zlib::Deflate.deflate("\x00\x7F").byteslice(0..-5)), /Corrupt PNG data/
  end

  def test_a_bit_depth_the_color_type_does_not_allow_is_refused
    # Indexed with a palette and a transparent entry, at 200 bits per sample instead of 1, 2, 4 or 8.
    data = "\x89PNG\r\n\x1A\n".b + chunk("IHDR", [1, 1, 200, 3, 0, 0, 0].pack("NNCCCCC")) + chunk("PLTE", "\x00\x00\x00") +
      chunk("tRNS", "\x00") + chunk("IDAT", Zlib::Deflate.deflate("\x00" + "\x00" * 25)) + chunk("IEND", "")

    error = assert_raises(Prawn::Errors::UnsupportedImageType) { Prawn::Document.new { image StringIO.new(data) }.render }
    assert_match(/invalid bit depth/, error.message)
  end

  def test_a_width_its_data_never_fills_renders_without_building_a_row_of_that_width
    # Gray and alpha, as wide as the size limit allows: a per-pixel layout would take 2 GB, too long a String for TruffleRuby.
    data = "\x89PNG\r\n\x1A\n".b + chunk("IHDR", [(2**29) - 1, 1, 8, 4, 0, 0, 0].pack("NNCCCCC")) +
      chunk("IDAT", Zlib::Deflate.deflate("\x00\x7F\xFF")) + chunk("IEND", "")

    assert_kind_of String, Prawn::Document.new { image StringIO.new(data), width: 100 }.render
  end

  private

  # A 1x1 grayscale image, 8 bits per sample: one filter byte and one sample per row.
  def png(idat)
    "\x89PNG\r\n\x1A\n".b + chunk("IHDR", [1, 1, 8, 0, 0, 0, 0].pack("NNCCCCC")) + chunk("IDAT", idat) + chunk("IEND", "")
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  def assert_refused_quietly(png, message)
    verbose, $VERBOSE = $VERBOSE, true
    _, warnings = capture_io do
      error = assert_raises(Prawn::Errors::UnsupportedImageType) { Prawn::Images::PNG.new(png).img_data }
      assert_match message, error.message
    end
    assert_empty warnings
  ensure
    $VERBOSE = verbose
  end
end
