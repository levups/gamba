# frozen_string_literal: true

require "digest/md5"
require "openssl"
require "securerandom"

module Prawn
  class Document
    # The standard security handler: 40-bit RC4 by default (revision 2, ISO 32000-1 §7.6.3), or AES-256
    # (revision 6, ISO 32000-2 §7.6.4) with algorithm: :aes_256.
    module Security
      PERMISSIONS_BITS = {print_document: 3, modify_contents: 4, copy_contents: 5, modify_annotations: 6}.freeze
      FULL_PERMISSIONS = 0xFFFFFFFF
      PASSWORD_PADDING = ["28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A"].pack("H*").freeze
      KEY_LENGTH_BYTES = 5
      private_constant :PERMISSIONS_BITS, :FULL_PERMISSIONS

      def encrypt_document(options = {})
        raise Errors::PdfAViolation, "PDF/A forbids encryption" if pdf_a?

        Prawn.verify_options(%i[user_password owner_password permissions algorithm], options)
        algorithm = options.delete(:algorithm) || :rc4_40
        encryption_class = case algorithm
        when :rc4_40 then Encryption
        when :aes_256 then Aes256Encryption
        else raise ArgumentError, "algorithm is #{algorithm.inspect}: encrypt_document takes :rc4_40 or :aes_256"
        end
        @user_password = options.delete(:user_password) || ""
        @owner_password = options.delete(:owner_password) || @user_password
        @owner_password = SecureRandom.bytes(32) if @owner_password == :random
        self.permissions = options.delete(:permissions) || {}
        @encryption = encryption_class.new(user_password: @user_password, owner_password: @owner_password, permissions: permissions_value)
        declare_extension_level_8 if encryption_class == Aes256Encryption
      end

      def self.encrypt_string(string, key, identifier, generation)
        Arcfour.new(object_key(key, identifier, generation)).encrypt(string)
      end

      # Algorithm 2.B (ISO 32000-2 §7.6.4.3.4): the hash of a password for revision 6, salted, and for the owner
      # password also keyed by the user entry.
      def self.hash_2b(password, salt, user_entry = "".b)
        digest = Digest::SHA256.digest(password + salt + user_entry)
        round = 0
        loop do
          cipher = OpenSSL::Cipher.new("aes-128-cbc").encrypt
          cipher.key = digest.byteslice(0, 16)
          cipher.iv = digest.byteslice(16, 16)
          cipher.padding = 0
          encrypted = cipher.update((password + digest + user_entry) * 64) + cipher.final
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

      # Revision 6 came as Adobe's extension level 8 to PDF 1.7, before ISO 32000-2 made it part of PDF 2.0.
      def declare_extension_level_8
        min_version(1.7)
        @root.data[:Extensions] = {ADBE: {BaseVersion: :"1.7", ExtensionLevel: 8}}
      end

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

      # Mixed into the file identifier, which is written in clear: without it, anyone holding the template could
      # check guesses at the encrypted content against the identifier. The /U and /O entries already let a password
      # guess be checked, so this tells nothing more about the passwords.
      def identifier_secret
        Security.pad_password(@user_password) + Security.pad_password(@owner_password)
      end

      def key(file_identifier)
        Digest::MD5.digest(Security.pad_password(@user_password) + owner_password_hash + [@permissions].pack("V") + file_identifier)[0, Security::KEY_LENGTH_BYTES]
      end

      def dictionary(file_identifier)
        user_password_hash = Arcfour.new(key(file_identifier)).encrypt(Security::PASSWORD_PADDING)
        {Filter: :Standard, V: 1, R: 2, O: PDF::Core::ByteString.new(owner_password_hash), U: PDF::Core::ByteString.new(user_password_hash),
         P: [@permissions].pack("L").unpack1("l")}
      end

      def encrypt(bytes, key, identifier)
        Security.encrypt_string(bytes, key, identifier, 0)
      end
    end

    # Revision 6 of the standard security handler: AES-256 with the file key itself (ISO 32000-2 §7.6.4). The key,
    # salts and initialization vectors come from an HMAC of the passwords and the file identifier, so the same
    # document gives the same bytes, and nobody without a password can tell them from random ones.
    class Aes256Encryption
      # Bits 1 and 2 are reserved and must be 0 (ISO 32000-2 table 22).
      RESERVED_PERMISSIONS = 0b11
      ZERO_IV = ("\x00" * 16).b.freeze

      def initialize(user_password:, owner_password:, permissions:)
        @user_password = password_bytes(user_password)
        @owner_password = password_bytes(owner_password)
        @permissions = permissions & ~RESERVED_PERMISSIONS
      end

      def identifier_secret
        Digest::SHA256.digest("#{@user_password}\0#{@owner_password}")
      end

      def key(file_identifier)
        derived(file_identifier, "key")
      end

      def dictionary(file_identifier)
        file_key = key(file_identifier)
        user_entry = password_entry(@user_password, file_identifier, "user")
        owner_entry = password_entry(@owner_password, file_identifier, "owner", user_entry)
        {Filter: :Standard, V: 5, R: 6, Length: 256, CF: {StdCF: {AuthEvent: :DocOpen, CFM: :AESV3, Length: 32}}, StmF: :StdCF, StrF: :StdCF,
         U: byte_string(user_entry), UE: byte_string(wrapped_key(@user_password, user_entry, file_key)),
         O: byte_string(owner_entry), OE: byte_string(wrapped_key(@owner_password, owner_entry, file_key, user_entry)),
         P: [@permissions].pack("L").unpack1("l"), Perms: byte_string(permissions_entry(file_key, file_identifier)), EncryptMetadata: true}
      end

      # Each string and stream: its initialization vector, then its bytes in AES-256-CBC with PKCS#7 padding.
      def encrypt(bytes, key, identifier)
        iv = OpenSSL::HMAC.digest("SHA256", key, [identifier].pack("N") + bytes).byteslice(0, 16)
        cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
        cipher.key = key
        cipher.iv = iv
        iv + cipher.update(bytes) + cipher.final
      end

      private

      # SASLprep leaves ASCII as it is, and is left out; 127 bytes is the limit revision 6 hashes.
      def password_bytes(password)
        password.to_s.encode(::Encoding::UTF_8).b.byteslice(0, 127)
      rescue ::Encoding::UndefinedConversionError
        password.to_s.b.byteslice(0, 127)
      end

      def derived(file_identifier, purpose)
        OpenSSL::HMAC.digest("SHA256", "#{@user_password}\0#{@owner_password}", file_identifier + purpose)
      end

      # Algorithm 8 (user) or 9 (owner): the password's hash, its validation salt and its key salt.
      def password_entry(password, file_identifier, purpose, user_entry = "".b)
        salts = derived(file_identifier, "#{purpose} salts").byteslice(0, 16)
        Security.hash_2b(password, salts.byteslice(0, 8), user_entry) + salts
      end

      # The file key encrypted with the hash of the password and its key salt, /UE or /OE.
      def wrapped_key(password, entry, file_key, user_entry = "".b)
        cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
        cipher.key = Security.hash_2b(password, entry.byteslice(40, 8), user_entry)
        cipher.iv = ZERO_IV
        cipher.padding = 0
        cipher.update(file_key) + cipher.final
      end

      # Algorithm 10: the permissions, encrypted so that a reader can check nobody changed /P; ECB, as it asks, on one block.
      def permissions_entry(file_key, file_identifier)
        block = [@permissions].pack("l<") + "\xFF\xFF\xFF\xFFTadb".b + derived(file_identifier, "perms").byteslice(0, 4)
        cipher = OpenSSL::Cipher.new("aes-256-ecb").encrypt
        cipher.key = file_key
        cipher.padding = 0
        cipher.update(block) + cipher.final
      end

      def byte_string(bytes)
        PDF::Core::ByteString.new(bytes)
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
