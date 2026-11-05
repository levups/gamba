# frozen_string_literal: true

# A text rendering mode block and a text box after forget_text_rendering_mode!: Prawn writes the forgotten mode back
# as a Tr missing its operand, and Poppler drops the last line; Gamba writes nothing back, and draws it.
stroke_color "cc0000"
forget_text_rendering_mode!
text_rendering_mode(:fill_stroke) do
  text "Alice was beginning to get very tired of sitting by her sister on the bank.", size: 24
end
text "and of having nothing to do", size: 24
