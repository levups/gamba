# frozen_string_literal: true

# Random document bodies from a seed: text in its many forms, boxes, columns, tables, shapes and pages, nested
# the way real documents nest them. The same seed always gives the same documents.
class FuzzDocuments
  WORDS = %w[
    quarterly report widget gadget figures summary charts tables sales region office layout canvas column
    garden lantern setting delivery returns warranty raised café résumé naïve façade crème brûlée déjà cliché
    3.1.4 1,299.00 € VAT it's, don't — « quotes » ; points : commas ! questions ? A Ta Va AV To Yo fi fl office
  ].freeze
  COLORS = %w[000000 ff0000 00aa00 0000ff 555555 cc8800].freeze
  ALIGNMENTS = %i[left center right justify].freeze
  FONT_SETUP = <<~RUBY
    font_families.update("DejaVu" => {normal: "\#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans.ttf", bold: "\#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans-Bold.ttf"})
  RUBY

  def initialize(seed)
    @random = Random.new(seed)
  end

  def document
    lines = [FONT_SETUP]
    lines << (pick([true, false]) ? 'font "DejaVu"' : 'font "Helvetica"')
    rand(3..9).times { lines << statement(depth: 0) }
    lines << 'number_pages "<page> / <total>", at: [0, 0]' if rand < 0.3
    lines.insert(2, "repeat(:all) { fill_rectangle [bounds.left, bounds.top + 20], 100, 10 }") if rand < 0.2
    lines.join("\n")
  end

  private

  def statement(depth:)
    choices = %i[text text formatted text_box move shape table draw_text settings]
    choices += %i[bounding_box column_box float indent transparent blend_mode text_state rotate new_page] if depth < 2
    send(:"#{pick(choices)}_statement", depth:)
  end

  def text_statement(depth:)
    "text #{sentence.inspect}, #{text_options}"
  end

  def formatted_statement(depth:)
    fragments = Array.new(rand(1..4)) do
      fragment = {text: "#{sentence(1..5)} "}
      fragment[:styles] = [pick(%i[bold italic underline strikethrough superscript subscript])] if rand < 0.6
      fragment[:color] = pick(COLORS) if rand < 0.4
      fragment[:size] = rand(7..16) if rand < 0.3
      fragment
    end
    "formatted_text #{fragments.inspect}, align: #{pick(ALIGNMENTS).inspect}"
  end

  def text_box_statement(depth:)
    "text_box #{sentence(5..40).inspect}, at: [#{rand(0..200)}, cursor], width: #{rand(60..300)}, height: #{rand(20..120)}, " \
      "overflow: #{pick(%i[truncate shrink_to_fit expand]).inspect}, valign: #{pick(%i[top center bottom]).inspect}, #{text_options}"
  end

  def draw_text_statement(depth:)
    "draw_text #{sentence(1..4).inspect}, at: [#{rand(0..300)}, #{rand(0..600)}], size: #{rand(6..20)}, rotate: #{pick([0, 0, 15, 90])}"
  end

  def move_statement(depth:)
    "move_down #{rand(0..40)}"
  end

  def shape_statement(depth:)
    shape = pick([
      "stroke_rectangle [#{rand(0..300)}, #{rand(100..600)}], #{rand(10..200)}, #{rand(10..200)}",
      "fill_circle [#{rand(0..400)}, #{rand(0..600)}], #{rand(2..60)}",
      "stroke_rounded_rectangle [#{rand(0..300)}, #{rand(100..600)}], #{rand(20..200)}, #{rand(20..200)}, #{rand(1..10)}",
      "fill_polygon [#{rand(0..300)}, #{rand(0..300)}], [#{rand(0..300)}, #{rand(0..300)}], [#{rand(0..300)}, #{rand(0..300)}]",
      "stroke_horizontal_rule"
    ])
    "fill_color #{pick(COLORS).inspect}; stroke_color #{pick(COLORS).inspect}; line_width #{rand(1..4)}; #{shape}; fill_color '000000'; stroke_color '000000'"
  end

  def table_statement(depth:)
    columns = rand(1..5)
    rows = Array.new(rand(1..12)) { Array.new(columns) { sentence(1..6) } }
    if columns > 1 && rows.size > 1 && rand < 0.4
      rows[1] = [{content: sentence(1..3), colspan: 2}, *rows[1].drop(2)]
    end
    "table(#{rows.inspect}, header: #{pick([true, false])}, row_colors: #{pick([nil, %w[eeeeee ffffff]]).inspect}, " \
      "cell_style: {size: #{rand(7..12)}, padding: #{rand(1..8)}}, position: #{pick(%i[left center right]).inspect})"
  end

  def bounding_box_statement(depth:)
    "bounding_box([#{rand(0..100)}, cursor], width: #{rand(150..400)}) do\n#{nested(depth)}\nend"
  end

  def column_box_statement(depth:)
    "column_box([0, cursor], columns: #{rand(2..3)}, width: bounds.width, height: #{rand(100..300)}) do\n#{nested(depth)}\nend"
  end

  def float_statement(depth:)
    "float do\n#{nested(depth)}\nend"
  end

  def indent_statement(depth:)
    "indent(#{rand(0..60)}, #{rand(0..40)}) do\n#{nested(depth)}\nend"
  end

  def transparent_statement(depth:)
    "#{onto_existing_page}transparent(#{rand(1..9) / 10.0}) do\n#{nested(depth)}\nend"
  end

  def blend_mode_statement(depth:)
    "#{onto_existing_page}blend_mode(#{pick(%i[Multiply Screen Darken Difference]).inspect}) do\n#{nested(depth)}\nend"
  end

  # Sometimes a page after this one first, with settings of its own, and low on this one: text flowing out of the
  # block goes onto a page that exists, through go_to_page, and must keep there the block's opacity and blend mode,
  # and the settings in effect before it, not the page's.
  def onto_existing_page
    return "" if rand >= 0.25

    settings_there = (rand < 0.3) ? "#{settings_statement(depth: 0)}\n" : ""
    settings_here = (rand < 0.5) ? "#{settings_statement(depth: 0)}\n" : ""
    "start_new_page\n#{settings_there}go_to_page(page_number - 1)\nmove_down #{rand(300..600)}\n#{settings_here}"
  end

  # Text state blocks: text flowing out of one onto a new page must keep it there.
  def text_state_statement(depth:)
    setting = pick([
      "text_rendering_mode(#{pick(%i[stroke fill_stroke invisible]).inspect})", "character_spacing(#{rand(1..4)})",
      "word_spacing(#{rand(1..6)})", "horizontal_text_scaling(#{rand(60..140)})", "rise(#{rand(-4..4)})"
    ])
    "#{setting} do\n#{nested(depth)}\nend"
  end

  # Settings kept until changed again, unlike a shape's colours: blocks crossing a page break must end on them.
  def settings_statement(depth:)
    "fill_color #{pick(COLORS).inspect}; stroke_color #{pick(COLORS).inspect}; line_width #{rand(1..4)}; " \
      "#{pick(["dash(#{rand(1..6)})", "undash", "cap_style :round", "join_style :bevel", "blend_mode(#{pick(%i[Multiply Screen Normal]).inspect})",
        "forget_text_rendering_mode!",
        "fill_gradient [0, 0], [#{rand(100..500)}, 0], #{pick(COLORS).inspect}, #{pick(COLORS).inspect}",
        "stroke_gradient from: [0, 0], to: [0, #{rand(100..700)}], stops: #{[pick(COLORS), pick(COLORS)].inspect}"])}"
  end

  def rotate_statement(depth:)
    "rotate(#{rand(-30..30)}, origin: [#{rand(0..300)}, #{rand(0..500)}]) do\n#{nested(depth)}\nend"
  end

  def new_page_statement(depth:)
    "start_new_page(size: #{pick(%w[A4 LETTER A5]).inspect}, layout: #{pick(%i[portrait landscape]).inspect})"
  end

  def nested(depth)
    Array.new(rand(1..3)) { statement(depth: depth + 1) }.join("\n")
  end

  def text_options
    options = ["size: #{rand(6..18)}", "align: #{pick(ALIGNMENTS).inspect}"]
    options << "leading: #{rand(0..6)}" if rand < 0.4
    options << "character_spacing: #{rand(0..3)}" if rand < 0.3
    options << "style: #{pick(%i[bold italic]).inspect}" if rand < 0.3
    options << "kerning: false" if rand < 0.2
    options << "inline_format: true" if rand < 0.2
    options.join(", ")
  end

  def sentence(word_range = 3..30)
    Array.new(rand(word_range)) { pick(WORDS) }.join(" ")
  end

  def rand(range = nil)
    range ? @random.rand(range) : @random.rand
  end

  def pick(values)
    values[@random.rand(values.size)]
  end
end
