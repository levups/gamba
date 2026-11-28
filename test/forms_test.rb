# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "prawn"

# Form fields a reader fills in: read back by qpdf as a viewer's form would see them, and drawn by their own
# appearances, which MuPDF and Poppler both show.
class FormsTest < Minitest::Test
  def test_fields_read_back_with_their_kind_value_flags_and_options
    fields = acro_form_fields(order_form).to_h { [_1["fullname"], _1] }

    assert_equal %w[name notes code secret agree news size country colour Prénom], fields.keys
    assert_equal ["/Tx", "u:Alice Martin", 0], fields["name"].values_at("fieldtype", "value", "fieldflags")
    assert_equal [Gamba::Forms::MULTILINE, Gamba::Forms::COMB, Gamba::Forms::PASSWORD], fields.values_at("notes", "code", "secret").map { _1["fieldflags"] }
    assert_nil fields["secret"]["value"]
    assert_equal ["/Yes", "/Off", "/m"], fields.values_at("agree", "news", "size").map { _1["value"] }
    assert_equal Gamba::Forms::RADIO | Gamba::Forms::NO_TOGGLE_TO_OFF, fields["size"]["fieldflags"]
    assert_equal [["France", "Belgique", "Suisse"], "u:Belgique"], fields["country"].values_at("choices", "value")
    assert_equal "u:Zoë", fields["Prénom"]["value"]
  end

  def test_each_viewer_draws_the_values_from_the_fields_own_appearances
    path = write(order_form)

    [Open3.capture2("mutool", "draw", "-q", "-F", "txt", "-o", "-", path, "1").first, Open3.capture2("pdftotext", path, "-").first].each do |text|
      ["Alice Martin", "Second", "*******", "Belgique", "Green", "Zoë"].each { assert_includes text, _1 }
      refute_includes text, "hunter2"
    end
  end

  def test_a_check_box_and_radio_buttons_have_an_appearance_for_each_state
    objects = qpdf_objects(order_form)
    widgets = objects.values.filter_map { _1["value"] }.select { _1["/Subtype"] == "/Widget" }
    agree = widgets.find { _1["/T"] == "u:agree" }
    buttons = widgets.select { _1.key?("/Parent") }

    assert_equal ["/Yes", %w[/Off /Yes]], [agree["/AS"], agree["/AP"]["/N"].keys.sort]
    assert_equal [%w[/Off /s], %w[/Off /m], %w[/Off /l]], buttons.map { _1["/AP"]["/N"].keys.sort }
    assert_equal %w[/Off /m /Off], buttons.map { _1["/AS"] }
  end

  def test_what_a_field_cannot_hold_or_a_standard_forbids_raises
    document = Prawn::Document.new
    assert_raises(Prawn::Errors::IncompatibleStringEncoding) { document.text_field "name", at: [0, 700], width: 100, height: 20, value: "Ελένη" }
    assert_raises(ArgumentError) { document.text_field "code", at: [0, 700], width: 100, height: 20, comb: true }
    assert_raises(ArgumentError) { document.text_field "code", at: [0, 700], width: 100, height: 20, value: "123456", max_length: 5 }
    assert_raises(ArgumentError) { document.text_field "", at: [0, 700], width: 100, height: 20 }
    assert_raises(ArgumentError) { document.radio_buttons "size", buttons: {"s" => [0, 0]}, selected: "xl" }
    assert_raises(ArgumentError) { document.choice_field "country", at: [0, 700], width: 100, height: 20, options: %w[France], value: "Spain" }
    assert_raises(Prawn::Errors::PdfAViolation) { Prawn::Document.new(pdf_a: true).check_box "agree", at: [0, 700] }
    assert_raises(Prawn::Errors::PdfUaViolation) { Gamba.document(pdf: :ua, lang: "en", info: {Title: "Order"}).prawn.check_box "agree", at: [0, 700] }
  end

  def test_fill_sets_values_and_draws_them_with_new_appearances
    filled = Gamba.fill(blank_form, "name" => "Alice Martin", "notes" => "Two lines\nof notes", "agree" => true, "size" => "m", "country" => "Belgique")
    fields = acro_form_fields(filled).to_h { [_1["fullname"], _1["value"]] }

    assert_equal({"name" => "u:Alice Martin", "notes" => "u:Two lines\nof notes", "agree" => "/Yes", "size" => "/m", "country" => "u:Belgique"}, fields)
    text = Open3.capture2("pdftotext", write(filled), "-").first
    ["Alice Martin", "of notes", "Belgique"].each { assert_includes text, _1 }
  end

  def test_a_flattened_form_draws_its_values_into_the_page_and_keeps_no_field
    values = {"name" => "Alice Martin", "agree" => true, "size" => "m", "country" => "Belgique"}
    filled = Gamba.fill(blank_form, values)
    flat = Gamba.fill(blank_form, values, flatten: true)

    refute JSON.parse(Open3.capture2("qpdf", "--json=2", "--json-key=acroform", write(flat)).first).dig("acroform", "hasacroform")
    refute_includes Open3.capture2("qpdf", "--qdf", "--object-streams=disable", write(flat), "-").first.b, "/Widget"
    [Open3.capture2("mutool", "draw", "-q", "-F", "txt", "-o", "-", write(flat), "1").first, Open3.capture2("pdftotext", write(flat), "-").first].each do |text|
      ["Alice Martin", "Belgique"].each { assert_includes text, _1 }
    end
    assert_equal rasterized(filled), rasterized(flat)
  end

  def test_fill_drops_javascript_and_refuses_what_a_field_cannot_take
    form = Prawn::Document.new do
      widget = text_field "name", at: [0, 700], width: 100, height: 20
      widget.data[:AA] = {K: {S: :JavaScript, JS: PDF::Core::LiteralString.new("app.alert(1)")}}
      radio_buttons "size", buttons: {"s" => [0, 650]}
      choice_field "country", at: [0, 600], width: 100, height: 20, options: %w[France]
    end.render

    refute_includes Open3.capture2("qpdf", "--qdf", "--object-streams=disable", write(Gamba.fill(form, "name" => "Alice")), "-").first.b, "JavaScript"
    assert_raises(ArgumentError) { Gamba.fill(form, "surname" => "Martin") }
    assert_raises(ArgumentError) { Gamba.fill(form, "size" => "xl") }
    assert_raises(ArgumentError) { Gamba.fill(form, "country" => "Spain") }
    assert_raises(Prawn::Errors::IncompatibleStringEncoding) { Gamba.fill(form, "name" => "Ελένη") }
  end

  private

  def order_form
    Prawn::Document.new do
      text "Order form"
      text_field "name", at: [0, 680], width: 200, height: 20, value: "Alice Martin"
      text_field "notes", at: [0, 650], width: 200, height: 60, value: "First line, a sentence long enough to wrap\nSecond", multiline: true
      text_field "code", at: [0, 580], width: 120, height: 20, value: "75001", comb: true, max_length: 6
      text_field "secret", at: [0, 550], width: 120, height: 20, value: "hunter2", password: true
      check_box "agree", at: [0, 520], checked: true
      check_box "news", at: [20, 520]
      radio_buttons "size", buttons: {"s" => [0, 500], "m" => [20, 500], "l" => [40, 500]}, selected: "m"
      choice_field "country", at: [0, 470], width: 120, height: 20, options: %w[France Belgique Suisse], value: "Belgique"
      choice_field "colour", at: [150, 470], width: 120, height: 50, options: %w[Red Green Blue], value: "Green", list: true
      text_field "Prénom", at: [0, 400], width: 120, height: 20, value: "Zoë"
    end.render
  end

  def blank_form
    Prawn::Document.new do
      text "Order form"
      text_field "name", at: [0, 680], width: 200, height: 20
      text_field "notes", at: [0, 650], width: 200, height: 60, multiline: true
      check_box "agree", at: [0, 560]
      radio_buttons "size", buttons: {"s" => [0, 530], "m" => [20, 530]}
      choice_field "country", at: [0, 500], width: 120, height: 20, options: %w[France Belgique]
    end.render
  end

  def rasterized(pdf)
    Dir.mktmpdir do |directory|
      Oracle.rasterize(write(pdf), File.join(directory, "page")).map { File.binread(_1) }
    end
  end

  def write(pdf)
    path = File.join(Dir.mktmpdir, "form.pdf")
    File.binwrite(path, pdf)
    path
  end

  def acro_form_fields(pdf)
    JSON.parse(Open3.capture2("qpdf", "--json=2", "--json-key=acroform", write(pdf)).first).fetch("acroform").fetch("fields")
  end

  def qpdf_objects(pdf)
    JSON.parse(Open3.capture2("qpdf", "--json=2", "--json-key=qpdf", write(pdf)).first).fetch("qpdf").last
  end
end
