require "digest/sha256"

module JoobQ::Delivery
  # Keep scratch storage local to the call. No shared digest contexts or pooled
  # payload buffers can be reused while a handler/another fiber still owns them.
  module Checksum
    def self.hex(value : String) : String
      Digest::SHA256.new.update(value).hexfinal
    end

    def self.matches?(value : String, expected : String) : Bool
      return false unless expected.bytesize == 64
      buffer = uninitialized UInt8[64]
      Digest::SHA256.new.update(value).hexfinal(buffer.to_slice)
      buffer.to_slice == expected.to_slice
    end
  end
end
