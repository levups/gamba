# frozen_string_literal: true

module PDF::Core
  # What a PDF `q` saves and `Q` restores, as far as Gamba writes it.
  class GraphicState
    UNDASHED = {dash: nil, space: nil, phase: 0}.freeze
    # The text state parameters Prawn sets, with their defaults, in the order a new page writes them back; each
    # state records them as last written in it.
    DEFAULT_TEXT_STATE = {text_rendering_mode: :fill, character_spacing: 0, word_spacing: 0, horizontal_text_scaling: 100, rise: 0}.freeze
    TEXT_STATE_WRITERS = DEFAULT_TEXT_STATE.to_h { |setting, _default| [setting, :"#{setting}="] }.freeze

    attr_accessor :color_space, :dash, :cap_style, :join_style, :line_width, :fill_color, :stroke_color,
      *DEFAULT_TEXT_STATE.keys
    # What Prawn's state leaves out: the pattern painting in place of each colour since a gradient was set, and the
    # blend mode's ExtGState, {name:, reference:} each, nil for none and for Normal.
    attr_accessor :fill_pattern, :stroke_pattern, :blend_mode
    # The save that opened this state on its page, or that it was reopened for on a new page; a copy has none.
    attr_accessor :save

    def initialize(previous_state = nil)
      if previous_state
        @color_space = previous_state.color_space.dup
        @fill_color = previous_state.fill_color.dup
        @stroke_color = previous_state.stroke_color.dup
        @dash = previous_state.dash.dup
        @cap_style = previous_state.cap_style
        @join_style = previous_state.join_style
        @line_width = previous_state.line_width
        @fill_pattern = previous_state.fill_pattern
        @stroke_pattern = previous_state.stroke_pattern
        @blend_mode = previous_state.blend_mode
        copy_text_state(previous_state)
      else
        @color_space = {}
        @fill_color = "000000"
        @stroke_color = "000000"
        @dash = UNDASHED.dup
        @cap_style = :butt
        @join_style = :miter
        @line_width = 1
        reset_text_state
      end
    end

    # The text state recorded in another state, the default one for nil.
    def copy_text_state(other)
      return reset_text_state unless other

      @text_rendering_mode = other.text_rendering_mode
      @character_spacing = other.character_spacing
      @word_spacing = other.word_spacing
      @horizontal_text_scaling = other.horizontal_text_scaling
      @rise = other.rise
    end

    def reset_text_state
      @text_rendering_mode = :fill
      @character_spacing = 0
      @word_spacing = 0
      @horizontal_text_scaling = 100
      @rise = 0
    end

    # What fills or strokes: the pattern's name, else the colour.
    def fill_paint
      fill_pattern ? fill_pattern[:name] : fill_color
    end

    def stroke_paint
      stroke_pattern ? stroke_pattern[:name] : stroke_color
    end

    def dup
      GraphicState.new(self)
    end

    def dash_setting
      return "[] 0 d" unless dash[:dash]

      lengths = dash[:dash].is_a?(Array) ? dash[:dash] : [dash[:dash], dash[:space]]
      "[#{PDF::Core.real_params(lengths)}] #{PDF::Core.real(dash[:phase])} d"
    end
  end
end
