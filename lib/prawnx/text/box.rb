# frozen_string_literal: true

module Prawn
  module Text
    # A text box of plain text: what does not fit comes back as a string.
    class Box < Formatted::Box
      def initialize(string, options = {})
        super([{text: string}], options)
      end

      def render(flags = {})
        super.map { it[:text] }.join
      end
    end
  end
end
