# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/layout_trees"
require "open3"
require "prawn"

# Random trees of native boxes from a seed, placed across pages: nothing drawn leaves the margins, no two lines
# overlap, a stack kept together stays on one page whenever it fits on an empty one, and rendering twice gives the
# same bytes. LAYOUT_FUZZ_SEED and LAYOUT_FUZZ_CASES choose them; a failure names the file holding the document,
# kept in tmp/layout_fuzz to reproduce it.
class LayoutFuzzTest < Minitest::Test
  SEED = Integer(ENV.fetch("LAYOUT_FUZZ_SEED", "20261113"))
  CASES = Integer(ENV.fetch("LAYOUT_FUZZ_CASES", "60"))
  DIRECTORY = File.join(Oracle::ROOT, "tmp/layout_fuzz")
  TOLERANCE = 0.01
  # Helvetica's ascender and descender, in ems: where a glyph's ink may reach above and below its baseline.
  ASCENDER = 0.718
  DESCENDER = 0.207
  # A tree whose boxes cannot fit their page or their width is refused; most must be placed.
  MINIMUM_PLACED_SHARE = 0.6

  # Each stack kept together as it is flowed: whether it fits on an empty page, and the ids of what it holds.
  module KeptStacks
    class << self
      attr_accessor :recorded
    end

    def flow(prawn, cursor, left, width)
      if instance_variable_get(:@keep_together) && KeptStacks.recorded
        fits = height(prawn, width) <= cursor.page_height + Gamba::Layout::FIT_TOLERANCE_POINTS
        KeptStacks.recorded << [fits, KeptStacks.ids(self)]
      end
      super
    end

    def self.ids(node)
      case node
      when Gamba::Layout::Text then node.instance_variable_get(:@fragments).flat_map { _1[:text].split }.uniq
      when Gamba::Layout::Table then node.instance_variable_get(:@rows).flat_map { _1.values.flat_map(&:split) }.uniq
      when Gamba::Layout::Container then node.instance_variable_get(:@children).flat_map { ids(_1) }.uniq
      else []
      end
    end
  end
  Gamba::Layout::Stack.prepend(KeptStacks)

  def test_random_box_trees_are_placed_within_the_margins_without_overlaps
    FileUtils.rm_rf(DIRECTORY)
    FileUtils.mkdir_p(DIRECTORY)
    generator = LayoutTrees.new(SEED)
    placed = 0
    failures = CASES.times.filter_map do |index|
      source = generator.document
      path = File.join(DIRECTORY, format("tree_%04d.rb", index))
      File.write(path, source)
      problem = problem(source)
      next if problem == :refused

      placed += 1
      next File.delete(path) && nil unless problem

      "#{path}: #{problem}"
    end

    assert_empty failures, "seed #{SEED}"
    assert_operator placed, :>=, CASES * MINIMUM_PLACED_SHARE, "seed #{SEED}: too few trees fit their pages to test anything"
  end

  private

  def problem(source)
    KeptStacks.recorded = []
    document = eval(source, binding, "tree.rb") # rubocop:disable Security/Eval
    pdf = document.to_s
    kept = KeptStacks.recorded
    KeptStacks.recorded = nil
    return "rendered twice, the bytes differ" unless eval(source, binding, "tree.rb").to_s == pdf # rubocop:disable Security/Eval

    pages = trace(pdf)
    margins = margin_box(document.prawn)
    pages.each_with_index do |(paths, runs), page_index|
      outside = (paths + runs.map(&:last)).find { |box| !inside?(box, margins) }
      return "page #{page_index + 1}: #{outside.map { _1.round(2) }} leaves the margins #{margins}" if outside

      overlap = runs.combination(2).find { |(_, first), (_, second)| overlap?(first, second) }
      return "page #{page_index + 1}: #{overlap.map(&:first).inspect} overlap" if overlap
    end
    split_kept_stack(kept, pages)
  rescue Prawn::Errors::CannotFit
    :refused
  ensure
    KeptStacks.recorded = nil
  end

  def split_kept_stack(kept, pages)
    page_numbers_by_id = Hash.new { |hash, id| hash[id] = [] }
    pages.each_with_index do |(_paths, runs), page_index|
      runs.each { |text, _box| text.scan(/[tc]\d+/) { page_numbers_by_id[_1] |= [page_index + 1] } }
    end
    kept.each do |fits, ids|
      page_numbers = ids.flat_map { page_numbers_by_id[_1] }.uniq.sort
      return "a stack kept together, fitting a page, is split over pages #{page_numbers}: #{ids.first(5)}" if fits && page_numbers.size > 1
    end
    nil
  end

  # Each page as [path bounds, [text, glyph box] for each run of glyphs on one baseline], in points, from MuPDF.
  def trace(pdf)
    output = Tempfile.create(["tree", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      output, errors, status = Open3.capture3("mutool", "trace", file.path, binmode: true)
      raise "mutool trace failed: #{errors}" unless status.success?

      output
    end
    output.split("<page ").drop(1).map { |page| [paths(page), runs(page)] }
  end

  # A stroke is centred on its path: half its width may reach past the margins, as Prawn's table borders do.
  def paths(page)
    page.scan(%r{<(fill|stroke)_path([^>]*)>(.*?)</\1_path>}m).map do |kind, attributes, body|
      points = body.scan(/x="([-\d.]+)" y="([-\d.]+)"/).map { |x, y| [Float(x), Float(y)] }
      xs, ys = points.transpose
      reach = (kind == "stroke") ? Float(attributes[/linewidth="([\d.]+)"/, 1]) / 2 : 0
      [xs.min + reach, ys.min + reach, xs.max - reach, ys.max - reach]
    end
  end

  def runs(page)
    page.scan(%r{<span [^>]*trm="([-\d.]+)[^"]*"[^>]*>(.*?)</span>}m).flat_map do |size, body|
      size = Float(size)
      glyphs = body.scan(/unicode="([^"]*)"[^>]*x="([-\d.]+)" y="([-\d.]+)" adv="([-\d.]+)"/)
      glyphs.chunk { |_, _, y, _| y }.map do |y, line|
        baseline = Float(y)
        left = Float(line.first[1])
        right = Float(line.last[1]) + (Float(line.last[3]) * size)
        text = line.map { |unicode, *| unicode.gsub("&quot;", '"').gsub("&amp;", "&") }.join
        [text, [left, baseline - (DESCENDER * size), right, baseline + (ASCENDER * size)]]
      end
    end
  end

  def margin_box(prawn)
    box = prawn.margin_box
    [box.absolute_left, box.absolute_bottom, box.absolute_right, box.absolute_top]
  end

  def inside?((left, bottom, right, top), (margin_left, margin_bottom, margin_right, margin_top))
    left >= margin_left - TOLERANCE && right <= margin_right + TOLERANCE && bottom >= margin_bottom - TOLERANCE && top <= margin_top + TOLERANCE
  end

  def overlap?(first, second)
    [first[2], second[2]].min - [first[0], second[0]].max > TOLERANCE && [first[3], second[3]].min - [first[1], second[1]].max > TOLERANCE
  end
end
