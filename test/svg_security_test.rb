# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "prawn-svg"
require "socket"
require "timeout"
require "base64"
require "zlib"

# An SVG names URLs: rendering it must not make the server fetch them unless the caller says so.
class SvgSecurityTest < Minitest::Test
  def test_an_svg_does_not_reach_the_web_by_default
    connections = connections_while_rendering do |port|
      data = image_svg(port)
      Prawn::Document.new { svg data }.render
    end

    assert_equal 0, connections
  end

  def test_web_requests_stay_available_on_request
    connections = connections_while_rendering do |port|
      data = image_svg(port)
      Prawn::Document.new { svg data, enable_web_requests: true }.render
    end

    assert_operator connections, :>, 0
  end

  def test_an_id_holding_quotes_names_an_element_and_nothing_else
    data = svg(%(<g id="a"><rect width="1" height="1"/></g><use xlink:href="#a&quot;] | //*[&quot;"/>))
    warnings = render_within_time(data)
    assert_includes warnings.join, "could not be resolved"
  end

  def test_references_to_missing_ids_read_the_document_once
    render_within_time(svg(%(<use xlink:href="#missing"/>) * 3000 + %(<rect fill="url(#missing)" width="1" height="1"/>) * 3000))
  end

  def test_a_use_drawing_its_own_ancestor_is_skipped
    [%(<g id="a"><use xlink:href="#a"/></g>), %(<use id="a" xlink:href="#b"/><use id="b" xlink:href="#a"/>)].each do |body|
      assert_includes render_within_time(svg(body)).join, "contains it"
    end
  end

  def test_uses_doubling_at_each_level_stop_at_a_budget
    levels = (1..20).map { |level| %(<g id="l#{level}"><use xlink:href="#l#{level - 1}"/><use xlink:href="#l#{level - 1}"/></g>) }
    warnings = render_within_time(svg(%(<defs><rect id="l0" width="1" height="1"/>#{levels.join}</defs><use xlink:href="#l20"/>)))
    assert_includes warnings.join, "draw more than"
  end

  def test_gradients_referring_to_each_other_paint_nothing
    body = %(<defs><linearGradient id="a" xlink:href="#b"/><linearGradient id="b" xlink:href="#a"/></defs><rect width="10" height="10" fill="url(#a)"/>)
    render_within_time(svg(body))
  end

  def test_a_gradient_without_stops_used_before_it_is_defined_paints_nothing
    render_within_time(svg(%(<rect width="10" height="10" fill="url(#a)"/><defs><linearGradient id="a"/></defs>)))
  end

  def test_elements_nested_too_deep_are_refused
    error = assert_raises(Prawn::SVG::Document::InvalidSVGData) { Prawn::Document.new { svg %(<svg xmlns="http://www.w3.org/2000/svg">#{"<g>" * 4000}#{"</g>" * 4000}</svg>) } }
    assert_match(/deeper/, error.message)
  end

  def test_entities_expanding_too_far_are_invalid_svg
    entities = %(<!ENTITY a "aaaaaaaaaa">) + (1..9).map { |level| %(<!ENTITY #{("a".ord + level).chr} "#{"&#{("a".ord + level - 1).chr};" * 10}">) }.join
    data = %(<?xml version="1.0"?><!DOCTYPE svg [#{entities}]><svg xmlns="http://www.w3.org/2000/svg"><text>&j;</text></svg>)
    assert_raises(Prawn::SVG::Document::InvalidSVGData) { Prawn::Document.new { svg data } }
  end

  def test_descendant_selectors_on_nested_elements_match_in_polynomial_time
    render_within_time(svg(%(<style>#{"g " * 20}{fill:red}</style>#{"<g>" * 20}<rect width="1" height="1"/>#{"</g>" * 20})))
  end

  def test_a_selector_value_holding_brackets_matches_nothing
    body = %(<style>[a='"] | /descendant::g/descendant::g/descendant::g/descendant::g/descendant::g | /descendant::g["'] { fill: red }</style>)
    render_within_time(svg(body + "<g>" * 12 + "<g/>" * 30 + "</g>" * 12))
  end

  def test_a_font_face_does_not_outlive_its_svg
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    font = Base64.strict_encode64(File.binread(FONT))
    pdf = Prawn::Document.new
    pdf.svg svg(%(<style>@font-face { font-family: "Helvetica"; src: url("data:font/ttf;base64,#{font}"); }</style><text>alice</text>))
    assert_equal "Helvetica", pdf.font_families["Helvetica"][:normal]
  end

  def test_masks_inside_masks_render
    mask = %(<mask id="inner"><rect width="5" height="5" fill="white"/></mask>) +
      %(<mask id="outer"><rect width="10" height="10" fill="white" mask="url(#inner)"/></mask>)
    render_within_time(svg(%(<defs>#{mask}</defs><rect width="10" height="10" mask="url(#outer)"/>)))
  end

  def test_an_embedded_svg_with_text_renders
    inner = Base64.strict_encode64(svg("<text>alice</text>"))
    render_within_time(svg(%(<image width="10" height="10" xlink:href="data:image/svg+xml;base64,#{inner}"/>)))
  end

  def test_infinite_numbers_never_reach_the_page
    pdf = Prawn::Document.new
    pdf.svg svg(%(<g transform="rotate(1e400)"><rect width="1" height="1"/></g><rect width="1" height="1" stroke="black" stroke-miterlimit="1e400"/>) +
      %(<text x="1e400" y="1e400" rotate="1e400">alice</text>))
    refute_match(/\b(?:NaN|Inf(?:inity)?)\b/, uncompressed(pdf.render))
  end

  def test_a_directory_inside_the_file_root_is_skipped
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "logo.png"))
      pdf = Prawn::Document.new
      result = pdf.svg(svg(%(<image width="1" height="1" xlink:href="logo.png"/>)), enable_file_requests_with_root: root)
      assert_includes result[:warnings].join, "not a regular file"
    end
  end

  def test_an_svg_loaded_by_use_is_checked_like_the_document
    entities = %(<!ENTITY a "aaaaaaaaaa">) + (1..9).map { |level| %(<!ENTITY #{("a".ord + level).chr} "#{"&#{("a".ord + level - 1).chr};" * 10}">) }.join
    [svg(%(<g id="a">#{"<g>" * 4000}#{"</g>" * 4000}</g>)),
      %(<?xml version="1.0"?><!DOCTYPE svg [#{entities}]><svg xmlns="http://www.w3.org/2000/svg"><g id="a"><text>&j;</text></g></svg>)].each do |external|
      assert_includes render_within_time(svg(%(<use xlink:href="#{data_url(external)}#a"/>))).join, "could not be parsed"
    end
  end

  def test_entities_expanding_too_far_in_an_attribute_are_invalid_svg
    entities = %(<!ENTITY a "aaaaaaaaaa">) + (1..9).map { |level| %(<!ENTITY #{("a".ord + level).chr} "#{"&#{("a".ord + level - 1).chr};" * 10}">) }.join
    data = %(<?xml version="1.0"?><!DOCTYPE svg [#{entities}]><svg xmlns="http://www.w3.org/2000/svg"><rect id="&j;" width="1" height="1"/></svg>)
    assert_raises(Prawn::SVG::Document::InvalidSVGData) { Prawn::Document.new { svg data } }
  end

  def test_svg_images_drawn_through_use_share_the_budget_of_their_document
    levels = (1..9).map { |level| %(<g id="l#{level}"><use xlink:href="#l#{level - 1}"/><use xlink:href="#l#{level - 1}"/></g>) }
    image = svg(%(<defs><rect id="l0" width="1" height="1"/>#{levels.join}</defs><use xlink:href="#l9"/>))
    refute_includes render_within_time(image).join, "draw more than"

    image = data_url(image)
    copies = (1..3).map { |level| %(<g id="m#{level}"><use xlink:href="#m#{level - 1}"/><use xlink:href="#m#{level - 1}"/></g>) }
    warnings = render_within_time(svg(%(<defs><image id="m0" width="5" height="5" xlink:href="#{image}"/>#{copies.join}</defs><use xlink:href="#m3"/>)))
    assert_includes warnings.join, "draw more than"
  end

  def test_svg_images_inside_svg_images_stop_at_a_depth
    image = svg(%(<rect width="1" height="1"/>))
    (Prawn::SVG::Document::MAXIMUM_EMBEDDING_DEPTH + 1).times { image = svg(%(<image width="5" height="5" xlink:href="#{data_url(image)}"/>)) }
    assert_includes render_within_time(image).join, "nested deeper than"
  end

  def test_a_data_url_image_drawn_through_use_is_decoded_once
    rows = Array.new(400) { |row| "\x00".b + Random.new(row).bytes(1200) }
    png = "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", [400, 400, 8, 2, 0, 0, 0].pack("N2C5")) +
      png_chunk("IDAT", Zlib::Deflate.deflate(rows.join)) + png_chunk("IEND", "")
    copies = (1..12).map { |level| %(<g id="m#{level}"><use xlink:href="#m#{level - 1}"/><use xlink:href="#m#{level - 1}"/></g>) }
    render_within_time(svg(%(<defs><image id="m0" width="5" height="5" xlink:href="data:image/png;base64,#{Base64.strict_encode64(png)}"/>#{copies.join}</defs><use xlink:href="#m12"/>)))
  end

  def test_a_tref_inside_the_text_it_refers_to_is_skipped
    assert_includes render_within_time(svg(%(<text id="t">alice<tref xlink:href="#t"/></text>))).join, "contains it"
  end

  def test_a_tref_to_a_missing_or_later_text_draws_nothing
    render_within_time(svg(%(<text>alice<tref xlink:href="#missing"/><tref xlink:href="#later"/></text><text id="later">Post</text>)))
  end

  def test_trefs_doubling_at_each_level_stop_at_a_budget
    levels = (1..20).map { |level| %(<text id="t#{level}"><tref xlink:href="#t#{level - 1}"/><tref xlink:href="#t#{level - 1}"/></text>) }
    assert_includes render_within_time(svg(%(<text id="t0">a</text>#{levels.join}))).join, "draw more than"
  end

  def test_a_font_face_that_is_not_a_font_is_left_out
    font_face = %(<style>@font-face { font-family: "alice"; src: url("data:image/png;base64,#{Base64.strict_encode64("alice")}"); }</style>)
    render_within_time(svg(%(#{font_face}<text font-family="alice">Post</text>)))
  end

  def test_an_import_climbing_back_up_its_path_resolves_quickly
    path = "/#{"a/" * 4000}#{"../" * 4000}example.css"
    render_within_time(svg(%(<style>@import url("#{path}");</style><rect width="1" height="1"/>)), seconds: 2)
  end

  private

  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")

  def data_url(svg)
    "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
  end

  def png_chunk(type, data)
    [data.bytesize].pack("N") + type + data.b + [Zlib.crc32(type + data.b)].pack("N")
  end

  def svg(body)
    %(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">#{body}</svg>)
  end

  def render_within_time(data, seconds: 10)
    Timeout.timeout(seconds) do
      pdf = Prawn::Document.new
      result = pdf.svg(data)
      pdf.render
      result[:warnings]
    end
  end

  def uncompressed(pdf)
    Tempfile.create(["svg", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.close
      output, status = Open3.capture2("qpdf", "--qdf", "--object-streams=disable", file.path, "-")
      assert status.success?
      output.b
    end
  end

  def image_svg(port)
    %(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">) +
      %(<image xlink:href="http://127.0.0.1:#{port}/image.png" width="10" height="10"/></svg>)
  end

  def connections_while_rendering
    server = TCPServer.new("127.0.0.1", 0)
    connections = 0
    acceptor = Thread.new do
      loop do
        server.accept.close
        connections += 1
      end
    rescue IOError
      nil
    end
    yield server.addr[1]
    connections
  ensure
    server&.close
    acceptor&.join(1)
  end
end
