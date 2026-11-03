# frozen_string_literal: true

require "digest"
require "openssl"

module PDF
  module Core
    # The standard security handler opened with the empty user password, as viewers open a file that has only an
    # owner password: RC4 (revisions 2 to 4), AES-128 (4) and AES-256 (5, 6). ISO 32000-1 §7.6, ISO 32000-2 §7.6.4.
    class Decryption
      PADDING = Prawn::Document::Security::PASSWORD_PADDING
      IDENTITY = Name.new(value: "Identity")
      AES_128 = Name.new(value: "AESV2")
      AES_256 = Name.new(value: "AESV3")
      RC4 = Name.new(value: "V2")
      STANDARD = Name.new(value: "Standard")
      TYPE_XREF = Name.new(value: "XRef")
      TYPE_METADATA = Name.new(value: "Metadata")
      NONE = Name.new(value: "None")

      def initialize(dictionary, file_identifier, dictionary_number)
        raise Prawn::Errors::EncryptedPDF, "Unsupported security handler #{dictionary[:Filter].inspect}" unless dictionary[:Filter] == STANDARD

        @dictionary_number = dictionary_number
        @revision = Reader.integer(dictionary[:R])
        @encrypt_metadata = dictionary[:EncryptMetadata] != false
        @stream_method, @string_method = methods_for(dictionary)
        @key = (@revision >= 5) ? aes_256_key(dictionary) : rc4_era_key(dictionary, file_identifier)
      end

      def decrypt(value, number, generation)
        return value if number == @dictionary_number

        case value
        when Reader::Stream
          return value if value.dictionary[:Type] == TYPE_XREF
          data = (value.dictionary[:Type] == TYPE_METADATA && !@encrypt_metadata) ? value.data : decrypt_bytes(value.data, @stream_method, number, generation)
          Reader::Stream.new(dictionary: decrypt_strings(value.dictionary, number, generation), data:)
        else decrypt_strings(value, number, generation)
        end
      end

      private

      def methods_for(dictionary)
        case Reader.integer(dictionary[:V])
        when 1, 2 then [:rc4, :rc4]
        when 4, 5
          filters = dictionary[:CF].is_a?(Hash) ? dictionary[:CF] : {}
          [dictionary[:StmF], dictionary[:StrF]].map do |name|
            next :identity if name.nil? || name == IDENTITY

            filter = filters[name.value.to_sym]
            method = filter[:CFM] if filter.is_a?(Hash)
            case method
            when RC4 then :rc4
            when AES_128 then :aes_128
            when AES_256 then :aes_256
            when nil, NONE then :identity
            else raise Prawn::Errors::EncryptedPDF, "Unsupported crypt filter #{method.inspect}"
            end
          end
        else raise Prawn::Errors::EncryptedPDF, "Unsupported encryption version #{dictionary[:V].inspect}"
        end
      end

      def decrypt_strings(value, number, generation)
        case value
        when ByteString then ByteString.new(decrypt_bytes(value, @string_method, number, generation))
        when Array then value.map { decrypt_strings(it, number, generation) }
        when Hash then value.transform_values { decrypt_strings(it, number, generation) }
        else value
        end
      end

      def decrypt_bytes(bytes, method, number, generation)
        case method
        when :identity then bytes
        when :rc4 then Prawn::Document::Arcfour.new(object_key(number, generation, false)).encrypt(bytes)
        when :aes_128 then aes_cbc("aes-128-cbc", object_key(number, generation, true), bytes)
        when :aes_256 then aes_cbc("aes-256-cbc", @key, bytes)
        end
      end

      def object_key(number, generation, aes)
        return @key if @revision >= 5

        Prawn::Document::Security.object_key(@key, number, generation, aes ? "sAlT" : nil)
      end

      # The first 16 bytes are the initialization vector. The PKCS#7 padding is stripped by hand, as OpenSSL checks
      # it, so that a wrong one keeps the bytes as decrypted instead of failing.
      def aes_cbc(cipher_name, key, bytes)
        return "".b if bytes.bytesize < 32

        cipher = OpenSSL::Cipher.new(cipher_name).decrypt
        cipher.key = key
        cipher.iv = bytes.byteslice(0, 16)
        cipher.padding = 0
        plain = cipher.update(bytes.byteslice(16, (bytes.bytesize - 16) / 16 * 16)) + cipher.final
        padding = plain.getbyte(-1)
        (padding.between?(1, 16) && plain.end_with?(padding.chr * padding)) ? plain.byteslice(0, plain.bytesize - padding) : plain
      rescue ArgumentError, OpenSSL::Cipher::CipherError => error
        raise Prawn::Errors::MalformedPDF, "Cannot decrypt: #{error.message}"
      end

      # Algorithms 2, 4 and 5 with the empty password.
      def rc4_era_key(dictionary, file_identifier)
        length = (@revision == 2) ? 5 : Reader.integer(dictionary[:Length], 40).clamp(40, 128) / 8
        length = 16 if @stream_method == :aes_128 || @string_method == :aes_128 || (@revision == 4 && dictionary[:Length].nil?)
        seed = PADDING + dictionary[:O].to_s.b.byteslice(0, 32) + [Reader.integer(dictionary[:P])].pack("l<") + file_identifier
        seed << "\xFF\xFF\xFF\xFF".b if @revision >= 4 && !@encrypt_metadata
        key = Digest::MD5.digest(seed).byteslice(0, length)
        50.times { key = Digest::MD5.digest(key).byteslice(0, length) } if @revision >= 3
        raise Prawn::Errors::EncryptedPDF, "This PDF needs a password to open" unless user_password_valid?(key, dictionary[:U].to_s.b, file_identifier)

        key
      end

      def user_password_valid?(key, user_entry, file_identifier)
        return Prawn::Document::Arcfour.new(key).encrypt(PADDING) == user_entry if @revision == 2

        hash = Prawn::Document::Arcfour.new(key).encrypt(Digest::MD5.digest(PADDING + file_identifier))
        1.upto(19) { |round| hash = Prawn::Document::Arcfour.new(key.bytes.map { it ^ round }.pack("C*")).encrypt(hash) }
        hash == user_entry.byteslice(0, 16)
      end

      # Algorithms 2.A and 2.B: the user entry validates the empty password, then its key salt unwraps /UE.
      def aes_256_key(dictionary)
        user_entry = dictionary[:U].to_s.b
        raise Prawn::Errors::MalformedPDF, "Bad /U or /UE in the encryption dictionary" if user_entry.bytesize < 48 || dictionary[:UE].to_s.bytesize < 32
        raise Prawn::Errors::EncryptedPDF, "This PDF needs a password to open" unless hash_2b(user_entry.byteslice(32, 8)) == user_entry.byteslice(0, 32)

        cipher = OpenSSL::Cipher.new("aes-256-cbc").decrypt
        cipher.key = hash_2b(user_entry.byteslice(40, 8))
        cipher.iv = "\x00".b * 16
        cipher.padding = 0
        cipher.update(dictionary[:UE].to_s.b.byteslice(0, 32)) + cipher.final
      end

      def hash_2b(salt)
        digest = Digest::SHA256.digest(salt)
        return digest if @revision == 5

        round = 0
        loop do
          block = digest * 64
          cipher = OpenSSL::Cipher.new("aes-128-cbc").encrypt
          cipher.key = digest.byteslice(0, 16)
          cipher.iv = digest.byteslice(16, 16)
          cipher.padding = 0
          encrypted = cipher.update(block) + cipher.final
          digest = case encrypted.byteslice(0, 16).bytes.sum % 3
          when 0 then Digest::SHA256.digest(encrypted)
          when 1 then Digest::SHA384.digest(encrypted)
          else Digest::SHA512.digest(encrypted)
          end
          round += 1
          break if round >= 64 && encrypted.getbyte(-1) <= round - 32
        end
        digest.byteslice(0, 32)
      end
    end
  end
end
