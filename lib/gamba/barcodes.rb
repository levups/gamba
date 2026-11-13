# frozen_string_literal: true

module Gamba
  # Symbologies encoded in pure Ruby, as grids of modules or runs of bars that Prawn::Barcodes draws.
  module Barcodes
    autoload :QRCode, ::File.expand_path("barcodes/qr_code", __dir__)
  end
end

module Prawn
  # Codes drawn as vector rectangles, one path and one fill per symbol: sharp at any size, and a sheet of labels
  # stays small.
  module Barcodes
    QR_OPTIONS = %i[at position vposition size module_size level quiet_zone color].freeze
    # The light margin scanners need around a QR code, in modules (ISO/IEC 18004 §6.3.8).
    QR_QUIET_ZONE_MODULES = 4
    DEFAULT_MODULE_SIZE = 2

    # A QR code of the text, from the top left corner at `at`, or placed as an image is: size is its width, quiet
    # zone included, or module_size the width of one module. level: :l, :m, :q or :h. Returns the symbol.
    def qr_code(text, options = {})
      Prawn.verify_options(QR_OPTIONS, options)
      symbol = Gamba::Barcodes::QRCode.new(text, level: options.fetch(:level, :m))
      draw_qr_code(symbol, options)
      symbol
    end

    # A symbol already encoded, with the options of qr_code but level.
    def draw_qr_code(symbol, options)
      quiet_zone = options.fetch(:quiet_zone, true) ? QR_QUIET_ZONE_MODULES : 0
      modules = symbol.size + (2 * quiet_zone)
      module_size = options[:size] ? options[:size] / modules.to_f : options.fetch(:module_size, DEFAULT_MODULE_SIZE)
      width = modules * module_size
      if options[:at]
        left, top = map_to_absolute(options[:at])
      else
        left, top = image_position(width, width, options.dup)
        move_text_position(width)
      end
      save_graphics_state do
        fill_color(options.fetch(:color, "000000"))
        add_content("#{module_path(symbol, left + (quiet_zone * module_size), top - (quiet_zone * module_size), module_size)}f")
      end
    end

    private

    # Dark modules side by side on a row are one rectangle of the path.
    def module_path(symbol, left, top, module_size)
      path = +""
      symbol.size.times do |y|
        x = 0
        while x < symbol.size
          unless symbol.dark?(x, y)
            x += 1
            next
          end

          run = x
          run += 1 while run < symbol.size && symbol.dark?(run, y)
          path << PDF::Core.real_params([left + (x * module_size), top - ((y + 1) * module_size), (run - x) * module_size, module_size]) << " re\n"
          x = run
        end
      end
      path
    end
  end
end
