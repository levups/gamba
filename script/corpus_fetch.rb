# frozen_string_literal: true

require "fileutils"
require "net/http"
require "tmpdir"
require "yaml"

CACHE_DIRECTORY = File.expand_path("../corpus/cache", __dir__)

def download(url, destination)
  response = Net::HTTP.get_response(URI(url))
  response = Net::HTTP.get_response(URI(response["location"])) while response.is_a?(Net::HTTPRedirection)
  response.value
  File.binwrite(destination, response.body)
end

YAML.load_file(File.expand_path("../corpus/manifest.yml", __dir__)).each do |name, source|
  directory = File.join(CACHE_DIRECTORY, name)
  stamp = File.join(directory, ".commit")
  next puts("#{name}: up to date") if File.exist?(stamp) && File.read(stamp) == source.fetch("commit")

  Dir.mktmpdir do |download_directory|
    archive = File.join(download_directory, "source.tar.gz")
    download("https://codeload.github.com/#{source.fetch("repository")}/tar.gz/#{source.fetch("commit")}", archive)
    system("tar", "-xzf", archive, "-C", download_directory, "--strip-components=1", exception: true)

    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)
    source.fetch("keep").each { FileUtils.mv(File.join(download_directory, _1), directory) }
  end
  File.write(stamp, source.fetch("commit"))
  puts "#{name}: #{source.fetch("commit")}"
end
