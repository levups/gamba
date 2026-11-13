# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# DataMatrix ECC 200 symbols drawn as vector rectangles, read back by libdmtx from the rendered page.
class DataMatrixTest < Minitest::Test
  SEED = Integer(ENV.fetch("DATA_MATRIX_SEED", "20261113"))
  DMTX_MISSING = "dmtxread is not installed: apt-get install dmtx-utils or brew install dmtx-utils"

  def test_every_size_reads_back_as_written
    skip DMTX_MISSING unless dmtx?

    random = Random.new(SEED)
    texts = ["A", "0123456789", "https://example.com/parcel/0001", "Café", *[10, 40, 100, 250, 500, 900, 1500].map { |length| Array.new(length) { (32 + random.rand(95)).chr }.join }]
    sizes = texts.map do |text|
      symbol = nil
      pdf = Prawn::Document.new { symbol = data_matrix text, module_size: 2 }.render

      assert_equal text.b, read_back(pdf), "#{text.bytesize} bytes in #{symbol.size}x#{symbol.size}"
      symbol.size
    end

    assert_equal [10, 144], sizes.minmax
    assert_operator sizes.uniq.size, :>=, 9, "sizes with one and several data regions and interleaved blocks"
  end

  def test_the_smallest_square_size_that_holds_the_data_is_chosen
    assert_equal 10, Gamba::Barcodes::DataMatrix.new("123456").size, "three digit pairs fill a 10x10"
    assert_equal 12, Gamba::Barcodes::DataMatrix.new("1234567").size
    assert_equal 144, Gamba::Barcodes::DataMatrix.new("1" * 3116).size
    assert_equal "3117 bytes take 1559 codewords: a DataMatrix holds 1558 at most", assert_raises(ArgumentError) { Gamba::Barcodes::DataMatrix.new("1" * 3117) }.message
  end

  def test_a_symbol_is_one_fill_its_size_counting_a_one_module_quiet_zone
    symbol = nil
    document = Prawn::Document.new { symbol = data_matrix "alice", at: [0, 700], size: 56 }
    content = uncompressed(document.render)[/stream\n(.*?)endstream/m, 1]
    rectangles = content.scan(/^([\d.]+) ([\d.]+) ([\d.]+) 4.0 re$/)

    assert_equal 12, symbol.size
    assert_equal 1, content.scan(/^f$/).size
    assert_equal 36 + 4, rectangles.map { _1[0].to_f }.min
    assert_equal 36 + 700 - 4 - (12 * 4), rectangles.map { _1[1].to_f }.min, "the solid bottom edge"
  end

  def test_the_native_api_draws_a_data_matrix_as_a_box
    skip DMTX_MISSING unless dmtx?

    document = Gamba.document do |yielded|
      yielded.row do |row|
        row.text "Parcel"
        row.data_matrix "alice@example.com", size: 80, align: :center
      end
    end

    assert_equal "alice@example.com", read_back(document.to_s)
    assert_raises(ArgumentError) { Gamba.document.data_matrix("alice", level: :h) }
  end

  private

  def dmtx?
    system("dmtxread", "--version", out: File::NULL, err: File::NULL)
  end

  def read_back(pdf)
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "code.pdf"), pdf)
      Oracle.mutool("draw", "-r", "150", "-o", File.join(directory, "page.png"), File.join(directory, "code.pdf"))
      output, _status = Open3.capture2("dmtxread", "--newline", "--stop-after=1", File.join(directory, "page.png"), err: File::NULL, binmode: true)
      output.chomp
    end
  end

  def uncompressed(pdf)
    Tempfile.create(["data_matrix", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Open3.capture2("qpdf", "--qdf", "--object-streams=disable", file.path, "-").first.b
    end
  end
end
