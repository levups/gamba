# frozen_string_literal: true

module Gamba
  module PdfA
    # An ICC version 2 display profile for sRGB (IEC 61966-2.1), built from the standard's primaries adapted to D50
    # (ICC.1:2001-04): PDF/A needs one as output intent, and building it avoids shipping a third-party file.
    module SrgbProfile
      DESCRIPTION = "sRGB IEC61966-2.1"
      D50_WHITE = [0.9642, 1.0, 0.8249].freeze
      # sRGB primaries, Bradford-adapted from D65 to D50.
      RED = [0.4361, 0.2225, 0.0139].freeze
      GREEN = [0.3851, 0.7169, 0.0971].freeze
      BLUE = [0.1431, 0.0606, 0.7141].freeze
      # The sRGB tone curve, approximated by a 2.2 gamma, as u8Fixed8Number.
      GAMMA = 0x0233

      module_function

      def bytes
        @bytes ||= begin
          curve = "curv".b + "\x00" * 4 + [1, GAMMA].pack("Nn") + "\x00\x00".b
          tags = [
            ["desc", text_description(DESCRIPTION)],
            ["cprt", "text".b + ("\x00" * 4) + "No copyright, use freely\x00".b],
            ["wtpt", xyz(D50_WHITE)],
            ["rXYZ", xyz(RED)], ["gXYZ", xyz(GREEN)], ["bXYZ", xyz(BLUE)],
            ["rTRC", curve], ["gTRC", curve], ["bTRC", curve]
          ]
          table_size = 4 + (tags.size * 12)
          offset = 128 + table_size
          directory = [tags.size].pack("N")
          data = +"".b
          tags.each do |signature, tag|
            directory << [signature, offset + data.bytesize, tag.bytesize].pack("a4N2")
            data << tag << ("\x00" * ((4 - (tag.bytesize % 4)) % 4))
          end
          body = directory + data
          header(128 + body.bytesize) + body
        end
      end

      def header(size)
        [size, "", 0x02100000, "mntr", "RGB ", "XYZ ", 2026, 1, 1, 0, 0, 0, "acsp", "APPL", 0, "", "", 0, 0,
          *D50_WHITE.map { s15_fixed16(_1) }, ""].pack("N a4 N a4 a4 a4 n6 a4 a4 N a4 a4 Q> N N3 a4") + ("\x00" * 44)
      end

      def xyz(values)
        "XYZ ".b + ("\x00" * 4) + values.map { s15_fixed16(_1) }.pack("N3")
      end

      def s15_fixed16(value)
        (value * 65_536).round & 0xFFFFFFFF
      end

      def text_description(text)
        ascii = "#{text}\x00".b
        "desc".b + ("\x00" * 4) + [ascii.bytesize].pack("N") + ascii + [0, 0, 0].pack("N2n") + ("\x00" * 67)
      end
    end
  end
end
