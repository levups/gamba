# frozen_string_literal: true

# Sample images and fonts corrupted from a seed: flipped bytes, truncations, and lengths overwritten where
# parsers trust them.
class CorruptInputs
  def initialize(seed)
    @random = Random.new(seed)
  end

  def corrupt(bytes)
    bytes = bytes.b.dup
    case @random.rand(4)
    when 0 then bytes.byteslice(0, @random.rand(bytes.bytesize))
    when 1
      @random.rand(1..20).times { bytes.setbyte(@random.rand(bytes.bytesize), @random.rand(256)) }
      bytes
    when 2
      position = @random.rand([bytes.bytesize - 4, 1].max)
      bytes[position, 4] = [[0xFFFFFFFF, 0x7FFFFFFF, 0, 0x10000, @random.rand(2**32)].sample(random: @random)].pack("N")
      bytes
    else
      position = @random.rand([bytes.bytesize - 2, 1].max)
      bytes[position, 2] = [[0xFFFF, 0, 0x8000, @random.rand(2**16)].sample(random: @random)].pack("n")
      bytes
    end
  end
end
