# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "socket"

# An SVG names URLs: rendering it must not make the server fetch them unless the caller says so.
class SvgSecurityTest < Minitest::Test
  def test_an_svg_does_not_reach_the_web_by_default
    connections = connections_while_rendering do |port|
      data = image_svg(port)
      Prawn::Document.new { svg data }.render
    end

    assert_equal 0, connections
  end

  def test_web_requests_stay_available_on_request
    connections = connections_while_rendering do |port|
      data = image_svg(port)
      Prawn::Document.new { svg data, enable_web_requests: true }.render
    end

    assert_operator connections, :>, 0
  end

  private

  def image_svg(port)
    %(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">) +
      %(<image xlink:href="http://127.0.0.1:#{port}/image.png" width="10" height="10"/></svg>)
  end

  def connections_while_rendering
    server = TCPServer.new("127.0.0.1", 0)
    connections = 0
    acceptor = Thread.new do
      loop do
        server.accept.close
        connections += 1
      end
    rescue IOError
      nil
    end
    yield server.addr[1]
    connections
  ensure
    server&.close
    acceptor&.join(1)
  end
end
