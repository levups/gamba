# frozen_string_literal: true

require "digest/md5"

module Prawn
  class Document
    # The standard security handler, revision 2: 40-bit RC4 (ISO 32000-1 §7.6.3).
    module Security
      PERMISSIONS_BITS = {print_document: 3, modify_contents: 4, copy_contents: 5, modify_annotations: 6}.freeze
      FULL_PERMISSIONS = 0xFFFFFFFF
      PASSWORD_PADDING = ["28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A"].pack("H*").freeze
      KEY_LENGTH_BYTES = 5
      private_constant :PERMISSIONS_BITS, :FULL_PERMISSIONS

      def encrypt_document(options = {})
        raise Errors::PdfAViolation, "PDF/A forbids encryption" if pdf_a?

        Prawn.verify_options(%i[user_password owner_password permissions], options)
        @user_password = options.delete(:user_password) || ""
        @owner_password = options.delete(:owner_password) || @user_password
        @owner_password = Random.bytes(32) if @owner_password == :random
        self.permissions = options.delete(:permissions) || {}
        @encryption = Encryption.new(user_password: @user_password, owner_password: @owner_password, permissions: permissions_value)
      end

      def self.encrypt_string(string, key, identifier, generation)
        Arcfour.new(object_key(key, identifier, generation)).encrypt(string)
      end

      # The key of one object: the document key extended with its number and generation (algorithm 1), and with
      # "sAlT" for AES-128, which only PDF::Core::Decryption reads.
      def self.object_key(key, identifier, generation, salt = nil)
        seed = key + [identifier].pack("V")[0, 3] + [generation].pack("V")[0, 2]
        seed << salt if salt
        Digest::MD5.digest(seed)[0, key.bytesize + 5]
      end

      def self.pad_password(password)
        password = password.b[0, 32]
        password + PASSWORD_PADDING[0, 32 - password.bytesize]
      end

      private

      def permissions=(permissions = {})
        @permissions ||= FULL_PERMISSIONS
        permissions.each do |key, value|
          raise ArgumentError, "Unknown permission :#{key}. Valid options: #{PERMISSIONS_BITS.keys.map(&:inspect).join(", ")}" unless PERMISSIONS_BITS[key]

          bit = 1 << (PERMISSIONS_BITS[key] - 1)
          @permissions = value ? @permissions | bit : @permissions & ~bit
        end
      end

      def permissions_value
        @permissions || FULL_PERMISSIONS
      end
    end

    # The keys and dictionary of an encrypted document, which depend on its file identifier.
    class Encryption
      def initialize(user_password:, owner_password:, permissions:)
        @user_password = user_password
        @owner_password = owner_password
        @permissions = permissions
      end

      def owner_password_hash
        @owner_password_hash ||= begin
          key = Digest::MD5.digest(Security.pad_password(@owner_password))[0, Security::KEY_LENGTH_BYTES]
          Arcfour.new(key).encrypt(Security.pad_password(@user_password))
        end
      end

      def key(file_identifier)
        Digest::MD5.digest(Security.pad_password(@user_password) + owner_password_hash + [@permissions].pack("V") + file_identifier)[0, Security::KEY_LENGTH_BYTES]
      end

      def dictionary(file_identifier)
        user_password_hash = Arcfour.new(key(file_identifier)).encrypt(Security::PASSWORD_PADDING)
        {Filter: :Standard, V: 1, R: 2, O: PDF::Core::ByteString.new(owner_password_hash), U: PDF::Core::ByteString.new(user_password_hash),
         P: [@permissions].pack("L").unpack1("l")}
      end
    end

    # RC4, the stream cipher of the standard security handler's first revisions.
    class Arcfour
      def initialize(key)
        @state = (0..255).to_a
        j = 0
        key_bytes = key.bytes
        256.times do |i|
          j = (j + @state[i] + key_bytes[i % key_bytes.size]) & 0xFF
          @state[i], @state[j] = @state[j], @state[i]
        end
      end

      def encrypt(string)
        state = @state.dup
        i = 0
        j = 0
        string.b.bytes.map do |byte|
          i = (i + 1) & 0xFF
          j = (j + state[i]) & 0xFF
          state[i], state[j] = state[j], state[i]
          byte ^ state[(state[i] + state[j]) & 0xFF]
        end.pack("C*")
      end
    end
  end
end
