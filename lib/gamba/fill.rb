# frozen_string_literal: true

module Gamba
  # Sets the values of an existing PDF's form fields, with appearances Gamba draws as it does for the fields it writes,
  # or with flatten: true, draws them into their pages and leaves no form. The source's JavaScript actions are dropped.
  class Fill < Combine
    WIDGET = PDF::Core::Name.new(value: "Widget")
    TEXT = PDF::Core::Name.new(value: "Tx")
    BUTTON = PDF::Core::Name.new(value: "Btn")
    CHOICE = PDF::Core::Name.new(value: "Ch")
    OFF = :Off
    # Annotation flag Hidden (ISO 32000-1 table 165).
    HIDDEN = 2
    # Fields within fields, at most: real forms nest a handful, crafted ones loop.
    MAX_FIELD_DEPTH = 32
    DEFAULT_SIZE = 10

    # Draws field appearances with Gamba::Forms, its objects written by the fill.
    class Appearances
      include Gamba::Forms

      def initialize(&reference)
        @reference = reference
        @fonts = {TEXT_FONT.to_sym => yield({Type: :Font, Subtype: :Type1, BaseFont: :Helvetica, Encoding: :WinAnsiEncoding}, nil)}
      end

      def ref!(data, stream = nil)
        @reference.call(data, stream)
      end

      def acro_form
        {DR: {Font: @fonts}}
      end

      def find_font(name)
        (@fonts_by_name ||= {})[name] ||= Prawn::Document.new.find_font(name)
      end

      def text(value, width, height, size, multiline:, cells:)
        text_field_appearance(value, width, height, size, multiline:, cells:)
      end

      def list(options, value, width, height, size)
        list_appearance(options, value, width, height, size)
      end

      def string(text)
        field_text(text)
      end
    end

    def initialize(values, flatten:)
      super()
      raise ArgumentError, "values is #{values.inspect}: give a Hash of field names and values" unless values.is_a?(Hash)

      @values = values.transform_keys(&:to_s)
      @flatten = flatten
    end

    private

    def copy_source(**)
      version = super
      @acro_form = @copier.copy(@reader.catalog[:AcroForm])
      @copier.finish
      @page_copies = @kids.dup
      version
    end

    def finish_catalog(root)
      form = value_of(@acro_form)
      fields = form.is_a?(Hash) ? terminal_fields(form[:Fields], "", {}, 0) : {}
      unknown = @values.keys - fields.keys
      raise ArgumentError, "this PDF has no field #{unknown.map(&:inspect).join(", ")}: its fields are #{fields.keys.inspect}" unless unknown.empty?

      @appearances = Appearances.new { |data, stream| reference(data).tap { _1.stream = stream if stream } }
      @values.each { |name, value| fill(fields.fetch(name), value) }
      fields.each_value { |field| strip_actions(field) }
      return flatten_pages if @flatten

      form[:NeedAppearances] = false if form.key?(:NeedAppearances)
      root.data[:AcroForm] = @acro_form
    end

    # By full name, each field holding a value, with what it inherits from its parents (ISO 32000-1 §12.7.3.1).
    def terminal_fields(kids, prefix, inherited, depth)
      fields = {}
      return fields if depth > MAX_FIELD_DEPTH

      Array(value_of(kids)).each do |kid|
        dictionary = value_of(kid)
        next unless dictionary.is_a?(Hash)

        partial = dictionary[:T]
        name = partial ? [prefix, partial.to_s.then { decode(_1) }].reject(&:empty?).join(".") : prefix
        own = inherited.merge(dictionary.slice(:FT, :Ff, :DA, :Opt, :MaxLen))
        children = Array(value_of(dictionary[:Kids])).select { value_of(_1).is_a?(Hash) && value_of(_1)[:T] }
        if children.empty?
          widgets = Array(value_of(dictionary[:Kids])).filter_map { value_of(_1) if value_of(_1).is_a?(Hash) }
          fields[name] = {dictionary:, widgets: widgets.empty? ? [dictionary] : widgets, **own}
        else
          fields.merge!(terminal_fields(dictionary[:Kids], name, own, depth + 1))
        end
      end
      fields
    end

    def fill(field, value)
      case field[:FT]
      when TEXT then fill_text(field, value)
      when BUTTON then fill_button(field, value)
      when CHOICE then fill_choice(field, value)
      else raise ArgumentError, "field of kind #{field[:FT].inspect} cannot be filled"
      end
    end

    def fill_text(field, value)
      flags = field[:Ff].to_i
      text = value.to_s
      field[:dictionary][:V] = @appearances.string(text)
      shown = flags.anybits?(Forms::PASSWORD) ? "*" * text.length : text
      cells = field[:MaxLen] if flags.anybits?(Forms::COMB)
      each_widget(field) do |widget, width, height|
        widget[:AP] = {N: @appearances.text(shown, width, height, font_size(field), multiline: flags.anybits?(Forms::MULTILINE), cells:)}
      end
    end

    # A check box takes true or false; radio buttons, the state of the button to turn on.
    def fill_button(field, value)
      radio = field[:Ff].to_i.anybits?(Forms::RADIO)
      states = field[:widgets].flat_map { on_states(_1) }.uniq
      state = if radio
        raise ArgumentError, "#{value.inspect} is none of the radio buttons' states, #{states.map(&:to_s).inspect}" unless states.map(&:to_s).include?(value.to_s)

        value.to_s.to_sym
      else
        value ? (states.first || :Yes) : OFF
      end
      field[:dictionary][:V] = state
      field[:widgets].each { |widget| widget[:AS] = on_states(widget).include?(state) ? state : OFF }
    end

    def fill_choice(field, value)
      options = Array(value_of(field[:Opt])).map { decode(Array(value_of(_1)).last.to_s) }
      raise ArgumentError, "#{value.inspect} is none of the options, #{options.inspect}" unless options.include?(value.to_s)

      field[:dictionary][:V] = @appearances.string(value.to_s)
      combo = field[:Ff].to_i.anybits?(Forms::COMBO)
      each_widget(field) do |widget, width, height|
        size = font_size(field)
        widget[:AP] = {N: combo ? @appearances.text(value.to_s, width, height, size, multiline: false, cells: nil) : @appearances.list(options, value.to_s, width, height, size)}
      end
    end

    def each_widget(field)
      field[:widgets].each do |widget|
        left, bottom, right, top = rectangle(widget)
        yield widget, (right - left).abs, (top - bottom).abs
      end
    end

    def on_states(widget)
      normal = value_of(value_of(widget[:AP])&.[](:N))
      (normal.is_a?(Hash) && !normal.is_a?(PDF::Core::Reference)) ? normal.keys.map(&:to_sym) - [OFF] : []
    end

    # The size of the field's default appearance, or 10 where it lets viewers choose.
    def font_size(field)
      size = field[:DA].to_s[/(\d+(?:\.\d+)?)\s+Tf/, 1].to_f
      size.positive? ? size : DEFAULT_SIZE
    end

    def strip_actions(field)
      [field[:dictionary], *field[:widgets]].each { _1.delete(:AA) }
    end

    # Each widget's appearance drawn where it sits, through the matrix that fits its box into its rectangle; the
    # widgets and the form go.
    def flatten_pages
      @page_copies.each do |page|
        annotations = value_of(page.data[:Annots])
        next unless annotations.is_a?(Array)

        widgets, others = annotations.partition { value_of(_1).is_a?(Hash) && value_of(_1)[:Subtype] == WIDGET }
        next if widgets.empty?

        drawing = +"Q\n"
        xobjects = {}
        widgets.each_with_index do |widget, index|
          dictionary = value_of(widget)
          next if dictionary[:F].to_i.anybits?(HIDDEN)

          form = appearance(dictionary)
          next unless form

          name = :"Flat#{index}"
          xobjects[name] = form
          drawing << "q\n#{PDF::Core.real_params(placement(form, rectangle(dictionary)))} cm\n/#{name} Do\nQ\n"
        end
        others.empty? ? page.data.delete(:Annots) : page.data[:Annots] = others
        resources = value_of(page.data[:Resources]).dup || {}
        resources[:XObject] = (value_of(resources[:XObject]) || {}).merge(xobjects)
        page.data[:Resources] = resources
        opening = reference({}).tap { _1.stream = +"q\n" }
        closing = reference({}).tap { _1.stream = drawing }
        page.data[:Contents] = [opening, *Array(value_of(page.data[:Contents])), closing]
      end
    end

    def appearance(widget)
      normal = value_of(value_of(widget[:AP])&.[](:N))
      normal = value_of(normal[widget[:AS].to_s.to_sym] || normal[widget[:AS]]) if normal.is_a?(Hash)
      (normal.is_a?(PDF::Core::Reference) && normal.stream?) ? normal : nil
    end

    # ISO 32000-1 §12.5.5: the form's box through its matrix, fitted into the annotation's rectangle.
    def placement(form, rectangle)
      left, bottom, right, top = Array(value_of(form.data[:BBox])).map { numeric(value_of(_1)) || 0 }
      matrix = Array(value_of(form.data[:Matrix])).map { numeric(value_of(_1)) }
      matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] unless matrix.size == 6 && matrix.all?
      corners = [[left, bottom], [right, bottom], [left, top], [right, top]].map { |x, y| apply(matrix, x, y) }
      xs, ys = corners.transpose
      width = xs.max - xs.min
      height = ys.max - ys.min
      rect_left, rect_bottom, rect_right, rect_top = rectangle
      scale_x = width.zero? ? 1.0 : (rect_right - rect_left) / width
      scale_y = height.zero? ? 1.0 : (rect_top - rect_bottom) / height
      [scale_x, 0.0, 0.0, scale_y, rect_left - (xs.min * scale_x), rect_bottom - (ys.min * scale_y)]
    end

    def rectangle(widget)
      values = Array(value_of(widget[:Rect])).map { numeric(value_of(_1)) || 0.0 }
      left, right = [values[0] || 0.0, values[2] || 0.0].minmax
      bottom, top = [values[1] || 0.0, values[3] || 0.0].minmax
      [left, bottom, right, top]
    end

    # A copied value: a reference's data, or the value itself.
    def value_of(value)
      (value.is_a?(PDF::Core::Reference) && !value.stream?) ? value.data : value
    end

    # A PDF text string as UTF-8: UTF-16 with its byte order mark, PDFDocEncoding read as Latin-1 otherwise.
    def decode(text)
      bytes = text.b
      return bytes.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8) if bytes.start_with?("\xFE\xFF".b)

      bytes.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
    end
  end
end
