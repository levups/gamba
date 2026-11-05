# frozen_string_literal: true

# A page break inside nested blocks: the inner block's end empties the new page's stack, the next block saves on it,
# and Prawn's outer block finds nothing to restore. Gamba renders both pages.
transparent(0.9) do
  transparent(0.6) do
    text "First page"
    start_new_page
  end
  transparent(0.5) do
    text "Saved on an emptied stack"
  end
end
