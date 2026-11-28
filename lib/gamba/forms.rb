# frozen_string_literal: true

module Gamba
  # Interactive form fields (ISO 32000-1 §12.7): text, check boxes, radio buttons and choices a reader fills in. Each
  # widget carries its own appearance, so every viewer shows the field the same way without regenerating it; text is
  # in Helvetica, check marks in ZapfDingbats, both standard fonts. Positions are those of Prawn's boxes: at: is the
  # top left corner, in the current bounding box.
  module Forms
    # Field flags (ISO 32000-1 tables 226, 228, 230 and 231).
    MULTILINE = 1 << 12
    PASSWORD = 1 << 13
    COMB = 1 << 24
    NO_TOGGLE_TO_OFF = 1 << 14
    RADIO = 1 << 15
    COMBO = 1 << 17
    EDIT = 1 << 18
    # Annotation flag 3, Print.
    PRINT = 4
    PADDING = 2
    BORDER = "0.5 0.5 0.5 RG"
    TEXT_FONT = "Helv"
    CHECK_FONT = "ZaDb"
    # ZapfDingbats' check mark, ✔, and bullet, ●.
    CHECK = "4"
    BULLET = "l"

    # A text field: one line, or multiline: true; password: true shows asterisks; comb: true spreads max_length
    # characters over as many cells. value is the text shown and sent.
    def text_field(name, at:, width:, height:, value: nil, size: 10, multiline: false, password: false, comb: false, max_length: nil)
      raise ArgumentError, "comb needs max_length, the number of cells" if comb && !max_length
      raise ArgumentError, "value is longer than max_length, #{max_length}" if value && max_length && value.length > max_length

      flags = (multiline ? MULTILINE : 0) | (password ? PASSWORD : 0) | (comb ? COMB : 0)
      field = {FT: :Tx, Ff: flags, DA: text_appearance_setting(size), MaxLen: max_length}
      field[:V] = field_text(value) if value && !password
      shown = password ? value && ("*" * value.length) : value
      add_field(name, at, width, height, field) do |form_width, form_height|
        text_field_appearance(shown, form_width, form_height, size, multiline:, cells: comb && max_length)
      end
    end

    # A check box, ticked when checked: true, sending "Yes" then.
    def check_box(name, at:, size: 12, checked: false)
      state = checked ? :Yes : :Off
      add_field(name, at, size, size, {FT: :Btn, V: state, AS: state, DA: PDF::Core::LiteralString.new("/#{CHECK_FONT} 0 Tf 0 g"), MK: {CA: PDF::Core::LiteralString.new(CHECK)}}) do |width, height|
        {Yes: mark_appearance(CHECK, width, height), Off: box_appearance(width, height)}
      end
    end

    # Radio buttons sharing one name, one per value at its top left corner, the one of selected on: choosing one
    # turns the others off.
    def radio_buttons(name, buttons:, size: 12, selected: nil)
      raise ArgumentError, "buttons is #{buttons.inspect}: give each value its top left corner, {\"yes\" => [x, y]}" unless buttons.is_a?(Hash) && !buttons.empty?
      raise ArgumentError, "selected is #{selected.inspect}: one of #{buttons.keys.inspect}" unless selected.nil? || buttons.key?(selected)

      check_forms_allowed
      parent = ref!(FT: :Btn, Ff: RADIO | NO_TOGGLE_TO_OFF, T: field_text(name), V: selected ? selected.to_s.to_sym : :Off, Kids: [])
      buttons.each do |value, corner|
        state = value.to_s.to_sym
        widget = form_widget(corner, size, size, Parent: parent, AS: (value == selected) ? state : :Off, MK: {CA: PDF::Core::LiteralString.new(BULLET)})
        widget.data[:AP] = {N: {state => mark_appearance(BULLET, size, size, round: true), :Off => box_appearance(size, size, round: true)}}
        parent.data[:Kids] << widget
      end
      acro_form[:Fields] << parent
      parent
    end

    # A list of options to choose one from: a dropdown, or a list box with list: true. value is the option chosen.
    def choice_field(name, at:, width:, height:, options:, value: nil, size: 10, list: false)
      raise ArgumentError, "options is #{options.inspect}: give an Array of Strings" unless options.is_a?(Array) && !options.empty? && options.all?(String)
      raise ArgumentError, "value is #{value.inspect}: one of the options" unless value.nil? || options.include?(value)

      field = {FT: :Ch, Ff: list ? 0 : COMBO, Opt: options.map { field_text(_1) }, DA: text_appearance_setting(size)}
      field[:V] = field_text(value) if value
      add_field(name, at, width, height, field) do |form_width, form_height|
        list ? list_appearance(options, value, form_width, form_height, size) : text_field_appearance(value, form_width, form_height, size)
      end
    end

    private

    def check_forms_allowed
      raise Prawn::Errors::PdfAViolation, "Gamba writes no form fields under PDF/A yet: leave them out, or fill them in as text" if pdf_a?
      raise tagging_violation, "#{tagging_standard} tags form fields as Form elements, which Gamba does not do yet: leave them out" if tagged?
    end

    # The field and its widget in one dictionary, its appearance the block's: a form, or forms by state.
    def add_field(name, corner, width, height, field)
      raise ArgumentError, "name is #{name.inspect}: give a non-empty String" unless name.is_a?(String) && !name.empty?

      check_forms_allowed
      widget = form_widget(corner, width, height, T: field_text(name), **field.compact)
      appearance = yield(width, height)
      widget.data[:AP] = {N: appearance}
      acro_form[:Fields] << widget
      widget
    end

    def form_widget(corner, width, height, **entries)
      x, y = corner
      left = x + bounds.absolute_left
      top = y + bounds.absolute_bottom
      widget = ref!(Type: :Annot, Subtype: :Widget, Rect: [left, top - height, left + width, top], F: PRINT, P: page.dictionary, **entries)
      (page.dictionary.data[:Annots] ||= []) << widget
      widget
    end

    # The document's form: its fields, and the fonts their appearances and readers' edits use.
    def acro_form
      @acro_form ||= begin
        fonts = {TEXT_FONT.to_sym => ref!(Type: :Font, Subtype: :Type1, BaseFont: :Helvetica, Encoding: :WinAnsiEncoding),
                 CHECK_FONT.to_sym => ref!(Type: :Font, Subtype: :Type1, BaseFont: :ZapfDingbats)}
        form = {Fields: [], DR: {Font: fonts}, DA: PDF::Core::LiteralString.new("/#{TEXT_FONT} 0 Tf 0 g")}
        @root.data[:AcroForm] = ref!(form)
        form
      end
    end

    def text_appearance_setting(size)
      PDF::Core::LiteralString.new("/#{TEXT_FONT} #{PDF::Core.real(size)} Tf 0 g")
    end

    # Text as PDF strings take it: PDFDocEncoding where it fits, UTF-16 otherwise.
    def field_text(text)
      text = text.to_s
      return PDF::Core::LiteralString.new(text) if text.ascii_only?

      PDF::Core::ByteString.new("\xFE\xFF".b + text.encode(::Encoding::UTF_16BE).b)
    end

    def form_xobject(width, height, content, fonts: {})
      resources = fonts.empty? ? {} : {Font: fonts}
      ref!({Type: :XObject, Subtype: :Form, BBox: [0, 0, width, height], Resources: resources}, content)
    end

    def form_helvetica
      @form_helvetica ||= find_font("Helvetica")
    end

    def form_fonts(name)
      {name.to_sym => acro_form[:DR][:Font][name.to_sym]}
    end

    # The value's text, Windows-1252 as Helvetica draws it: a character outside raises rather than show nothing.
    def form_text(text)
      form_helvetica.normalize_encoding(text.to_s)
    rescue Prawn::Errors::IncompatibleStringEncoding
      raise Prawn::Errors::IncompatibleStringEncoding, "#{text.inspect} has characters Helvetica, the form fields' font, cannot draw"
    end

    def text_field_appearance(value, width, height, size, multiline: false, cells: nil)
      content = "#{BORDER}\n0.5 0.5 #{PDF::Core.real(width - 1)} #{PDF::Core.real(height - 1)} re S\n/Tx BMC\n"
      if value && !value.empty?
        text = form_text(value)
        content << "q\n1 1 #{PDF::Core.real(width - 2)} #{PDF::Core.real(height - 2)} re W n\nBT\n/#{TEXT_FONT} #{PDF::Core.real(size)} Tf 0 g\n"
        if cells
          cell = width.to_f / cells
          text.each_char.with_index do |character, index|
            x = (cell * index) + ((cell - form_helvetica.compute_width_of(character, size:)) / 2)
            content << "1 0 0 1 #{PDF::Core.real(x)} #{PDF::Core.real(form_baseline(height, size))} Tm\n#{form_string(character)} Tj\n"
          end
        elsif multiline
          leading = size * 1.15
          content << "#{PDF::Core.real(leading)} TL\n#{PADDING} #{PDF::Core.real(height - PADDING - size)} Td\n"
          form_lines(text, width - (2 * PADDING), size).each_with_index { |line, index| content << (index.zero? ? "" : "T*\n") << "#{form_string(line)} Tj\n" }
        else
          content << "#{PADDING} #{PDF::Core.real(form_baseline(height, size))} Td\n#{form_string(text)} Tj\n"
        end
        content << "ET\nQ\n"
      end
      content << "EMC\n"
      form_xobject(width, height, content, fonts: form_fonts(TEXT_FONT))
    end

    def list_appearance(options, value, width, height, size)
      content = "#{BORDER}\n0.5 0.5 #{PDF::Core.real(width - 1)} #{PDF::Core.real(height - 1)} re S\n/Tx BMC\nq\n1 1 #{PDF::Core.real(width - 2)} #{PDF::Core.real(height - 2)} re W n\n"
      leading = size * 1.15
      options.each_with_index do |option, index|
        top = height - PADDING - (leading * index)
        break if top - leading < 0

        if option == value
          content << "0.6 0.75 0.9 rg\n1 #{PDF::Core.real(top - leading)} #{PDF::Core.real(width - 2)} #{PDF::Core.real(leading)} re f\n"
        end
        content << "BT\n/#{TEXT_FONT} #{PDF::Core.real(size)} Tf 0 g\n#{PADDING} #{PDF::Core.real(top - size)} Td\n#{form_string(form_text(option))} Tj\nET\n"
      end
      content << "Q\nEMC\n"
      form_xobject(width, height, content, fonts: form_fonts(TEXT_FONT))
    end

    # A check mark or a dot drawn as paths, which no viewer lacks a font for.
    def mark_appearance(mark, width, height, round: false)
      content = +form_border(width, height, round)
      if mark == CHECK
        points = [[0.22, 0.52], [0.42, 0.3], [0.78, 0.74]].map { |x, y| "#{PDF::Core.real(x * width)} #{PDF::Core.real(y * height)}" }
        content << "0 G\n#{PDF::Core.real([width, height].min * 0.12)} w\n1 J\n1 j\n#{points[0]} m\n#{points[1]} l\n#{points[2]} l\nS\n"
      else
        content << "0 g\n" << form_circle(width / 2.0, height / 2.0, [width, height].min * 0.25) << "f\n"
      end
      form_xobject(width, height, content)
    end

    def box_appearance(width, height, round: false)
      form_xobject(width, height, form_border(width, height, round))
    end

    def form_border(width, height, round)
      return "#{BORDER}\n0.5 0.5 #{PDF::Core.real(width - 1)} #{PDF::Core.real(height - 1)} re S\n" unless round

      "#{BORDER}\n#{form_circle(width / 2.0, height / 2.0, ([width, height].min - 1) / 2.0)}S\n"
    end

    def form_circle(center_x, center_y, radius)
      kappa = radius * 0.5523
      [
        "#{PDF::Core.real(center_x + radius)} #{PDF::Core.real(center_y)} m",
        form_curve(center_x + radius, center_y + kappa, center_x + kappa, center_y + radius, center_x, center_y + radius),
        form_curve(center_x - kappa, center_y + radius, center_x - radius, center_y + kappa, center_x - radius, center_y),
        form_curve(center_x - radius, center_y - kappa, center_x - kappa, center_y - radius, center_x, center_y - radius),
        form_curve(center_x + kappa, center_y - radius, center_x + radius, center_y - kappa, center_x + radius, center_y)
      ].join("\n") + "\n"
    end

    def form_curve(*points)
      "#{points.map { PDF::Core.real(_1) }.join(" ")} c"
    end

    # The baseline that centres a line of Helvetica in the field's height.
    def form_baseline(height, size)
      (height - (size * 0.72)) / 2
    end

    def form_lines(text, width, size)
      text.split(/\r\n|\r|\n/, -1).flat_map do |paragraph|
        words = paragraph.split(" ")
        next [+""] if words.empty?

        words.each_with_object([+""]) do |word, lines|
          candidate = lines.last.empty? ? word : "#{lines.last} #{word}"
          if form_helvetica.compute_width_of(candidate, size:) <= width || lines.last.empty?
            lines[-1] = candidate
          else
            lines << word
          end
        end
      end
    end

    def form_string(text)
      PDF::Core.serialize(PDF::Core::LiteralString.new(text.b))
    end
  end
end
