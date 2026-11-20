# Parses a money amount typed into a form ("19.99", "19,99", "$5") into
# integer cents. Never goes through Float: `"19.99".to_f * 100` is
# 1998.9999999999998, which `.to_i` truncated to 1998 (a lost cent).
#
# Returns nil for anything that isn't a plain non-negative amount with at most
# two decimals (no thousands separators), so callers can show a clear error
# instead of silently charging a different amount.
module MoneyInput
  FORMAT = /\A\d{1,7}(?:[.,]\d{1,2})?\z/

  def self.to_cents(value)
    text = value.to_s.strip.delete_prefix("$").strip
    return nil unless text.match?(FORMAT)

    (BigDecimal(text.tr(",", ".")) * 100).to_i
  end
end
