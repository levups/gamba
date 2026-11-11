# frozen_string_literal: true

module Gamba
  module Layout
    # What a header or a footer block knows of the page it is drawn on.
    Page = Data.define(:number, :total)

    # A header or a footer: a stack built again for each page once the document knows how many it has, drawn in
    # room taken from the page's margin box so the body never runs under it.
    class Band
      EDGES = {header: :top, footer: :bottom}.freeze

      def initialize(prawn, styles, name, gap, block)
        @prawn = prawn
        @styles = styles
        @name = name
        @gap = gap
        @block = block
      end

      # The room is the height the band has on the page it is declared on; it is kept on the pages that follow.
      def reserve
        first_page = @prawn.page_number
        @height = stack(first_page).height(@prawn, @prawn.margin_box.width)
        @prawn.page.margins[EDGES.fetch(@name)] += @height + @gap
        @prawn.__send__(:generate_margin_box)
        @prawn.y = [@prawn.y, @prawn.margin_box.absolute_top].min
        @prawn.repeat(->(page_number) { page_number >= first_page }, dynamic: true) { paint }
      end

      private

      def stack(page_number)
        stack = Stack.new(@styles)
        @block.call(stack, Page.new(number: page_number, total: @prawn.page_count))
        stack
      end

      # On the whole page as bounds: a table of the band then finds room where the margin box has none.
      def paint
        stack = stack(@prawn.page_number)
        body = @prawn.margin_box
        height = stack.height(@prawn, body.width)
        if height > @height + FIT_TOLERANCE_POINTS
          raise Prawn::Errors::CannotFit, "the #{@name} is #{height.round(1)} pt high on page #{@prawn.page_number}, " \
            "#{@height.round(1)} pt were kept for it, its height on the page it was declared on"
        end

        top = (@name == :header) ? body.absolute_top + @gap + @height : body.absolute_bottom - @gap
        @prawn.canvas { stack.paint(@prawn, body.absolute_left, top, body.width) }
      end
    end
  end
end
