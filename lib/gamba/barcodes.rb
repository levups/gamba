# frozen_string_literal: true

module Gamba
  # Symbologies encoded in pure Ruby, as grids of modules or runs of bars that Prawn::Barcodes draws.
  module Barcodes
    autoload :QRCode, ::File.expand_path("barcodes/qr_code", __dir__)
    autoload :Linear, ::File.expand_path("barcodes/linear", __dir__)
    autoload :DataMatrix, ::File.expand_path("barcodes/data_matrix", __dir__)
  end
end

module Prawn
  # Codes drawn as vector rectangles, one path and one fill per symbol: sharp at any size, and a sheet of labels
  # stays small.
  module Barcodes
    QR_OPTIONS = %i[at position vposition size module_size level quiet_zone color].freeze
    DATA_MATRIX_OPTIONS = (QR_OPTIONS - %i[level]).freeze
    DEFAULT_MODULE_SIZE = 2
    BARCODE_OPTIONS = %i[type at position vposition width module_size height text text_size color quiet_zone].freeze
    # Bars this many modules high unless told, and their digits this many modules high.
    DEFAULT_BAR_HEIGHT_MODULES = 50
    TEXT_SIZE_MODULES = 8
    TEXT_GAP_MODULES = 2

    # A QR code of the text, from the top left corner at `at`, or placed as an image is: size is its width, quiet
    # zone included, or module_size the width of one module. level: :l, :m, :q or :h. Returns the symbol.
    def qr_code(text, options = {})
      Prawn.verify_options(QR_OPTIONS, options)
      symbol = Gamba::Barcodes::QRCode.new(text, level: options.fetch(:level, :m))
      draw_matrix_code(symbol, options)
      symbol
    end

    # A square DataMatrix ECC 200 symbol of the data, the smallest that holds it, with the options of qr_code but
    # level: its error correction is fixed by its size. Returns the symbol.
    def data_matrix(data, options = {})
      Prawn.verify_options(DATA_MATRIX_OPTIONS, options)
      symbol = Gamba::Barcodes::DataMatrix.new(data)
      draw_matrix_code(symbol, options)
      symbol
    end

    # A linear barcode of the data, type :code128, :ean13, :ean8, :code39 or :itf14, from the top left corner at
    # `at`, or placed as an image is. width counts the quiet zones, or module_size sets the narrowest bar; height is
    # the bars'. text: true writes the encoded text under them, check digit included. Returns the symbol.
    def barcode(data, options = {})
      Prawn.verify_options(BARCODE_OPTIONS, options)
      raise ArgumentError, "barcode needs a type: :code128, :ean13, :ean8, :code39 or :itf14" unless options[:type]

      symbol = Gamba::Barcodes::Linear.new(data, type: options[:type])
      draw_barcode(symbol, options)
      symbol
    end

    # A symbol already encoded, with the options of barcode but type.
    def draw_barcode(symbol, options)
      quiet_left, module_size, bar_height, text_size, width, height = Barcodes.linear_dimensions(symbol, options)
      if options[:at]
        left, top = map_to_absolute(options[:at])
      else
        left, top = image_position(width, height, options.dup)
        move_text_position(height)
      end
      bars_left = left + (quiet_left * module_size)
      save_graphics_state do
        fill_color(options.fetch(:color, "000000"))
        add_content("#{bar_path(symbol, bars_left, top - bar_height, module_size, bar_height)}f")
        if text_size
          text_box symbol.text, at: [bars_left - bounds.absolute_left, top - bar_height - (TEXT_GAP_MODULES * module_size) - bounds.absolute_bottom],
            width: symbol.length * module_size, height: text_size * 1.5, size: text_size, align: :center, overflow: :shrink_to_fit
        end
      end
    end

    # The left quiet zone in modules, the module, bar and text sizes, and the whole symbol's width and height.
    def self.linear_dimensions(symbol, options)
      quiet_left, quiet_right = options.fetch(:quiet_zone, true) ? symbol.quiet_zones : [0, 0]
      modules = quiet_left + symbol.length + quiet_right
      module_size = options[:width] ? options[:width] / modules.to_f : options.fetch(:module_size, DEFAULT_MODULE_SIZE)
      bar_height = options[:height] || (DEFAULT_BAR_HEIGHT_MODULES * module_size)
      text_size = options[:text_size] || (TEXT_SIZE_MODULES * module_size) if options[:text]
      height = bar_height + (text_size ? (TEXT_GAP_MODULES * module_size) + text_size : 0)
      [quiet_left, module_size, bar_height, text_size, modules * module_size, height]
    end

    # A QR code or a DataMatrix already encoded, with the options of qr_code but level.
    def draw_matrix_code(symbol, options)
      quiet_zone = options.fetch(:quiet_zone, true) ? symbol.quiet_zone : 0
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

    def bar_path(symbol, left, bottom, module_size, height)
      path = +""
      x = left
      symbol.widths.each_with_index do |width, index|
        path << PDF::Core.real_params([x, bottom, width * module_size, height]) << " re\n" if index.even?
        x += width * module_size
      end
      path
    end

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
