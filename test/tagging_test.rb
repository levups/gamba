# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pdf_objects"
require "prawn"

# Tagged PDF, PDF/UA-1 and PDF/A-3a: a structure tree read back with qpdf, checked by veraPDF when installed
# (brew install verapdf), and pages identical to those of the same document untagged.
class TaggingTest < Minitest::Test
  DATA_DIRECTORY = File.join(Oracle::ROOT, "corpus/cache/prawn/data")
  BENCH_DIRECTORY = File.join(Oracle::ROOT, "bench/native")
  TAGGED = {pdf: :ua, pdf_a: :a, lang: "en", info: {Title: "Quarterly report"}}.freeze

  def setup
    skip CORPUS_MISSING_MESSAGE unless File.directory?(DATA_DIRECTORY)
  end

  def test_a_tagged_document_passes_pdf_ua_1_and_pdf_a_3a_alone_and_together
    [{pdf: :ua}, {pdf_a: :a}, {pdf: :ua, pdf_a: :a}].each do |levels|
      pdf = report(**TAGGED.slice(:lang, :info), **levels)

      assert_valid "ua1", pdf if levels[:pdf]
      assert_valid "3a", pdf if levels[:pdf_a]
    end
  end

  def test_the_bench_examples_pass_once_tagged
    %w[invoice report catalog].each do |name|
      body = File.read(File.join(BENCH_DIRECTORY, "#{name}.rb"))
      pdf = Gamba.document(**TAGGED) { |document| eval(body, binding, name) }.to_s # rubocop:disable Security/Eval

      assert_valid "ua1", pdf
      assert_valid "3a", pdf
    end
  end

  def test_the_structure_follows_the_boxes_and_reads_in_their_order
    tree = structure(report(**TAGGED))

    assert_equal "Document", tree[:type]
    assert_equal %w[H1 H2 P L P Figure Table P], tree[:kids].map { _1[:type] }
    list = tree[:kids][3]
    assert_equal [%w[LI LBody], %w[LI LBody]], list[:kids].map { |item| [item[:type], *item[:kids].map { _1[:type] }] }
    assert_equal "u:Two dice", tree[:kids][5][:attributes]["/Alt"]
    assert_equal "u:fr", tree[:kids].last[:attributes]["/Lang"]
  end

  def test_a_paragraph_across_a_page_break_stays_one_paragraph
    long = structure(report(**TAGGED))[:kids][2]

    assert_equal [1, 2], long[:content].map(&:first).uniq
  end

  def test_a_table_across_pages_stays_one_table_with_its_header_once
    tables = []
    walk(structure(report(**TAGGED))) { tables << _1 if _1[:type] == "Table" }
    assert_equal 1, tables.size
    table = tables.first

    assert_equal 81, table[:kids].size
    assert_equal %w[TH TH], table[:kids].first[:kids].map { _1[:type] }
    assert_equal({"/O" => "/Table", "/Scope" => "/Column"}, table[:kids].first[:kids].first[:attributes]["/A"])
    assert(table[:kids].drop(1).all? { |row| row[:kids].map { _1[:type] } == %w[TD TD] })
    assert_operator table[:kids].flat_map { |row| row[:kids].flat_map { _1[:content].map(&:first) } }.uniq.size, :>, 1
  end

  def test_marked_content_is_balanced_on_each_page_and_mapped_back_to_its_elements
    reader = PdfObjects.new(report(**TAGGED))

    assert_nil reader.marked_content_problem
    assert_equal reader.pages.size, reader.parent_tree.size
  end

  def test_headers_footers_backgrounds_and_borders_are_artifacts
    reader = PdfObjects.new(report(**TAGGED))
    second = reader.content(reader.pages[1])

    assert_includes second, "/Artifact <</Type /Pagination /Subtype /Header>> BDC"
    assert_includes second, "/Artifact BMC"
    # The repeated header of the table and the decorated stack's background are drawn inside artifacts only.
    second.scan(%r{/Artifact BMC\n(.*?)EMC}m).flatten.each { |artifact| refute_match(/MCID/, artifact) }
  end

  # PDF/A's output intent changes how a viewer renders colours: each tagged document is compared with its untagged
  # level of PDF/A, none or 3b.
  def test_tagging_moves_no_pixel
    untagged = TAGGED.slice(:lang, :info)
    [[{pdf: :ua}, {}], [{pdf: :ua, pdf_a: :a}, {pdf_a: true}]].each do |tagged, plain|
      expected = pixels(report(**untagged, **plain))
      actual = pixels(report(**untagged, **tagged))

      assert_equal expected.size, actual.size, tagged.inspect
      assert expected == actual, "#{tagged.inspect} moves pixels"
    end
  end

  def test_an_untagged_document_is_written_as_before
    plain = Gamba.document { |document| document.text "Hello" }.to_s
    with_attributes = Gamba.document { |document| document.text "Hello", lang: "en" }.to_s

    assert_equal plain, with_attributes
    refute_includes plain, "StructTreeRoot"
  end

  def test_the_catalog_and_the_metadata_say_what_the_document_is
    reader = PdfObjects.new(report(**TAGGED))
    catalog = reader.catalog

    assert_equal({"/Marked" => true}, catalog["/MarkInfo"])
    assert_equal "u:en", catalog["/Lang"]
    assert reader.value(catalog["/ViewerPreferences"])["/DisplayDocTitle"]
    metadata = reader.stream(catalog["/Metadata"])
    assert_includes metadata, "<pdfaid:conformance>A</pdfaid:conformance>"
    assert_includes metadata, "<pdfuaid:part>1</pdfuaid:part>"
    assert_includes metadata, "<pdfaSchema:prefix>pdfuaid</pdfaSchema:prefix>"
  end

  def test_what_breaks_the_rules_raises_where_it_is_written
    assert_raises_with(Prawn::Errors::PdfUaViolation, /lang: "en"/) { Gamba.document(pdf: :ua, info: {Title: "Report"}) }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /Title/) { Gamba.document(pdf: :ua, lang: "en") }
    [" ", "\u3000", "\u200B", "\uFEFF\u2060", false, :Report, "\xFF".b, (+"Report \xFF").force_encoding(Encoding::UTF_8)].each do |title|
      assert_raises_with(Prawn::Errors::PdfUaViolation, /Title/) { Gamba.document(pdf: :ua, lang: "en", info: {Title: title}) }
    end
    assert Gamba.document(pdf: :ua, lang: "fr", info: {Title: "Résumé".encode(Encoding::ISO_8859_1)}).prawn.tagged?
    assert_raises_with(ArgumentError, /alt is "\u200B"/) { Gamba.document.image "#{DATA_DIRECTORY}/images/dice.png", alt: "\u200B" }
    assert Gamba.document.image("#{DATA_DIRECTORY}/images/dice.png", alt: "\xC3\xA9".b) # UTF-8 bytes, as File.binread reads them
    assert_raises_with(ArgumentError, /:ua is the only/) { Prawn::Document.new(pdf: :ub) }
    assert_raises_with(ArgumentError, /:a for PDF\/A-3a/) { Prawn::Document.new(pdf_a: :u) }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /standard PDF font/) { Gamba.document(**TAGGED.except(:pdf_a)) { _1.text "Hello" } }

    document = dejavu(Gamba.document(**TAGGED))
    assert_raises_with(Prawn::Errors::PdfUaViolation, /alternative text/) { document.image "#{DATA_DIRECTORY}/images/dice.png" }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /outside any tagged box/) { document.prawn.text "Untagged" }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /an h2 comes first/) { document.text "Details", role: :h2 }
    document.text "Report", role: :h1
    assert_raises_with(Prawn::Errors::PdfUaViolation, /an h3 follows an h1/) { document.text "Details", role: :h3 }
    assert_raises_with(Prawn::Errors::PdfAViolation, /PDF\/A-3a tags all content/) do
      dejavu(Gamba.document(pdf_a: :a, lang: "en")).prawn.stroke_horizontal_rule
    end
  end

  def test_a_decorative_image_needs_no_alternative_text
    document = dejavu(Gamba.document(**TAGGED))
    document.image "#{DATA_DIRECTORY}/images/dice.png", role: :artifact
    document.text "Hello"

    assert_valid "ua1", document.to_s
  end

  # A box that moves to the next page before drawing leaves nothing on the page it leaves: no empty sequence, and
  # no decoration around nothing.
  def test_a_decorated_stack_moving_to_the_next_page_leaves_its_page_as_untagged
    pdfs = [{pdf: :ua}, {}].map do |levels|
      document = dejavu(Gamba.document(lang: "en", info: {Title: "Report"}, **levels))
      # Two of the paragraph's three lines fit: leaving one widow, it moves whole.
      document.prawn.move_down(document.prawn.cursor - 36)
      document.stack(background: "dddddd", border_width: 1, padding: 2) { |stack| stack.text "word " * 36 }
      document.to_s
    end
    reader = PdfObjects.new(pdfs.first)

    assert_equal 2, reader.pages.size
    assert_nil reader.marked_content_problem
    refute_match(/\bre\b|BDC|BMC/, reader.content(reader.pages.first))
    assert_equal pixels(pdfs.last), pixels(pdfs.first)
  end

  def test_tables_in_a_figure_and_in_a_cell_are_tagged_validly
    document = dejavu(Gamba.document(**TAGGED))
    document.stack(role: :figure, alt: "Totals by customer") { |figure| figure.table([{name: "alice", total: "$1.00"}]) }
    document.table([{name: "alice", detail: [%w[a b], %w[c d]]}])
    pdf = document.to_s

    assert_nil PdfObjects.new(pdf).marked_content_problem
    assert_valid "ua1", pdf
    assert_valid "3a", pdf
  end

  def test_the_default_style_font_is_found_when_first_used_and_keeps_waiting_boxes_waiting
    document = Gamba.document(pdf_a: true)
    document.style :default, font: "DejaVu"
    document.register_font "DejaVu", normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"
    document.table([{name: "alice"}])

    # Helvetica, Prawn's default, would raise PdfAViolation: the table is measured and drawn in DejaVu Sans.
    assert document.to_s.start_with?("%PDF")
    kept = Gamba.document { |plain| plain.text "Heading", keep_with_next: true }
    kept.style :default, size: 9
    assert kept.instance_variable_get(:@kept), "a style placed the box waiting for the next one"
  end

  def test_lists_imported_pages_annotations_and_attribute_values_are_checked
    document = dejavu(Gamba.document(**TAGGED.except(:pdf_a)))
    assert_raises_with(Prawn::Errors::PdfUaViolation, /list item in a list/) { document.text "Alone", role: :list_item }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /only list items in a list/) do
      document.stack(role: :list) { |list| list.text "Not an item" }
    end
    helvetica = Prawn::Document.new { text "Letterhead" }.render
    assert_raises_with(Prawn::Errors::PdfUaViolation, /PDF\/UA embeds every font/) { document.pdf_page(helvetica, alt: "Letterhead") }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /outside any tagged box/) { document.prawn.make_cell("x").draw }
    assert_raises_with(Prawn::Errors::PdfUaViolation, /annotations and links/) { document.prawn.link_annotation([0, 0, 10, 10], A: {S: :URI}) }
    assert_raises_with(ArgumentError, /alt is " "/) { document.image "#{DATA_DIRECTORY}/images/dice.png", alt: " " }
    assert_raises_with(ArgumentError, /language tag/) { Gamba.document.text "Bonjour", lang: :fr }
    assert_raises_with(ArgumentError, /language tag/) { Gamba.document(**TAGGED, lang: "en_US") }
    tagged_page = document.to_s
    assert_raises_with(Prawn::Errors::PdfUaViolation, /marked content of its own/) do
      dejavu(Gamba.document(**TAGGED)).pdf_page(tagged_page, alt: "A tagged page")
    end
    # Operators written against what surrounds them, as LibreOffice does after a dictionary.
    ["/P<</MCID 0>>BDC\nEMC", "/P<</MCID 0>>BDC[(a)]TJ EMC", "/Artifact BMC/GS1 gs EMC"].each do |marks|
      compact = Gamba.document.tap { _1.prawn.add_content(marks) }.to_s
      assert_raises_with(Prawn::Errors::PdfUaViolation, /marked content of its own/) do
        dejavu(Gamba.document(**TAGGED)).pdf_page(compact, alt: "A tagged page")
      end
    end
    assert_raises_with(Prawn::Errors::PdfUaViolation, /PDF\/UA metadata/) { Gamba.document(**TAGGED, info: {Title: "A\u0001B"}).to_s }
    refute Prawn::Document.new(pdf: false).tagged?
  end

  # A decoration within an artifact is moved beneath what the artifact holds on each page: it is an artifact too.
  def test_a_decorated_stack_within_an_artifact_stays_an_artifact
    document = dejavu(Gamba.document(**TAGGED))
    document.stack(role: :artifact) do |artifact|
      artifact.text "Draft"
      artifact.stack(border_width: 1) { |stack| stack.text "word " * 900 }
    end
    pdf = document.to_s

    assert_nil PdfObjects.new(pdf).marked_content_problem
    assert_valid "ua1", pdf
  end

  private

  def report(**options)
    document = dejavu(Gamba.document(**options))
    document.header { |stack, page| stack.text "Quarterly report, page #{page.number} of #{page.total}" }
    document.text "Quarterly report", role: :h1
    document.text "Introduction", role: :h2
    document.text "A quarterly report gathers sales figures from every region. " * 120
    document.stack(role: :list) do |list|
      list.text "Sales grew in every region.", role: :list_item
      list.stack(role: :list_item) { |item| item.text "Costs fell, as planned." }
    end
    document.stack(background: "eeeeee", border_width: 1, padding: 8) { |stack| stack.text "A boxed summary. " * 200 }
    document.image "#{DATA_DIRECTORY}/images/dice.png", width: 100, alt: "Two dice"
    document.table(Array.new(80) { {name: "alice #{_1}", total: "$#{_1 * 3}.00"} }, stripes: %w[ffffff eeeeee])
    document.text "Merci de votre lecture.", lang: "fr"
    document.to_s
  end

  def dejavu(document)
    document.register_font "DejaVu", normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"
    document.style :default, font: "DejaVu"
    # What PDF/A and PDF/UA documents do on their own, for untagged ones to be drawn alike.
    document.prawn.font("DejaVu")
    document
  end

  def assert_valid(flavour, pdf)
    require_verapdf

    assert_nil Gamba::PdfCheck.pdf_a_failure(pdf, flavour:)
  end

  def assert_raises_with(error, message, &)
    raised = assert_raises(error, &)
    assert_match message, raised.message
  end

  def pixels(pdf)
    Gamba::PdfCheck.with_path(pdf) do |path|
      Dir.mktmpdir do |directory|
        system("mutool", "draw", "-q", "-r", "36", "-o", File.join(directory, "%03d.png"), path, exception: true)
        Dir[File.join(directory, "*.png")].sort.map { File.binread(_1) }
      end
    end
  end

  # The structure tree as nested hashes: each element's type, attributes, kids, and content as [page number, MCID].
  def structure(pdf)
    reader = PdfObjects.new(pdf)
    root = reader.value(reader.catalog["/StructTreeRoot"])
    element(reader, reader.value(root["/K"]).first)
  end

  def element(reader, reference)
    dictionary = reader.value(reference)
    kids = Array(dictionary["/K"]).map { reader.value(_1) }
    {
      type: dictionary["/S"].delete_prefix("/"),
      attributes: dictionary.except("/K", "/P", "/S", "/Type"),
      kids: Array(dictionary["/K"]).zip(kids).filter_map { |kid, value| element(reader, kid) if value["/Type"] == "/StructElem" },
      content: kids.select { _1["/Type"] == "/MCR" }.map { [reader.pages.index(_1["/Pg"]) + 1, _1["/MCID"]] }
    }
  end

  def walk(element, &block)
    yield element
    element[:kids].each { walk(_1, &block) }
  end
end
