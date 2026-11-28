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
