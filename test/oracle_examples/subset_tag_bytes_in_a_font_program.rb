# frozen_string_literal: true

# PrawnX's compressed subset of this bold face holds the bytes "/XtqaB7+" by chance, which the oracle must not take for
# a subset tag. With another zlib, the bytes may not occur, and the example tests nothing more than its text.
font_families.update("DejaVu" => {bold: "#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans-Bold.ttf"})
font "DejaVu", style: :bold
text "; Achartsiedlnom3.14—wyuéjà!p'g«fV", size: 17
