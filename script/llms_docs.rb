# frozen_string_literal: true

# Writes docs/llms.txt (https://llmstxt.org: an index of the site for coding agents, built from each page's <title>
# and meta description) and docs/llms-full.txt (the README, then every page of docs/ but the home page, in Markdown,
# links made absolute). --check writes nothing and exits 1 if either file would change.

require "nokogiri"
require "rubygems"
require "uri"

ROOT = File.expand_path("..", __dir__)
SPEC = Gem::Specification.load(Dir[File.join(ROOT, "*.gemspec")].first)
SITE = SPEC.metadata.fetch("documentation_uri").chomp("/") + "/"
REPOSITORY = SPEC.metadata.fetch("source_code_uri")
README = File.read(File.join(ROOT, "README.md"), encoding: "UTF-8")
# The README's title as text: a logo in it (<img …>) is left out.
NAME = Nokogiri::HTML.fragment(README[/\A# (.+)$/, 1].to_s).text.strip
abort "README.md must open with a # title" if NAME.empty?
# Numbers some pages fill in from it with JavaScript: the Markdown points to it instead.
NUMBERS = File.exist?(File.join(ROOT, "docs", "benchmarks.json")) && "#{SITE}benchmarks.json"

# Relative links of the README: inline [text](path), reference [label]: path, and src="path" attributes.
RELATIVE_LINK = %r{(\]\(|^\[[^\]]+\]: +|src=")(?!https?:|mailto:|/)([^)"\s]+)}
LOADING = "Loading the latest numbers"
# What a reader of the Markdown has no use for: the site's chrome, the table of contents, images, scripts.
SKIPPED = "nav, footer, script, style, img, svg, button, .toc"
# Elements that start a block of their own; any other element is inline.
BLOCKS = %w[
  h1 h2 h3 h4 h5 h6 pre ul ol table hr p div section article header main aside figure figcaption caption blockquote
  details summary dl dt dd
].freeze

Page = Struct.new(:path, :url, :title, :description, :document)

def page(path)
  document = Nokogiri::HTML(File.read(path, encoding: "UTF-8"))
  title = document.at("title")&.text.to_s.strip
  description = document.at('meta[name="description"]')&.[]("content").to_s.strip
  abort "#{path}: a page needs a <title> and a meta description" if title.empty? || description.empty?

  name = File.basename(path)
  Page.new(path, (name == "index.html") ? SITE : "#{SITE}#{name}", title, description, document)
end

# A README link made absolute: docs/ on the website, an anchor in the README on GitHub, the rest in the repository.
def absolute(path)
  if path.start_with?("docs/") then "#{SITE}#{path.delete_prefix("docs/")}"
  elsif path.start_with?("#") then "#{REPOSITORY}#{path}"
  else "#{REPOSITORY}/blob/main/#{path.delete_prefix("./")}"
  end
end

def link(page)
  "- [#{page.title}](#{page.url}): #{page.description}"
end

# The Markdown of a node's inline content, on one line.
def inline(node, url)
  node.children.map { |child| inline_node(child, url) }.join
end

def inline_node(node, url)
  return node.text.gsub(/\s+/, " ") if node.text?
  return "" unless node.element? && !node.matches?(SKIPPED)

  text = inline(node, url)
  # A span right after another element, with nothing between them (badges, a count after a link), is told apart
  # with a dot.
  text = " · #{text}" if node.name == "span" && node.previous_sibling&.element?
  case node.name
  when "code" then code_span(node.text.gsub(/\s+/, " "))
  when "a" then node["href"] ? "[#{text.strip}](#{resolve(url, node["href"])})" : text
  when "strong", "b" then "**#{text.strip}**"
  when "em", "i" then "_#{text.strip}_"
  when "br" then " "
  else text
  end
end

def resolve(url, href)
  URI.join(url, href).to_s
rescue URI::Error => error
  abort "#{url}: cannot follow the link #{href.inspect} (#{error.message})"
end

def code_span(text)
  fence = "`" * (text.scan(/`+/).map(&:size).max.to_i + 1)
  padding = (text.start_with?("`") || text.end_with?("`")) ? " " : ""
  "#{fence}#{padding}#{text}#{padding}#{fence}"
end

# The Markdown blocks of a node, headings shifted by `shift` levels.
def blocks(node, url, shift)
  markdown_blocks = []
  line = +""
  flush = lambda do
    markdown_blocks << line.strip unless line.strip.empty?
    line = +""
  end

  node.children.each do |child|
    if child.element? && BLOCKS.include?(child.name)
      flush.call
      markdown_blocks.concat(block(child, url, shift)) unless child.matches?(SKIPPED)
    else
      line << inline_node(child, url)
    end
  end
  flush.call
  markdown_blocks
end

def block(node, url, shift)
  case node.name
  when "h1", "h2", "h3", "h4", "h5", "h6"
    level = [node.name[1].to_i + shift, 6].min
    ["#{"#" * level} #{inline(node, url).strip}"]
  when "pre"
    language = node.at("code")&.[]("class").to_s[/language-([\w-]+)/, 1]
    fence = "`" * [3, node.text.scan(/`{3,}/).map(&:size).max.to_i + 1].max
    ["#{fence}#{language}\n#{node.text.chomp}\n#{fence}"]
  when "ul", "ol" then [list(node, url, shift)]
  when "table" then table(node, url)
  when "hr" then ["---"]
  when "blockquote" then [blocks(node, url, shift).join("\n\n").gsub(/^/, "> ")]
  when "p"
    # A note a script replaces with the latest numbers once the page loads.
    return [*("The latest numbers are in [benchmarks.json](#{NUMBERS})." if NUMBERS)] if node.text.strip.start_with?(LOADING)

    blocks(node, url, shift)
  else blocks(node, url, shift)
  end
end

def list(node, url, shift)
  first = (node.name == "ol") ? node["start"].to_i.clamp(1..) : 1
  node.element_children.select { |item| item.name == "li" }.each_with_index.map do |item, index|
    marker = (node.name == "ol") ? "#{first + index}. " : "- "
    blocks(item, url, shift).join("\n\n").gsub("\n", "\n#{" " * marker.size}").gsub(/^ +$/, "").prepend(marker)
  end.join("\n")
end

# A table in Markdown; none for a table a script fills in, which has no row under its header yet.
def table(node, url)
  rows = node.css("tr").map { |row| row.css("th, td").map { |cell| inline(cell, url).strip.gsub("|", "\\|") } }
  return [] if rows.size < 2

  width = rows.map(&:size).max
  rows = rows.map { |cells| cells + [""] * (width - cells.size) }
  caption = node.at("caption")
  lines = [rows.first, ["---"] * width, *rows.drop(1)].map { |cells| "| #{cells.join(" | ")} |" }
  [*(caption && inline(caption, url).strip), lines.join("\n")]
end

# A page of docs/ in Markdown: its <title> as a level-2 heading, its own h1 dropped, its headings one level down.
def markdown(page)
  main = page.document.at("main") || page.document.at("body")
  main.css("h1").each(&:remove)
  ["## #{page.title}", "<#{page.url}>", *blocks(main, page.url, 1)].join("\n\n")
end

pages = Dir[File.join(ROOT, "docs", "*.html")].sort.map { |path| page(path) }
benchmarks, pages = pages.partition { |page| page.url.end_with?("/benchmarks.html") }
home, pages = pages.partition { |page| page.url == SITE }
optional = [
  *benchmarks.map { |page| link(page) },
  *("- [Benchmark numbers](#{NUMBERS}): the latest measurements, as JSON" if NUMBERS),
  "- [Changelog](#{REPOSITORY}/blob/main/CHANGELOG.md): what changed in each version",
  "- [Source code](#{REPOSITORY})"
]

llms = <<~MARKDOWN
  # #{NAME}

  > #{SPEC.summary}

  Install with `gem "#{SPEC.name}"` in the Gemfile.

  ## Docs

  - [Everything in one file](#{SITE}llms-full.txt): the README, then every page below but the home page, in Markdown
  #{[*home, *pages].map { |page| link(page) }.join("\n")}

  ## Optional

  #{optional.join("\n")}
MARKDOWN

# The README's relative links made absolute, outside code: a link in a code sample stays as written.
fence = nil
readme = README.sub(/\A# .+$/, "# #{NAME}").each_line.map do |line|
  if (marker = line[/\A *(`{3,}|~{3,})/, 1])
    fence = fence.nil? ? marker : (fence if !line.strip.start_with?(fence))
    next line
  end
  next line if fence

  line.split(/(`[^`\n]+`)/).each_with_index.map do |part, index|
    index.odd? ? part : part.gsub(RELATIVE_LINK) { "#{$1}#{absolute($2)}" }
  end.join
end.join
full = [readme.rstrip, *[*pages, *benchmarks].map { |page| markdown(page) }].join("\n\n") << "\n"

check = ARGV.include?("--check")
outdated = {"docs/llms.txt" => llms, "docs/llms-full.txt" => full}.reject do |name, text|
  path = File.join(ROOT, name)
  next true if File.exist?(path) && File.read(path, encoding: "UTF-8") == text

  File.write(path, text) unless check
  false
end

abort "Out of date: #{outdated.keys.join(", ")}. Run bundle exec rake docs:llms" if check && outdated.any?
puts "Wrote #{outdated.keys.join(", ")}" if outdated.any?
