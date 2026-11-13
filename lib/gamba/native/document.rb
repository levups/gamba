# frozen_string_literal: true

require_relative "layout"
require_relative "table"
require_relative "band"

module Gamba
  # Gamba's own API, over a Prawn::Document that stays reachable through #prawn. Blocks receive this object,
  # options are keywords, and an unknown one raises instead of being ignored.
  class Document
    include Layout::Builder

    OPTIONS = %i[
      page_size page_layout margin left_margin right_margin top_margin bottom_margin background info print_scaling
      pdf_a lang background_pdf background_pdf_page
    ].freeze
    TEXT_ATTRIBUTES = Layout::Styles::TEXT_ATTRIBUTES
    # No Prawn page to match here, so fonts that have ligatures and GPOS kerning use them.
    DEFAULT_FONT_FEATURES = %i[liga kern].freeze

    def initialize(prawn = nil, **options)
      Layout::Styles.check_options(options, OPTIONS)
      @prawn = prawn || Prawn::Document.new(options)
      @styles = Layout::Styles.new(@prawn, DEFAULT_FONT_FEATURES)
    end

    # The Prawn document underneath. Boxes still waiting for the one they are kept with are placed first, so what
    # Prawn draws next comes after them.
    def prawn
      place_kept
      @prawn
    end

    def register_font(family, normal:, bold: nil, italic: nil, bold_italic: nil, features: DEFAULT_FONT_FEATURES)
      files = {normal:, bold:, italic:, bold_italic:}.compact
      prawn.font_families[family] = files.transform_values { |file| {file:, features:} }
      self
    end

    # Text attributes under a name: text "…", style: name. The :default style applies to every text.
    def style(name, **attributes)
      @styles.define(name, attributes)
      self
    end

    def text(string, style: nil, **attributes)
      add(Layout::Text.new(string, **@styles.text_arguments(style, attributes)))
    end

    # What follows starts at the top of a new page, the boxes waiting for a next one placed first.
    def page_break
      prawn.start_new_page
      self
    end

    # Drawn at the top of every page from this one on. The block receives a stack to fill and the page, which
    # answers number and total; gap is the room left between the header and the body.
    def header(gap: 0, &block)
      declare_band(:header, gap, block)
    end

    def footer(gap: 0, &block)
      declare_band(:footer, gap, block)
    end

    def to_s
      prawn.render
    end

    def write(destination)
      if destination.respond_to?(:write)
        destination.write(to_s)
      else
        File.binwrite(destination, to_s)
      end
      self
    end

    private

    def declare_band(name, gap, block)
      raise ArgumentError, "the #{name} takes a block, which receives a stack and the page" unless block
      raise ArgumentError, "the #{name} is already declared: a document has one" if (@bands ||= {}).key?(name)

      @bands[name] = Layout::Band.new(prawn, @styles.without_bookmarks, name, gap, block).tap(&:reserve)
      self
    end

    # A box of the document is placed as soon as it is described, from the cursor, which it leaves below; one
    # kept with the next waits for it, and they are placed together.
    def add(box)
      raise ArgumentError, "grow shares the width of a row: it means nothing on the document" if box.grow

      if @kept.nil? && !box.keep_with_next
        place(box)
      else
        (@kept ||= Layout::Group.new(@styles)).push(box)
        place_kept unless box.keep_with_next
      end
      self
    end

    def place_kept
      return unless @kept

      kept = @kept
      @kept = nil
      place(kept)
    end

    def place(box)
      bounds = @prawn.bounds
      cursor = Layout::Cursor.new(@prawn)
      box.flow(@prawn, cursor, bounds.absolute_left, [box.width || bounds.width, bounds.width].min)
      @prawn.y = cursor.y
    end
  end
end
