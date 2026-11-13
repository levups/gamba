# frozen_string_literal: true

module Gamba
  module Layout
    # A table of named columns as a box: as wide as its box, broken across pages with its header when a stack
    # flows it. Prawn's table lays it out and draws it.
    class Table < Node
      OPTIONS = (Node::OPTIONS + %i[columns header stripes cell]).freeze
      COLUMN_OPTIONS = %i[title width align weight italic size color].freeze
      HEADER_OPTIONS = %i[align weight italic size color background].freeze
      CELL_OPTIONS = %i[padding size font color background borders border_width border_color].freeze
      DEFAULT_HEADER = {weight: :bold}.freeze
      # A native name on the left, the name of Prawn's cell on the right.
      PRAWN_CELL_NAMES = {color: :text_color, background: :background_color}.freeze
      # Prawn starts a new page unless a row is strictly shorter than what is left of the page: a table that
      # fills the page to the point would be cut. Measured a hair higher, it fits with room to spare or moves.
      PAGE_BREAK_SLACK_POINTS = 0.001

      def initialize(rows, styling, styles, **options)
        Styles.check_options(options, OPTIONS)
        super(**options.slice(*Node::OPTIONS))
        @rows = rows
        @styling = styling
        @styles = styles
        @columns = checked_columns(options[:columns] || inferred_columns)
        @header = checked_header(options.fetch(:header, true))
        @stripes = options[:stripes]
        @cell = options.fetch(:cell, {})
        Styles.check_options(@cell, CELL_OPTIONS)
      end

      def paint(prawn, left, top, width)
        return if data.empty?

        table = table(prawn, width)
        prawn.y = top
        within(prawn, left, width) { table.draw }
      end

      # Prawn draws a row higher than a page past its bottom: here it raises, as any box that cannot be split does.
      def flow(prawn, cursor, left, width)
        check_rows_fit(prawn, cursor, width) unless data.empty?
        paint(prawn, left, cursor.y, width)
        cursor.y = prawn.y unless data.empty?
      end

      # A page can start with the header and the first row.
      def first_height(prawn, width)
        return 0 if data.empty?

        table(prawn, width).rows(0..[@header ? 1 : 0, data.size - 1].min).height + PAGE_BREAK_SLACK_POINTS
      end

      private

      def measure(prawn, width)
        data.empty? ? 0 : table(prawn, width).height + PAGE_BREAK_SLACK_POINTS
      end

      def description
        "a table"
      end

      def check_rows_fit(prawn, cursor, width)
        heights = table(prawn, width).row_heights
        header = @header ? heights.first : 0
        tallest = (@header ? heights.drop(1) : heights).max || 0
        return if header + tallest <= cursor.page_height + FIT_TOLERANCE_POINTS

        raise Prawn::Errors::CannotFit, "#{description} has a row #{tallest.round(1)} pt high#{" under a #{header.round(1)} pt header" if @header}, " \
          "the page has #{cursor.page_height.to_f.round(1)} pt"
      end

      # Without columns, a table of hashes has those of its first row.
      def inferred_columns
        first = @rows.first
        unless first.is_a?(Hash)
          raise ArgumentError, 'columns are missing: name them, columns: {total: {title: "Total", align: :right}}, or give rows as hashes'
        end

        first.keys.to_h { |name| [name, {}] }
      end

      def checked_columns(columns)
        columns.each_value { |options| Styles.check_options(options, COLUMN_OPTIONS) }
        raise ArgumentError, "a table needs at least one column" if columns.empty?

        columns
      end

      def checked_header(header)
        return header ? DEFAULT_HEADER : nil unless header.is_a?(Hash)

        Styles.check_options(header, HEADER_OPTIONS)
        {**DEFAULT_HEADER, **header}
      end

      def data
        @data ||= begin
          body = @rows.map { |row| @columns.each_key.map { |name| value(row, name) } }
          @header ? [@columns.map { |name, options| options.fetch(:title) { name.to_s.tr("_", " ").capitalize } }, *body] : body
        end
      end

      def value(row, name)
        case row
        when Hash then row[name]
        when Array then raise ArgumentError, "a row is an array: rows are hashes, or objects answering the columns' names (Prawn's table of arrays is document.prawn.table)"
        else row.public_send(name)
        end
      end

      # Columns given all their widths keep them; otherwise the table takes the width of its box.
      def table(prawn, width)
        return @table if @table_width == width

        @table_width = width
        @table = within(prawn, prawn.bounds.absolute_left, width) do
          prawn.make_table(data, prawn_options(width)) do |table|
            style_columns(table)
            style(table.row(0), @header) if @header
            @styling&.call(table)
          end
        end
      end

      def prawn_options(width)
        widths = @columns.each_value.map { |options| options[:width] }
        options = {header: !@header.nil?, cell_style: prawn_cell_style({**@styles.cell_defaults, **@cell})}
        options[:row_colors] = @stripes if @stripes
        options[:column_widths] = widths.each_with_index.to_h { |column_width, index| [index, column_width] }.compact
        options[:width] = width unless widths.all?
        options
      end

      def style_columns(table)
        @columns.each_value.with_index { |options, index| style(table.column(index), options.except(:title, :width)) }
      end

      def style(cells, options)
        style = prawn_cell_style(options.except(:weight, :italic))
        style[:font_style] = Styles.font_style(options[:weight], options[:italic]) if options[:weight] || options[:italic]
        cells.style(style)
      end

      def prawn_cell_style(options)
        options.transform_keys { |name| PRAWN_CELL_NAMES.fetch(name, name) }
      end

      # Prawn's table reads its left edge and the width it may take from the bounds.
      def within(prawn, left, width, &)
        bounds = prawn.bounds
        prawn.indent(left - bounds.absolute_left, bounds.absolute_right - left - width, &)
      end
    end
  end
end
