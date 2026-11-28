# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require_relative "../../lib/gamba/pdf_check"

# The objects of a PDF as qpdf's JSON gives them, streams decoded.
class PdfObjects
  # The operators that start painting: a text object, a path, an image, a shading.
  PAINTING = /(?:\A|\s)(?:BT|BI|Do|m|re|sh)\z/
  def initialize(pdf)
    json = Gamba::PdfCheck.with_path(pdf) do |path|
      Open3.capture2("qpdf", "--json=2", "--json-stream-data=inline", "--decode-level=generalized", path).first
    end
    @objects = JSON.parse(json).fetch("qpdf").last
  end

  def value(reference)
    return reference unless reference.is_a?(String) && reference.end_with?(" R")

    object = @objects.fetch("obj:#{reference}")
    object["value"] || object.dig("stream", "dict")
  end

  def stream(reference)
    Base64.decode64(@objects.fetch("obj:#{reference}").dig("stream", "data"))
  end

  # Every object of this type, whether or not anything refers to it.
  def of_type(type)
    @objects.each_value.filter_map { _1["value"] || _1.dig("stream", "dict") }.grep(Hash).select { _1["/Type"] == type }
  end

  def catalog
    value(value(@objects.fetch("trailer")["value"]["/Root"]))
  end

  def pages
    value(catalog["/Pages"])["/Kids"]
  end

  def content(page)
    Array(value(page)["/Contents"]).sum("") { stream(_1) }
  end

  # The parent tree's arrays by key: the element of each MCID of a page.
  def parent_tree
    value(value(catalog["/StructTreeRoot"])["/ParentTree"])["/Nums"].each_slice(2).to_h
  end

  # What breaks the marked content of a tagged PDF, nil when nothing does: something painted outside any
  # sequence, a sequence closed on no page or left open, an artifact inside tagged content, MCIDs not numbered from 0 on a page, or a page whose parent tree entry
  # does not hold one element for each.
  def marked_content_problem
    tree = parent_tree
    pages.each_with_index do |page, index|
      open = []
      mcids = []
      content(page).each_line(chomp: true) do |line|
        if line.end_with?("BDC", "BMC")
          artifact = line.start_with?("/Artifact")
          return "page #{index + 1}: an artifact inside tagged content" if artifact && open.include?(:tagged)

          open << (artifact ? :artifact : :tagged)
          mcids << Integer(line[/MCID (\d+)/, 1]) unless artifact
        elsif line == "EMC"
          return "page #{index + 1}: EMC closes no sequence" unless open.pop
        elsif open.empty? && line.match?(PAINTING)
          return "page #{index + 1}: #{line.inspect} painted outside any sequence"
        end
      end
      return "page #{index + 1}: #{open.size} sequences left open" unless open.empty?
      return "page #{index + 1}: MCIDs #{mcids}" unless mcids == (0...mcids.size).to_a
      next if mcids.empty?

      held = tree.fetch(value(page)["/StructParents"], []).size
      return "page #{index + 1}: #{mcids.size} MCIDs, #{held} elements in the parent tree" unless held == mcids.size
    end
    nil
  end
end
