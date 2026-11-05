# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Turns inline markup (<b>, <i>, <u>, <strikethrough>, <sub>, <sup>, <link>, <a>, <color>, <font>, <br>)
      # into formatted text arrays, and back.
      class Parser
        PARSER_REGEX = Regexp.new(
          "\n|<b>|</b>|<i>|</i>|<u>|</u>|<strikethrough>|</strikethrough>|<sub>|</sub>|<sup>|</sup>|<link[^>]*>|</link>|" \
          "<color[^>]*>|</color>|<font[^>]*>|</font>|<strong>|</strong>|<em>|</em>|<a[^>]*>|</a>|[^<\n]+",
          Regexp::MULTILINE
        )
        ESCAPE_CHARS = {"&" => "&amp;", ">" => "&gt;", "<" => "&lt;"}.freeze
        UNESCAPE_CHARS = ESCAPE_CHARS.invert.freeze
        CMYK_ATTRIBUTES = %w[c m y k].freeze
        ESCAPE_PATTERN = Regexp.union(ESCAPE_CHARS.keys)
        UNESCAPE_PATTERN = Regexp.union(UNESCAPE_CHARS.keys)
        STYLE_BY_OPENING_TAG = {
          "<b>" => :bold, "<strong>" => :bold, "<i>" => :italic, "<em>" => :italic, "<u>" => :underline,
          "<strikethrough>" => :strikethrough, "<sub>" => :subscript, "<sup>" => :superscript
        }.freeze
        STYLE_BY_CLOSING_TAG = STYLE_BY_OPENING_TAG.transform_keys { _1.sub("<", "</") }.freeze
        PREFIX_BY_STYLE = {bold: "<b>", italic: "<i>", underline: "<u>", strikethrough: "<strikethrough>", subscript: "<sub>", superscript: "<sup>"}.freeze
        SUFFIX_BY_STYLE = PREFIX_BY_STYLE.transform_values { _1.sub("<", "</") }.freeze

        def self.format(string, *_arguments)
          array_from_tokens(string.gsub(%r{<br\s*/?>}, "\n").scan(PARSER_REGEX))
        end

        def self.to_string(array)
          array.map do |hash|
            prefix = +""
            suffix = +""
            hash[:styles]&.each do |style|
              prefix << PREFIX_BY_STYLE[style]
              suffix = SUFFIX_BY_STYLE[style] + suffix
            end
            font = (" name='#{hash[:font]}'" if hash[:font])
            size = (" size='#{hash[:size]}'" if hash[:size])
            character_spacing = (" character_spacing='#{hash[:character_spacing]}'" if hash[:character_spacing])
            if font || size || character_spacing
              prefix << "<font#{font}#{size}#{character_spacing}>"
              suffix = "</font>"
            end
            link = (" href='#{hash[:link]}'" if hash[:link])
            anchor = (" anchor='#{hash[:anchor]}'" if hash[:anchor])
            if link || anchor
              prefix << "<link#{link}#{anchor}>"
              suffix = "</link>"
            end
            if hash[:color]
              prefix <<
                if hash[:color].is_a?(Array)
                  c, m, y, k = hash[:color]
                  "<color c='#{c}' m='#{m}' y='#{y}' k='#{k}'>"
                else
                  "<color rgb='#{hash[:color]}'>"
                end
              suffix = "</color>"
            end
            prefix + escape(hash[:text]) + suffix
          end.join
        end

        def self.array_paragraphs(array)
          paragraphs = []
          paragraph = []
          previous_string = "\n"
          array.each do |hash|
            hash[:text].scan(/[^\n]+|\n/).each do |string|
              if string == "\n"
                paragraph << hash.merge(text: "\n") if previous_string == "\n"
                paragraphs << paragraph unless paragraph.empty?
                paragraph = []
              else
                paragraph << hash.merge(text: string)
              end
              previous_string = string
            end
          end
          paragraphs << paragraph unless paragraph.empty?
          paragraphs
        end

        def self.array_from_tokens(tokens)
          array = []
          styles = []
          colors = []
          link = nil
          anchor = nil
          local = nil
          fonts = []
          sizes = []
          character_spacings = []
          tokens.each do |token|
            if (style = STYLE_BY_OPENING_TAG[token])
              styles << style
            elsif (style = STYLE_BY_CLOSING_TAG[token])
              styles.delete(style)
            else
              case token
              when "</link>", "</a>"
                link = anchor = local = nil
              when "</color>"
                colors.pop
              when "</font>"
                fonts.pop
                sizes.pop
                character_spacings.pop
              when /^<link[^>]*>$/, /^<a[^>]*>$/
                link = attribute(token, "href") || link
                anchor = attribute(token, "anchor") || anchor
                local = attribute(token, "local") || local
              when /^<color[^>]*>$/
                rgb = attribute(token, "rgb", hash_prefixed: true)
                colors << rgb if rgb
                cmyk = CMYK_ATTRIBUTES.map { |name| attribute(token, name, hash_prefixed: true)&.then { |value| Integer(value, 10) } }
                colors << cmyk if cmyk.all?
              when /^<font[^>]*>$/
                attribute(token, "name")&.then { fonts << _1 }
                attribute(token, "size")&.then { sizes << Float(_1) }
                attribute(token, "character_spacing")&.then { character_spacings << Float(_1) }
              else
                array << {
                  text: unescape(token), styles: styles.dup, color: colors.last, local:, link:, anchor:,
                  font: fonts.last, size: sizes.last, character_spacing: character_spacings.last
                }
              end
            end
          end
          array
        end

        def self.attribute(token, name, hash_prefixed: false)
          prefix = hash_prefixed ? "#?" : ""
          token[/\b#{name}="#{prefix}([^"]*)"/, 1] || token[/\b#{name}='#{prefix}([^']*)'/, 1]
        end

        def self.escape(text)
          text.gsub(ESCAPE_PATTERN, ESCAPE_CHARS)
        end

        def self.unescape(text)
          text.gsub(UNESCAPE_PATTERN, UNESCAPE_CHARS)
        end
      end
    end
  end
end
