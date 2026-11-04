# frozen_string_literal: true

# PrawnX's compressed subset of this bold face holds the bytes "/XtqaB7+" by chance: the oracle took them for a
# subset tag and rewrote them, corrupting the font program. With another zlib, the bytes may not occur.
font_families.update("DejaVu" => {bold: "#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans-Bold.ttf"})
font "DejaVu", style: :bold
text "; Achartsiedlnom3.14—wyuéjà!p'g«fV", size: 17
