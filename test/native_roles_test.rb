# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "prawn"

# What each box is to a reader, for tagged PDF: headings, paragraphs, lists, tables, figures with their alternative
# text, artifacts. Headings already make the PDF's outline, nested by level, each pointing at its first line.
class NativeRolesTest < Minitest::Test
  def test_headings_make_the_outline_nested_by_level_at_their_first_line
    document = Gamba.document do |yielded|
      yielded.style :title, size: 18, weight: :bold, role: :h1
      yielded.text "Introduction", style: :title
      yielded.text "Background", role: :h2
      yielded.text "word " * 2000
      yielded.text "Details", role: :h3
      yielded.text "Methods", style: :title
      yielded.text "Data", role: :h3
    end
    outline = outline(document.to_s)

    assert_equal [["Introduction", [["Background", [["Details", []]]]]], ["Methods", [["Data", []]]]], titles(outline)
    lines = text_lines(document.to_s)
    flatten(outline).each do |item|
      page, baseline, size = lines.fetch(item["title"])
      assert_equal page, item["destpageposfrom1"], item["title"]
      # The destination is the top of the line: its baseline plus Helvetica's ascender.
      assert_in_delta 792 - baseline + (0.718 * size), item["dest"][3], 0.01, item["title"]
    end
    assert_operator lines.fetch("Methods").first, :>, 1
  end

  def test_a_heading_moved_to_the_next_page_points_at_that_page
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 700
      yielded.stack(background: "eeeeee", keep_together: true) do |stack|
        stack.text "Totals", role: :h2
        3.times { stack.text "line" }
      end
    end

    assert_equal [2], flatten(outline(document.to_s)).map { _1["destpageposfrom1"] }
  end

  def test_headings_of_prawn_code_blocks_share_one_outline_and_headers_bookmark_nothing
    prawn = Prawn::Document.new do
      gamba do |document|
        document.header { |stack, page| stack.text "Report, page #{page.number}", role: :h1 }
        document.text "Part one", role: :h1
      end
      text "Prawn's own text"
      gamba { |document| document.text "Section", role: :h2 }
    end

    assert_equal [["Part one", [["Section", []]]]], titles(outline(prawn.render))
  end

  def test_roles_are_checked_and_carried_by_each_box
    assert_equal :figure, Gamba::Layout::Image.new("logo.png", alt: "Example logo").role
    assert_equal "Example logo", Gamba::Layout::Image.new("logo.png", alt: "Example logo").alt
    assert_equal :table, Gamba::Layout::Table.new([{name: "alice"}], nil, nil).role
    assert_nil Gamba::Layout::Stack.new(Gamba::Layout::Styles.new(Prawn::Document.new, [])).role

    error = assert_raises(ArgumentError) { Gamba.document { |document| document.text "Hi", role: :h7 } }
    assert_equal "role is :h7: a text takes :p, :h1, :h2, :h3, :h4, :h5, :h6, :list_item, :artifact", error.message
    error = assert_raises(ArgumentError) { Gamba.document { |document| document.stack(role: :list, alt: "x") { _1.text "a" } } }
    assert_equal "alt is the alternative text of a figure: give it with role: :figure, not :list", error.message
    assert_raises(ArgumentError) { Gamba.document { |document| document.table([{name: "alice"}], role: :figure) } }
    assert_raises(ArgumentError) { Gamba.document { |document| document.qr_code("x", role: :p) } }
  end

  def test_roles_change_nothing_drawn
    plain = Gamba.document do |document|
      document.text "Title", size: 18
      document.stack { |list| list.text "one" }
      document.qr_code "https://example.com"
    end
    with_roles = Gamba.document do |document|
      document.text "Title", size: 18, role: :artifact
      document.stack(role: :list) { |list| list.text "one", role: :list_item }
      document.qr_code "https://example.com", alt: "Example's site"
    end

    assert_equal plain.to_s, with_roles.to_s
  end

  private

  def outline(pdf)
    Tempfile.create(["roles", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      JSON.parse(Open3.capture2("qpdf", "--json", "--json-key=outlines", file.path).first).fetch("outlines")
    end
  end

  def titles(items)
    items.map { [_1["title"], titles(_1["kids"])] }
  end

  def flatten(items)
    items.flat_map { [_1, *flatten(_1["kids"])] }
  end

  # Each line's text: [page, baseline from the top, size].
  def text_lines(pdf)
    Tempfile.create(["roles", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Oracle.text_layout(file.path).each_with_index.flat_map do |page, index|
        page.glyphs.group_by(&:last).map { |y, glyphs| [glyphs.map(&:first).join, [index + 1, y, glyphs.first[2]]] }
      end.to_h
    end
  end
end
