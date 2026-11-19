# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "open3"
require "stringio"

# Gamba.document, Gamba's own API over a Prawn document, and Prawn::Document#gamba, which opens it inside Prawn code.
class NativeDocumentTest < Minitest::Test
  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")
  BOLD_FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans-Bold.ttf")

  def test_the_block_receives_the_document_and_keeps_its_own_self
    @greeting = "Hello"
    document = Gamba.document { |yielded| yielded.text @greeting }

    assert_instance_of Gamba::Document, document
    assert_equal "Hello", glyphs(document.to_s).map(&:first).join
  end

  def test_an_unknown_document_option_raises_with_the_accepted_ones
    error = assert_raises(ArgumentError) { Gamba.document(page_sise: "A4") }

    assert_equal "unknown option :page_sise: accepted options are #{Gamba::Document::OPTIONS.map(&:inspect).join(", ")}", error.message
  end

  def test_an_unknown_text_attribute_raises_with_the_accepted_ones
    error = assert_raises(ArgumentError) { Gamba.document.text("Hello", colour: "ff0000", sise: 3) }

    assert_match(/\Aunknown options :colour, :sise: accepted options are :font, :size, :weight, :italic, :color, :align, :leading, :widows, :orphans, :keep_with_next, :role, :lang\z/, error.message)
  end

  def test_an_unknown_style_attribute_raises_when_the_style_is_defined
    assert_raises(ArgumentError) { Gamba.document.style(:title, sise: 18) }
  end

  def test_an_undefined_style_raises_with_the_defined_ones
    document = Gamba.document
    document.style :title, size: 18
    error = assert_raises(ArgumentError) { document.text "Hello", style: :titel }

    assert_equal "unknown style :titel: defined styles are :title", error.message
  end

  def test_an_unknown_weight_raises
    assert_raises(ArgumentError) { Gamba.document.text("Hello", weight: :heavy) }
  end

  def test_a_named_style_sets_what_the_call_leaves_out
    document = Gamba.document
    document.style :title, size: 18, weight: :bold
    document.text "A", style: :title
    document.text "B", style: :title, size: 9, italic: true
    document.text "C"

    assert_equal [["A", "Helvetica-Bold", 18.0], ["B", "Helvetica-BoldOblique", 9.0], ["C", "Helvetica", 12.0]], glyphs(document.to_s).map { _1.first(3) }
  end

  def test_the_default_style_applies_to_every_text
    document = Gamba.document
    document.style :default, font: "Courier", size: 10
    document.style :title, size: 18
    document.text "A"
    document.text "B", style: :title

    assert_equal [["A", "Courier", 10.0], ["B", "Courier", 18.0]], glyphs(document.to_s).map { _1.first(3) }
  end

  # Prawn's table sizes its columns in the document's font: the native table sets its own around it.
  def test_a_table_sizes_its_columns_in_its_font_whatever_the_documents
    table = ->(document) { document.stack { |stack| stack.table([{sku: "SKU1", description: "Gadget, deluxe edition"}], columns: {sku: {}, description: {}}, cell: {font: "Courier"}) } }
    in_helvetica = Gamba.document { |document| document.text "Intro" }.tap(&table)
    in_courier = Gamba.document { |document| document.text "Intro" }.tap { |document| document.prawn.font("Courier") }.tap(&table)

    assert_equal glyphs(in_courier.to_s).drop(5), glyphs(in_helvetica.to_s).drop(5)
  end

  def test_a_cell_the_styling_block_sets_in_another_font_is_sized_in_it
    rows = [{sku: "SKU1", description: "Gadget, deluxe edition"}]
    document = Gamba.document { |gamba| gamba.stack(width: 220) { |stack| stack.table(rows, columns: {sku: {}, description: {}}) { |table| table.column(1).font = "Courier" } } }

    # Sized in Helvetica, the narrower, the description wrapped on two lines.
    assert_equal 1, glyphs(document.to_s).select { _1[1] == "Courier" && _1.first != " " }.map(&:last).uniq.size
  end

  # As a text: the style of the Prawn code around the table changes neither what its cells draw nor their size.
  def test_a_table_in_a_bold_or_italic_document_stays_regular
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    words = %w[Gadget deluxe edition with spare parts toolkit and manual]
    pdfs = %i[bold italic].map do |style|
      Prawn::Document.new do
        font "Times-Roman", style: style
        gamba do |document|
          document.register_font "DejaVuSans", normal: FONT, bold: BOLD_FONT
          document.stack(width: 200) { |stack| stack.table([{sku: "SKU1", description: words.join(" ")}], columns: {sku: {}, description: {}}, cell: {font: "DejaVuSans"}) }
        end
      end.render
    end
    regular = Gamba.document do |document|
      document.register_font "DejaVuSans", normal: FONT, bold: BOLD_FONT
      document.stack(width: 200) { |stack| stack.table([{sku: "SKU1", description: words.join(" ")}], columns: {sku: {}, description: {}}, cell: {font: "DejaVuSans"}) }
    end

    assert_equal "SkuDescriptionSKU1#{words.join}", glyphs(regular.to_s).map(&:first).join.delete(" ")
    pdfs.each { |pdf| assert_equal glyphs(regular.to_s), glyphs(pdf) }
  end

  def test_a_table_lays_out_the_same_tagged_or_not
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    table = lambda do |document|
      document.register_font "DejaVuSans", normal: FONT, bold: BOLD_FONT
      document.style :default, font: "DejaVuSans", size: 9
      document.stack { |stack| stack.table([{sku: "SKU1", description: "Gadget, deluxe edition"}], columns: {sku: {title: "SKU"}, description: {}}) }
    end
    plain = Gamba.document(&table)
    tagged = Gamba.document(pdf: :ua, lang: "en", info: {Title: "Table"}, &table)

    assert_equal glyphs(tagged.to_s), glyphs(plain.to_s)
  end

  def test_a_native_call_draws_what_the_prawn_call_draws
    native = Gamba.document(margin: 50) { |document| document.text "Hello", size: 18, color: "ff0000", align: :right, weight: :bold }
    prawn = Prawn::Document.new(margin: 50) { text "Hello", size: 18, color: "ff0000", align: :right, style: :bold }

    assert_equal prawn.render, native.to_s
  end

  def test_lang_is_written_in_the_catalog
    assert_includes uncompressed(Gamba.document(lang: "fr-FR").to_s), "/Lang (fr-FR)"
    assert_includes uncompressed(Prawn::Document.new(lang: "en").render), "/Lang (en)"
    refute_includes uncompressed(Prawn::Document.new.render), "/Lang"
  end

  def test_draw_calls_the_component_with_the_document
    component = ->(document) { document.text "Drawn" }
    document = Gamba.document

    assert_same document, document.draw(component)
    assert_equal "Drawn", glyphs(document.to_s).map(&:first).join
  end

  def test_write_takes_a_path_or_an_io
    document = Gamba.document { |yielded| yielded.text "Hello" }
    io = StringIO.new
    document.write(io)

    Dir.mktmpdir do |directory|
      path = File.join(directory, "hello.pdf")
      document.write(path)

      assert_equal io.string.b, File.binread(path)
    end
    assert io.string.start_with?("%PDF-")
  end

  def test_prawn_is_the_document_underneath
    document = Gamba.document
    document.prawn.text "From Prawn"
    document.text "From Gamba"

    assert_equal "From PrawnFrom Gamba", glyphs(document.to_s).map(&:first).join
  end

  def test_a_gamba_block_in_prawn_code_draws_from_the_cursor_and_leaves_it_below
    bridged = Prawn::Document.new do
      text "Before"
      gamba { |document| document.text "Native", size: 18 }
      text "After"
    end
    plain = Prawn::Document.new do
      text "Before"
      text "Native", size: 18
      text "After"
    end

    assert_equal plain.render, bridged.render
  end

  def test_gamba_blocks_of_one_prawn_document_share_their_styles
    pdf = Prawn::Document.new do
      gamba { |document| document.style :title, size: 18 }
      gamba { |document| document.text "A", style: :title }
    end

    assert_equal [["A", "Helvetica", 18.0]], glyphs(pdf.render).map { _1.first(3) }
  end

  def test_a_registered_font_uses_its_ligatures_and_kerning_in_every_face
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)
    native = Gamba.document do |document|
      document.register_font "DejaVu", normal: FONT, bold: BOLD_FONT
      document.style :default, font: "DejaVu"
      document.text "AVATAR office"
      document.text "AVATAR office", weight: :bold
    end
    prawn = Prawn::Document.new
    prawn.font_families.update("DejaVu" => {normal: FONT, bold: BOLD_FONT})
    prawn.font("DejaVu")
    prawn.text "AVATAR office"
    prawn.text "AVATAR office", style: :bold

    native_lines = glyphs(native.to_s).slice_when { |previous, following| previous.last != following.last }.to_a
    prawn_lines = glyphs(prawn.render).slice_when { |previous, following| previous.last != following.last }.to_a

    assert_equal 2, native_lines.size
    native_lines.zip(prawn_lines).each do |native_line, prawn_line|
      assert_equal "AVATAR office", native_line.map(&:first).join
      assert_operator native_line.last[3], :<, prawn_line.last[3], "kerning and the fi ligature bring the last glyph closer"
    end
  end

  def test_a_font_given_by_its_file_uses_its_ligatures_and_kerning
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)
    native = Gamba.document { |document| document.text "AVATAR office", font: FONT }
    prawn = Prawn::Document.new { font(FONT) { text "AVATAR office" } }

    assert_operator glyphs(native.to_s).last[3], :<, glyphs(prawn.render).last[3]
  end

  def test_a_registered_font_can_turn_its_features_off
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)
    native = Gamba.document do |document|
      document.register_font "DejaVu", normal: FONT, features: []
      document.text "AVATAR office", font: "DejaVu"
    end
    prawn = Prawn::Document.new do
      font_families.update("DejaVu" => {normal: FONT})
      font("DejaVu") { text "AVATAR office" }
    end

    assert_equal glyphs(prawn.render), glyphs(native.to_s)
  end

  private

  def uncompressed(pdf)
    Tempfile.create(["native", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Open3.capture2("qpdf", "--qdf", "--object-streams=disable", file.path, "-").first
    end
  end

  def glyphs(pdf)
    Tempfile.create(["native", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Oracle.text_layout(file.path).flat_map(&:glyphs)
    end
  end
end
