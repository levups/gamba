# frozen_string_literal: true

require_relative "pdf_check"

module Gamba
  # What an application's tests ask of its PDFs, in words of the test frameworks: Gamba::Minitest and Gamba::RSpec
  # put it in their own forms. A check whose tool is missing fails with the install command, or is skipped when
  # Gamba::Testing.missing_tools is :skip; it never passes unchecked.
  module Testing
    MISSING_TOOLS = %i[fail skip].freeze
    # Text found this many points from where it was expected is where it was expected.
    POSITION_TOLERANCE = 1

    class << self
      attr_reader :missing_tools

      def missing_tools=(choice)
        raise ArgumentError, "missing_tools is #{choice.inspect}: give :fail or :skip" unless MISSING_TOOLS.include?(choice)

        @missing_tools = choice
      end

      # nil when the text is on the page (any page unless told), else what was there instead. text: a String, whose
      # spaces match any run of them, or a Regexp; at: [x, y] of its first character's baseline, in points from the page's
      # top left, as MuPDF reads it.
      def text_failure(pdf, text, page: nil, at: nil)
        pages = PdfCheck.text_layout(pdf)
        candidates = page ? [pages[page - 1]].compact : pages
        return "the PDF has #{pages.size} pages, not #{page}" if candidates.empty?

        pattern = text.is_a?(Regexp) ? text : Regexp.new(text.split.map { Regexp.escape(_1) }.join("\\s+"))
        found = candidates.any? do |candidate|
          lines(candidate).any? do |glyphs|
            line = glyphs.map(&:first).join
            line.to_enum(:scan, pattern).any? { at.nil? || near?(glyphs[Regexp.last_match.begin(0)], at) }
          end
        end
        return nil if found

        place = page ? "page #{page}" : "the PDF"
        "#{text.inspect} is not on #{place}#{" at #{at.inspect}" if at}: it reads\n#{candidates.map { |candidate| lines(candidate).map { _1.map(&:first).join }.join("\n") }.join("\n---\n")}"
      end

      def pages_failure(expected, actual)
        differences = PdfCheck.page_differences(expected, actual)
        differences.empty? ? nil : "the pages differ:\n#{differences.join("\n")}"
      end

      def validity_failure(pdf)
        problem = PdfCheck.invalidity(pdf)
        problem && "the PDF is not valid: #{problem}"
      end

      def pdf_a_failure(pdf, flavour: "3b")
        report = PdfCheck.pdf_a_failure(pdf, flavour:)
        report && "the PDF is not PDF/A-#{flavour}:\n#{report}"
      end

      private

      def lines(page)
        page.glyphs.group_by(&:last).sort.map!(&:last)
      end

      def near?(glyph, (x, y))
        glyph && (glyph[3] - x).abs <= POSITION_TOLERANCE && (glyph[4] - y).abs <= POSITION_TOLERANCE
      end
    end

    self.missing_tools = :fail
  end
end
