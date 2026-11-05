# frozen_string_literal: true

# Character spacing, horizontal scaling and a text rendering mode around text that flows onto the next page: Prawn
# lays that page out spaced and narrowed but draws it plain, filled and overflowing its lines; Gamba draws it as the
# first page, then plain again after the blocks.
stroke_color "cc0000"
character_spacing(1.5) do
  horizontal_text_scaling(80) do
    text_rendering_mode(:fill_stroke) do
      text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 50, size: 16, align: :right
    end
  end
end
text "Plain again"
