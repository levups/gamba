# frozen_string_literal: true

# Random documents of native boxes from a seed, as Ruby source: stacks, rows and grids nested a few levels deep,
# with gaps, paddings, backgrounds, borders and page break rules, holding texts and tables. Every word of a text
# or a cell is its id, t0001 or c0001, so each line drawn says which box it belongs to: a word broken across lines
# leaves pieces too short to pass for an id.
class LayoutTrees
  PAGE_SIZES = ["LETTER", "A5", [400, 300]].freeze
  MAX_DEPTH = 3
  FONT_SIZES = [8, 10, 12, 14].freeze

  def initialize(seed)
    @random = Random.new(seed)
  end

  def document
    @id = 0
    page_size = PAGE_SIZES.sample(random: @random)
    source = "Gamba.document(page_size: #{page_size.inspect}, margin: #{@random.rand(20..60)}) do |document|\n"
    @random.rand(1..6).times { source << box("document", 1, :document) }
    source << "end\n"
  end

  private

  # A box added to receiver, a container of the given kind or the document. Within a row or a grid, boxes share a
  # line of the page: they hold less, so that most trees fit their pages.
  def box(receiver, depth, parent, inline: false)
    kind = if depth > MAX_DEPTH
      leaf(inline)
    else
      (inline ? %i[text text stack] : %i[text text text table stack stack row grid]).sample(random: @random)
    end
    indent = "  " * depth
    case kind
    when :text then "#{indent}#{receiver}.text #{words("t", @random.rand(1..(inline ? 12 : 80))).inspect}#{text_options(parent, inline)}\n"
    when :table then "#{indent}#{receiver}.table(#{table_rows.inspect}#{", header: false" if chance(0.3)}#{width_options(parent, inline)})\n"
    else container(receiver, depth, parent, kind, indent, inline || %i[row grid].include?(kind))
    end
  end

  def leaf(inline)
    (inline || chance(0.85)) ? :text : :table
  end

  def container(receiver, depth, parent, kind, indent, inline)
    name = "box#{depth}"
    options = container_options(kind, inline) + width_options(parent, inline)
    source = "#{indent}#{receiver}.#{kind}(#{options.delete_prefix(", ")}) do |#{name}|\n"
    @random.rand(1..(inline ? 3 : 5)).times { source << box(name, depth + 1, kind, inline:) }
    source << "#{indent}end\n"
  end

  def container_options(kind, inline)
    options = +""
    options << ", columns: #{@random.rand(1..4)}" if kind == :grid
    options << ", gap: #{gap(kind)}" if chance(0.6)
    options << ", padding: #{padding}" if chance(0.5)
    options << ", background: \"eeeeee\"" if chance(0.3)
    options << ", border_width: #{[0.5, 1, 2].sample(random: @random)}" if chance(0.3)
    options << ", keep_together: true" if kind != :row && chance(inline ? 0.1 : 0.2)
    options << ", keep_with_next: true" if chance(0.15)
    options
  end

  def text_options(parent, inline)
    options = ", size: #{FONT_SIZES.sample(random: @random)}"
    options << ", widows: #{@random.rand(1..3)}, orphans: #{@random.rand(1..3)}" if chance(0.4)
    options << ", role: :h#{@random.rand(1..6)}" if chance(0.1)
    options << ", keep_with_next: true" if chance(0.15)
    options + width_options(parent, inline)
  end

  # In a row, a box takes a width or a share of what is left; elsewhere, sometimes a width.
  def width_options(parent, inline)
    return "" if %i[grid document].include?(parent)
    return ", grow: #{@random.rand(1..3)}" if parent == :row && chance(0.3)

    if chance(0.15)
      ", width: #{inline ? @random.rand(30..90) : @random.rand(60..250)}"
    else
      ""
    end
  end

  def table_rows
    Array.new(@random.rand(1..40)) { {name: words("c", @random.rand(1..6)), quantity: words("c", 1)} }
  end

  def gap(kind)
    return "[#{@random.rand(0..12)}, #{@random.rand(0..12)}]" if kind == :grid && chance(0.5)

    @random.rand(0..12)
  end

  def padding
    case @random.rand(3)
    when 0 then @random.rand(0..12).to_s
    when 1 then "[#{@random.rand(0..12)}, #{@random.rand(0..12)}]"
    else "[#{Array.new(4) { @random.rand(0..12) }.join(", ")}]"
    end
  end

  def words(prefix, count)
    id = format("%s%04d", prefix, @id += 1)
    ([id] * count).join(" ")
  end

  def chance(probability)
    @random.rand < probability
  end
end
