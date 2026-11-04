# frozen_string_literal: true

# A blend_mode block whose text flows onto the next page, under a header: Prawn draws that page in the normal blend
# mode, PrawnX keeps multiplying the colours where the rectangle overlaps the text.
on_page_create { text "Header", align: :right }
blend_mode(:Multiply) do
  fill_color "00ccff"
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 60, size: 18
  fill_color "ffcc00"
  fill_rectangle [bounds.left + 40, cursor + 80], 300, 120
end
text "Normal again"
