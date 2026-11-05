# frozen_string_literal: true

# A page break inside nested blocks, with nothing drawn after it: the inner block's end closes the new page's state,
# and Prawn's outer block finds nothing to restore. Gamba's outer block has nothing left to close.
transparent(0.9) do
  transparent(0.6) do
    text "First page"
    start_new_page
  end
end
text "Second page"
