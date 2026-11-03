# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# The same document gives the same bytes, in one process or in two: golden files and change detection rely on it.
class DeterminismTest < Minitest::Test
  DOCUMENT = <<~RUBY
    require "prawn"
    pdf = Prawn::Document.new
    pdf.font "#{Oracle::ROOT}/corpus/cache/prawn/data/fonts/DejaVuSans.ttf"
    pdf.repeat(:all) { pdf.draw_text "Header", at: [0, 0] }
    pdf.text "Hello, world! " * 40
    pdf.image "#{Oracle::ROOT}/corpus/cache/prawn/data/images/dice.png", width: 100
    pdf.fill_gradient [0, 0], [100, 100], "ff0000", "0000ff"
    pdf.fill_rectangle [0, 100], 100, 100
    pdf.encrypt_document(user_password: "foo")
    print pdf.render
  RUBY

  def setup
    skip CORPUS_MISSING_MESSAGE if Oracle.manual_chapters.empty?
  end

  def test_two_renders_in_one_process_are_identical
    assert_equal render_in_this_process, render_in_this_process
  end

  def test_two_renders_in_two_processes_are_identical
    assert_equal render_in_a_new_process, render_in_a_new_process
  end

  private

  def render_in_this_process
    output = StringIO.new
    $stdout = output
    eval(DOCUMENT, binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- the document under test, defined above
    output.string
  ensure
    $stdout = STDOUT
  end

  def render_in_a_new_process
    output, status = Open3.capture2("ruby", "-I", File.join(Oracle::ROOT, "lib"), stdin_data: DOCUMENT, binmode: true)
    assert status.success?
    output
  end
end
