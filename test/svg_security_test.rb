# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "socket"
require "timeout"
require "base64"

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

  private

  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")

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
