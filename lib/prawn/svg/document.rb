require "tempfile"

class Prawn::SVG::Document
  Error = Class.new(StandardError)
  InvalidSVGData = Class.new(Error)

  DEFAULT_FALLBACK_FONT_NAME = "Times-Roman".freeze
  # Gamba: limits a crafted SVG would otherwise exceed to hang the process. Elements drawn again through <use>,
  # counted over the whole document: two <use> of the level below, sixteen levels deep, draw 65,536 copies.
  MAXIMUM_ELEMENTS_THROUGH_USE = 20_000
  # Elements inside one another: deeper, Ruby's stack runs out, and REXML resolves each namespace by its ancestors.
  MAXIMUM_DEPTH = 256

  class << self
    attr_accessor :enable_web_requests_warned
  end

  # An +Array+ of warnings that occurred while parsing the SVG data.
  attr_reader :warnings

  attr_reader :root,
    :sizing,
    :fallback_font_name,
    :font_registry,
    :url_loader,
    :elements_by_id, :gradients,
    :element_styles,
    :color_mode,
    :external_svg_cache

  def initialize(data, bounds, options, font_registry: nil, css_parser: CssParser::Parser.new, attribute_overrides: {})
    begin
      @root = REXML::Document.new(data).root or raise_parse_error(data)
    rescue REXML::ParseException => e
      raise_parse_error(data, e.message)
    rescue RuntimeError => e
      # Gamba: REXML's entity expansion limits raise a bare RuntimeError.
      raise InvalidSVGData, "The data supplied is not a valid SVG document: #{e.message}"
    end
    check_tree!(@root)

    @warnings = []
    @options = options
    @elements_by_id = {}
    @element_index_by_root = {}.compare_by_identity
    @elements_through_use = 0
    @references_in_use = []
    @depth = 0
    @gradients = Prawn::SVG::Gradients.new(self)
    @external_svg_cache = {}
    @fallback_font_name = options.fetch(:fallback_font_name, DEFAULT_FALLBACK_FONT_NAME)
    @font_registry = font_registry
    @color_mode = load_color_mode
    @font_face_tempfiles = []

    @url_loader = Prawn::SVG::UrlLoader.new(
      enable_cache: options[:cache_images],
      # Gamba: no web request unless asked for, since an SVG could otherwise make the server fetch any URL.
      enable_web: options.fetch(:enable_web_requests, false),
      enable_file_with_root: options[:enable_file_requests_with_root]
    )

    attributes = @root.attributes.dup
    attribute_overrides.each { |key, value| attributes.add(REXML::Attribute.new(key, value)) }

    @sizing = Prawn::SVG::Calculators::DocumentSizing.new(bounds, attributes)
    calculate_sizing(requested_width: options[:width], requested_height: options[:height])

    stylesheets = Prawn::SVG::CSS::Stylesheets.new(css_parser, root, url_loader:, warnings:)
    @element_styles = stylesheets.load
    process_font_face_rules(stylesheets.font_face_rules)

    yield self if block_given?
  end

  # Gamba: the first element of root, in document order, whose id is id. Read once into a hash per root, where
  # prawn-svg built an XPath query from the id: an id holding a quote injected XPath, and each reference to a
  # missing id scanned the whole document.
  def self.element_by_id(root, id, cache = nil)
    index = cache ? (cache[root] ||= element_index(root)) : element_index(root)
    index[id]
  end

  def self.element_index(root)
    index = {}
    index[root.attributes["id"]] = root if root.attributes["id"]
    root.each_recursive { |element| (id = element.attributes["id"]) && (index[id] ||= element) }
    index
  end

  def raw_element_by_id(id, root = @root)
    self.class.element_by_id(root, id, @element_index_by_root)
  end

  # Gamba: the elements a <use> draws, unless it draws one of its own ancestors or the document has drawn too many.
  def drawing_through_use(source)
    raise Prawn::SVG::Elements::Base::SkipElementError, "use tag references an element that contains it" if @references_in_use.any? { _1.equal?(source) }

    @elements_through_use += 1
    source.each_recursive { @elements_through_use += 1 }
    raise Prawn::SVG::Elements::Base::SkipElementError, "use tags draw more than #{MAXIMUM_ELEMENTS_THROUGH_USE} elements" if @elements_through_use > MAXIMUM_ELEMENTS_THROUGH_USE

    @references_in_use << source
    yield
  ensure
    @references_in_use.pop if @references_in_use.last.equal?(source)
  end

  # Gamba: walked without recursion, before anything else walks the tree with it. Texts expand their entities
  # here, so that REXML's limits on expansion raise InvalidSVGData rather than a RuntimeError mid-render.
  def check_tree!(root)
    level = [root]
    MAXIMUM_DEPTH.times do
      level.each { |element| element.texts.each(&:value) }
      level = level.flat_map { _1.elements.to_a }
      return if level.empty?
    end
    raise InvalidSVGData, "The SVG document nests elements deeper than #{MAXIMUM_DEPTH} levels"
  rescue RuntimeError => e
    raise InvalidSVGData, "The data supplied is not a valid SVG document: #{e.message}"
  end

  # Gamba: one level further down the tree, unless that is too deep.
  def nested
    raise Prawn::SVG::Elements::Base::SkipElementError, "elements nested deeper than #{MAXIMUM_DEPTH} levels" if @depth >= MAXIMUM_DEPTH

    @depth += 1
    begin
      yield
    ensure
      @depth -= 1
    end
  end

  def calculate_sizing(requested_width: nil, requested_height: nil)
    sizing.requested_width = requested_width
    sizing.requested_height = requested_height
    sizing.calculate
  end

  def with_sizing(temporary_sizing)
    original = @sizing
    @sizing = temporary_sizing
    yield
  ensure
    @sizing = original
  end

  private

  def process_font_face_rules(rules)
    return unless font_registry

    rules.each do |declarations|
      decl_hash = {}
      declarations.each { |name, value, _| decl_hash[name] = value }

      family = unquote_css_string(decl_hash["font-family"])
      next unless family

      src = decl_hash["src"]
      next unless src

      weight = decl_hash["font-weight"]
      style = decl_hash["font-style"]
      stretch = decl_hash["font-stretch"]

      load_font_face_source(family, weight, style, stretch, src)
    end
  end

  def load_font_face_source(family, weight, style, stretch, src)
    sources = Prawn::SVG::CSS::FontFaceParser.parse_src(src)

    sources.detect do |source|
      case source[:type]
      when :local
        load_local_font_face(family, weight, style, stretch, source[:name])
      when :url
        load_url_font_face(family, weight, style, stretch, source)
      end
    end
  end

  def load_local_font_face(family, weight, style, stretch, local_name)
    font_data = font_registry.find_local_font_data(local_name, weight, style, stretch)
    return unless font_data

    font_registry.register_font_face(family, weight, style, stretch, font_data)
    true
  end

  def load_url_font_face(family, weight, style, stretch, source)
    return if source[:format] && !Prawn::SVG::CSS::FontFaceParser::SUPPORTED_FORMATS.include?(source[:format])

    data = url_loader.load(source[:url])
    tempfile = Tempfile.new(["prawn-svg-font", ".ttf"])
    tempfile.binmode
    tempfile.write(data)
    tempfile.close
    @font_face_tempfiles << tempfile

    font_registry.register_font_face(family, weight, style, stretch, tempfile.path)
    true
  rescue Prawn::SVG::UrlLoader::Error => e
    warnings << "Failed to load @font-face font from #{source[:url]}: #{e.message}"
    false
  end

  def unquote_css_string(value)
    return unless value

    value = value.strip
    if (value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'"))
      value[1..-2]
    else
      value
    end
  end

  def load_color_mode
    case @options[:color_mode]
    when nil, :rgb then :rgb
    when :cmyk then :cmyk
    else
      raise ArgumentError, ":color_mode must be set to :rgb (default) or :cmyk"
    end
  end

  def raise_parse_error(data, exception_message = nil)
    message = "The data supplied is not a valid SVG document."

    if data.respond_to?(:end_with?) && data.end_with?(".svg")
      message += "  It looks like you've supplied a filename instead; use File.read(filename) to get the data from the file before you pass it to prawn-svg."
    end

    message += "\n#{exception_message}" if exception_message

    raise InvalidSVGData, message
  end
end
