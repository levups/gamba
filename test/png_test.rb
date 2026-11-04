# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "zlib"

class PngTest < Minitest::Test
  GRAYSCALE_WITH_ALPHA = 4

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

  def test_a_wide_image_too_large_for_its_header_is_refused_before_its_rows_are_split
    wide = png(Zlib::Deflate.deflate("\x00\x7F\xFF"), width: 2**27, height: 16, color_type: GRAYSCALE_WITH_ALPHA)

    assert_allocates_less_than(16 * 1024 * 1024) do
      error = assert_raises(Prawn::Errors::UnsupportedImageType) { Prawn::Document.new { image StringIO.new(wide), width: 100 }.render }
      assert_match(/too large/, error.message)
    end
  end

  def test_a_wide_image_without_a_full_row_renders_without_splitting_its_pixels
    wide = png(Zlib::Deflate.deflate("\x00\x7F\xFF"), width: 2**24, height: 1, color_type: GRAYSCALE_WITH_ALPHA)

    assert_allocates_less_than(16 * 1024 * 1024) do
      assert Prawn::Document.new { image StringIO.new(wide), width: 100 }.render.start_with?("%PDF")
    end
  end

  private

  # 8 bits per sample, grayscale unless told otherwise: one filter byte, then the samples of each row.
  def png(idat, width: 1, height: 1, color_type: 0)
    "\x89PNG\r\n\x1A\n".b + chunk("IHDR", [width, height, 8, color_type, 0, 0, 0].pack("NNCCCCC")) + chunk("IDAT", idat) +
      chunk("IEND", "")
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  # Measured where Ruby counts it (CRuby); elsewhere the error the block expects is what catches a layout too long.
  def assert_allocates_less_than(bytes)
    GC.disable
    before = GC.stat[:malloc_increase_bytes]
    yield
    assert_operator GC.stat[:malloc_increase_bytes] - before, :<, bytes if before
  ensure
    GC.enable
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
