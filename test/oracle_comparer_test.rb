# frozen_string_literal: true

require_relative "test_helper"

# The oracle is only worth its silence if it speaks up: each document below differs from the base one in a single
# way, and the comparison has to name that way.
class OracleComparerTest < Minitest::Test
  DOCUMENT_BY_NAME = {
    "base" => 'text "Hello, world"',
    "same" => 'text "Hello, world"',
    "moved" => 'move_down 0.5; text "Hello, world"',
    "retyped" => 'text "Hello, wordl"',
    "recolored" => 'fill_color "ff0000"; text "Hello, world"',
    "longer" => 'text "Hello, world"; start_new_page',
    "heavier" => 'text "Hello, world"; save_graphics_state; restore_graphics_state'
  }.freeze

  def self.rendering
    @rendering ||= Dir.mktmpdir do |directory|
      paths = DOCUMENT_BY_NAME.map { |name, body| File.join(directory, "#{name}.rb").tap { File.write(_1, body) } }
      Oracle.render("prawn", paths, File.join(Oracle::ROOT, "tmp/oracle_comparer"))
    end
  end

  def test_identical_documents_show_no_difference
    assert_empty differences_with("same")
  end

  def test_moved_text_shows_in_positions
    assert_includes differences_with("moved"),
      'page 1: glyph 0 is ["H", "Helvetica", 12.0, 36.0, 45.12] instead of ["H", "Helvetica", 12.0, 36.0, 44.62]'
  end

  def test_changed_text_shows_in_glyphs
    assert_match(/glyph 10 is \["d"/, differences_with("retyped").first)
  end

  def test_changed_color_shows_in_pixels
    assert_includes differences_with("recolored"), "page 1: 23 pixel rows differ at 150 dpi"
  end

  def test_extra_page_shows_in_page_count
    assert_includes differences_with("longer"), "2 pages instead of 1"
  end

  def test_invisible_content_shows_in_weight
    assert_equal 1, differences_with("heavier").size
    assert_match(/\Aheavier: \d+ bytes instead of \d+\z/, differences_with("heavier").first)
  end

  def test_errors_must_match_their_class
    assert_equal ["raises ArgumentError instead of Prawn::Errors::CannotFit"],
      Oracle.error_class_differences("Prawn::Errors::CannotFit: …", "ArgumentError: …")
  end

  # Stream data, compressed or not, can hold the bytes of a subset tag by chance: only font names get the neutral tag.
  def test_neutral_subset_tags_leave_stream_data_alone
    Dir.mktmpdir do |directory|
      pdf = File.join(directory, "tagged.pdf")
      content = "% /AbCdEf+ is stream data\n"
      File.binwrite(pdf, <<~PDF)
        %PDF-1.4
        1 0 obj <</Type/Catalog/Pages 2 0 R>> endobj
        2 0 obj <</Type/Pages/Kids[3 0 R]/Count 1>> endobj
        3 0 obj <</Type/Page/Parent 2 0 R/MediaBox[0 0 10 10]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>> endobj
        4 0 obj <</Length #{content.bytesize}>> stream
        #{content}endstream endobj
        5 0 obj <</Type/Font/Subtype/Type1/BaseFont/AbCdEf+Helvetica/FontDescriptor 6 0 R>> endobj
        6 0 obj <</Type/FontDescriptor/FontName/GhIjKl+Helvetica>> endobj
        trailer <</Root 1 0 R/Size 7>>
        %%EOF
      PDF
      neutral = File.binread(Oracle.with_neutral_subset_tags(pdf, File.join(directory, "neutral.pdf")))

      assert_includes neutral, content
      assert_equal ["/BaseFont /AAAAAA+Helvetica", "/FontName /AAAAAA+Helvetica"], neutral.scan(%r{/\w+ /\w{6}\+Helvetica})
    end
  end

  private

  def differences_with(name)
    rendering = self.class.rendering
    Oracle.pdf_differences(File.join(rendering.directory, "base.pdf"), File.join(rendering.directory, "#{name}.pdf"))
  end
end
