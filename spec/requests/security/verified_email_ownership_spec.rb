require "rails_helper"

# Batch B: a gift reaches an account only after that account proves it owns
# the gift's email. Phone numbers are never verified (no SMS provider), so
# they must never decide who receives money.
RSpec.describe "Verified email ownership", type: :request do
  let(:json_headers) { { "Content-Type" => "application/json" } }

  def parsed_body = JSON.parse(response.body)
  def parsed_data = parsed_body["data"]
  def parsed_error = parsed_body["error"] || {}

  before do
    # Deterministic OTPs ("123455"); other SecureRandom calls behave normally.
    allow(SecureRandom).to receive(:random_number).and_call_original
    allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(123_455)
  end

  # ── Gift routing ─────────────────────────────────────────────────────────

  describe "Loads::Fulfill recipient resolution" do
    def resolve(email: nil, phone: nil)
      Loads::Fulfill.find_or_create_recipient(
        "recipient_email" => email.to_s, "recipient_phone" => phone.to_s, "recipient_name" => "Ana Pérez"
      )
    end

    it "routes to the account that owns the email, case-insensitively" do
      owner = create(:user, email: "ana@example.com")
      expect(resolve(email: " ANA@Example.com ")).to eq(owner)
    end

    it "never routes by phone: a squatter holding the number gets nothing" do
      squatter = create(:user, email: "squatter@example.com", phone: "+593990000001")

      recipient = resolve(email: "ana@example.com", phone: "+593990000001")

      expect(recipient).not_to eq(squatter)
      expect(recipient).to be_pending
      expect(recipient.email).to eq("ana@example.com")
      expect(recipient.phone).to be_nil # number already taken; shell keeps the email only
    end

    it "keeps accumulating gifts on the same pending shell" do
      first = resolve(email: "nuevo@example.com", phone: "+593990000002")
      expect(resolve(email: "nuevo@example.com", phone: "+593990000002")).to eq(first)
    end

    it "parks legacy phone-only gifts on that phone's placeholder shell, never on a real account" do
      real = create(:user, email: "real@example.com", phone: "+593990000003")

      shell = resolve(phone: "+593990000003")
      expect(shell).not_to eq(real)
      expect(shell).to be_placeholder_email
      expect(resolve(phone: "+593990000003")).to eq(shell)
    end
  end

  # ── Repeat signup on an unverified account ───────────────────────────────

  describe "repeat API signup for an email mid-verification" do
    let!(:started) do
      User.create!(email: "mid@example.com", password: "OwnerPass!23", password_confirmation: "OwnerPass!23",
                   first_name: "Owner", last_name: "Real", phone: "+593990000010",
                   require_email_verification: true)
    end

    let(:base) do
      { email: "mid@example.com", password_confirmation: nil, first_name: "X", last_name: "Y", phone: "+593990000011" }
    end

    it "refuses a different password and leaves the account untouched" do
      post "/api/v1/auth/signup", params: base.merge(password: "Attacker!23", password_confirmation: "Attacker!23").to_json,
                                  headers: json_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error.dig("details", "email")).to eq([ "has already been taken" ])
      started.reload
      expect(started.valid_password?("OwnerPass!23")).to be(true)
      expect(started.valid_password?("Attacker!23")).to be(false)
      expect(started.phone).to eq("+593990000010")
    end

    it "lets the original signer retry (same password) and re-sends the code" do
      post "/api/v1/auth/signup", params: base.merge(password: "OwnerPass!23", password_confirmation: "OwnerPass!23").to_json,
                                  headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(parsed_data["verification_required"]).to be(true)
    end
  end

  # ── Claiming a pending account ───────────────────────────────────────────

  describe "claiming a pending account" do
    def make_shell(email:, phone:)
      User.create!(name: "Maria Perez", first_name: "Maria", last_name: "Perez", email: email, phone: phone,
                   password: SecureRandom.hex(32), role: :user, pending_recipient: true, skip_national_id_validation: true)
    end

    def arm_claim_code(user)
      user.update_columns(claim_otp_digest: Digest::SHA256.hexdigest("123455"), claim_otp_sent_at: Time.current,
                          claim_otp_attempts: 0)
    end

    def claim(email:, phone:)
      post "/api/v1/auth/signup", headers: json_headers, params: {
        email: email, phone: phone, password: "Password!23", password_confirmation: "Password!23",
        first_name: "Maria", last_name: "Perez", claim_otp: "123455"
      }.to_json
    end

    it "keeps the proven address (where the code went) instead of a different typed email" do
      shell = make_shell(email: "maria@example.com", phone: "+593990000020")
      arm_claim_code(shell)

      claim(email: "someone-else@example.com", phone: "+593990000020") # matched via phone, proved maria@

      expect(response).to have_http_status(:ok)
      expect(parsed_data["access_token"]).to be_present
      shell.reload
      expect(shell.email).to eq("maria@example.com")
      expect(shell).to be_email_verified
      expect(User.where(email: "someone-else@example.com")).to be_empty
    end

    it "verifies and issues tokens when the typed email is the proven one" do
      shell = make_shell(email: "maria2@example.com", phone: "+593990000021")
      arm_claim_code(shell)

      claim(email: "Maria2@Example.com", phone: "+593990000021")

      expect(parsed_data["access_token"]).to be_present
      expect(shell.reload).to be_email_verified
    end

    it "withholds tokens when only a phone was proven (placeholder shell)" do
      shell = make_shell(email: User.placeholder_email_for_phone("+593990000022"), phone: "+593990000022")
      arm_claim_code(shell)

      claim(email: "typed@example.com", phone: "+593990000022")

      expect(response).to have_http_status(:ok)
      expect(parsed_data["verification_required"]).to be(true)
      expect(parsed_data["access_token"]).to be_nil
      expect(shell.reload).not_to be_email_verified
    end
  end

  # ── One-time code attempt counting ───────────────────────────────────────

  describe "OTP attempt counter" do
    it "persists each wrong guess and invalidates the code at the cap" do
      user = User.create!(email: "otp@example.com", password: "Password!23", password_confirmation: "Password!23",
                          first_name: "O", last_name: "T", phone: "+593990000030", require_email_verification: true)
      Auth::EmailVerification.request!(user)

      4.times do |i|
        expect { Auth::EmailVerification.verify!(User.find(user.id), "000000") }
          .to raise_error(Auth::EmailVerification::Invalid)
        expect(user.reload.email_otp_attempts).to eq(i + 1) # committed, not rolled back
      end

      expect { Auth::EmailVerification.verify!(User.find(user.id), "000000") }
        .to raise_error(Auth::EmailVerification::TooManyAttempts)
      # The code is now dead: even the right one fails until a new one is sent.
      expect { Auth::EmailVerification.verify!(User.find(user.id), "123455") }
        .to raise_error(Auth::EmailVerification::Expired)
      expect(user.reload).not_to be_email_verified
    end

    it "accepts the right code" do
      user = User.create!(email: "otp2@example.com", password: "Password!23", password_confirmation: "Password!23",
                          first_name: "O", last_name: "T", phone: "+593990000031", require_email_verification: true)
      Auth::EmailVerification.request!(user)
      expect(Auth::EmailVerification.verify!(User.find(user.id), "123455")).to be(true)
      expect(user.reload).to be_email_verified
    end
  end

  # ── Password reset ───────────────────────────────────────────────────────

  describe "API password reset" do
    it "proves the email (marks it verified) and ends every other session" do
      user = User.create!(email: "reset@example.com", password: "OldPass!23", password_confirmation: "OldPass!23",
                          first_name: "R", last_name: "S", phone: "+593990000040", require_email_verification: true)
      session = UserSession.create!(user: user, refresh_token_digest: SecureRandom.hex(32))
      raw = user.send(:set_reset_password_token)

      Auth::ResetPassword.call(reset_token: raw, password: "NewPass!234", password_confirmation: "NewPass!234")

      user.reload
      expect(user).to be_email_verified
      expect(user.valid_password?("NewPass!234")).to be(true)
      expect(session.reload.revoked_at).to be_present
    end
  end
end
