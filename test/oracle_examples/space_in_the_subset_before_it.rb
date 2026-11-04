# frozen_string_literal: true

# Every subset of a TrueType font holds a space: Prawn encodes the space after "€" in the euro's subset, not in the
# first one. MuPDF places that space, where the line crosses the rotated text, by its subset.
font "#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans.ttf"
move_cursor_to 428
draw_text "€ summary", at: [141, 401], size: 19, rotate: 90
text "Yo summary of the tea party", size: 18, character_spacing: 3
