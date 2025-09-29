class CodeGenerator
  # Generate a 12-character uppercase base32 code (no 0/O/I/1)
  # Format: REM-XXXX-XXXX-XXXX
  def self.generate
    # Base32 alphabet without confusing characters (0, O, I, 1)
    alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    
    # Generate 12 random characters
    code_chars = 12.times.map { alphabet[rand(alphabet.length)] }.join
    
    # Format as REM-XXXX-XXXX-XXXX
    "REM-#{code_chars[0..3]}-#{code_chars[4..7]}-#{code_chars[8..11]}"
  end

  # Generate both raw code and digest
  def self.generate_with_digest
    raw_code = generate
    digest = BCrypt::Password.create(raw_code)
    [raw_code, digest]
  end
end
