# frozen_string_literal: true

# Page numbers drawn once a character spacing block has run over two pages: Prawn draws the first page's number
# spaced, inside the block it ended, laid out without the spacing; Gamba draws each number as the others.
character_spacing(4) do
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 50, size: 16
end
number_pages "Page <page> of <total>", at: [bounds.right - 150, 0], width: 150, align: :right
