require "rails_helper"

# Signup flow for claiming a pending recipient account (created when a gift
# card was sent to an email/phone with no account). Claiming now requires an
# OTP delivered to the pending account's existing contact channels, so an
# attacker who merely knows the recipient's email or phone can no longer
# take over their waiting gift cards.
RSpec.describe "Pending account claim verification", type: :request do
  let(:json_headers) { { "Content-Type" => "application/json" } }

  let(:pending_email) { "maria.pending@example.com" }
  let(:pending_phone) { "+593991234567" }

  let!(:pending_user) do
    User.create!(
      name: "Maria Perez",
      first_name: "Maria",
      last_name: "Perez",
      email: pending_email,
      phone: pending_phone,
      password: SecureRandom.hex(32),
      role: :user,
      pending_recipient: true,
      skip_national_id_validation: true
    )
  end

  let!(:waiting_gift_card) { create(:gift_card, recipient: pending_user) }

  let(:signup_params) do
    {
      email: pending_email,
      password: "Password!23",
      password_confirmation: "Password!23",
      first_name: "Maria",
      last_name: "Perez",
      phone: pending_phone
    }
  end

  # Mock the Twilio transport (SMS/WhatsApp).
  let(:twilio_messages) { double("twilio_messages") }
  let(:twilio_client) { double("twilio_client", messages: twilio_messages) }

  before do
    allow(Messaging::TwilioConfig).to receive(:enabled?).and_return(true)
    allow(Messaging::TwilioConfig).to receive(:client).and_return(twilio_client)
    allow(Messaging::TwilioConfig).to receive(:from_number).and_return("+15550001111")
    allow(Messaging::TwilioConfig).to receive(:whatsapp_number).and_return("+15550002222")
    allow(twilio_messages).to receive(:create).and_return(double(sid: "SM123"))

    # Deterministic OTP: SecureRandom.random_number(1_000_000) => 123455,
    # formatted as "123455". Other SecureRandom calls behave normally.
    allow(SecureRandom).to receive(:random_number).and_call_original
    allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(123_455)
  end

  def post_signup(params)
    post "/api/v1/auth/signup", params: params.to_json, headers: json_headers
  end

  def parsed_body = JSON.parse(response.body)
  def parsed_data = parsed_body["data"]
  def parsed_error = parsed_body["error"] || {}

  describe "pending match without claim_otp" do
    it "responds 409, stores the OTP digest, delivers to both channels, and does NOT claim" do
      expect do
        post_signup(signup_params)
      end.not_to change(User, :count)

      expect(response).to have_http_status(:conflict)
      expect(parsed_error["code"]).to eq("auth.claim_verification_required")
      expect(parsed_error["details"]["channels"]).to match_array(%w[email whatsapp])
      expect(parsed_error["details"]["masked_email"]).to eq("m•••@example.com")
      expect(parsed_error["details"]["masked_phone"]).to eq("+593•••4567")

      pending_user.reload
      expect(pending_user.claimed_at).to be_nil
      expect(pending_user.claim_otp_digest).to eq(Digest::SHA256.hexdigest("123455"))
      expect(pending_user.claim_otp_sent_at).to be_within(5.seconds).of(Time.current)
      expect(pending_user.claim_otp_attempts).to eq(0)

      # WhatsApp OTP went out through the mocked transport with the code.
      expect(twilio_messages).to have_received(:create).with(
        hash_including(to: "whatsapp:#{pending_phone}", body: include("123455"))
      )
      # Email OTP enqueued.
      expect(enqueued_mailer_jobs("claim_otp").size).to eq(1)
    end

    it "falls back to SMS when WhatsApp delivery fails" do
      allow(twilio_messages).to receive(:create) do |args|
        if args[:from].to_s.start_with?("whatsapp:")
          raise Twilio::REST::RestError.new("boom", double(status_code: 400, body: {}, headers: {}))
        end
        double(sid: "SM123")
      end

      post_signup(signup_params)

      expect(response).to have_http_status(:conflict)
      expect(parsed_error["details"]["channels"]).to match_array(%w[email sms])
      expect(twilio_messages).to have_received(:create).with(
        hash_including(to: pending_phone, body: include("123455"))
      )
    end

    it "skips email for placeholder-email (phone-only) pending users" do
      pending_user.update_columns(email: User.placeholder_email_for_phone(pending_phone))

      post_signup(signup_params.merge(email: "real.address@example.com"))

      expect(response).to have_http_status(:conflict)
      expect(parsed_error["details"]["channels"]).to eq(%w[whatsapp])
      expect(parsed_error["details"]).not_to have_key("masked_email")
      expect(enqueued_mailer_jobs("claim_otp")).to be_empty
    end

    it "throttles resends within 60 seconds but still responds 409 with retry_in_seconds" do
      post_signup(signup_params)
      first_digest = pending_user.reload.claim_otp_digest
      first_sent_at = pending_user.claim_otp_sent_at

      expect(twilio_messages).to have_received(:create).once

      post_signup(signup_params)

      expect(response).to have_http_status(:conflict)
      expect(parsed_error["code"]).to eq("auth.claim_verification_required")
      expect(parsed_error["details"]["retry_in_seconds"]).to be_between(1, 60)
      expect(parsed_error["details"]["channels"]).to match_array(%w[email whatsapp])

      pending_user.reload
      expect(pending_user.claim_otp_digest).to eq(first_digest)
      expect(pending_user.claim_otp_sent_at).to eq(first_sent_at)
      # No second delivery attempt.
      expect(twilio_messages).to have_received(:create).once
    end

    it "resends a fresh OTP after the throttle window" do
      post_signup(signup_params)
      pending_user.reload.update_columns(claim_otp_sent_at: 61.seconds.ago)

      post_signup(signup_params)

      expect(response).to have_http_status(:conflict)
      expect(parsed_error["details"]).not_to have_key("retry_in_seconds")
      expect(twilio_messages).to have_received(:create).twice
    end
  end

  describe "pending match with correct claim_otp" do
    before { post_signup(signup_params) } # issue the challenge

    it "claims the account, returns tokens, and keeps gift cards on the same user id" do
      users_before = User.count
      expect do
        post_signup(signup_params.merge(claim_otp: "123455"))
      end.to change(UserSession, :count).by(1)
      expect(User.count).to eq(users_before)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["access_token"]).to be_present
      expect(parsed_data["refresh_token"]).to be_present
      expect(parsed_data["expires_in"]).to be > 0

      pending_user.reload
      expect(pending_user.claimed_at).to be_present
      expect(pending_user.claim_otp_digest).to be_nil
      expect(pending_user.claim_otp_sent_at).to be_nil
      expect(pending_user.claim_otp_attempts).to eq(0)

      expect(waiting_gift_card.reload.recipient_id).to eq(pending_user.id)
    end

    it "notifies the original contact channels that the account was claimed" do
      post_signup(signup_params.merge(claim_otp: "123455"))

      expect(response).to have_http_status(:ok)
      # SMS/WhatsApp claimed-notice to the original phone.
      expect(twilio_messages).to have_received(:create).with(
        hash_including(to: "whatsapp:#{pending_phone}", body: include("activada"))
      )
      # Email claimed-notice to the original email address.
      expect(enqueued_mailer_jobs("account_claimed").size).to eq(1)
      # Welcome email still goes out on claim (other users created by
      # factories enqueue their own, so match on the claimed user's id).
      welcome_for_claimed = enqueued_mailer_jobs("welcome").select do |job|
        job[:args].to_s.include?(pending_user.id.to_s)
      end
      expect(welcome_for_claimed.size).to eq(1)
    end
  end

  describe "pending match with wrong claim_otp" do
    before { post_signup(signup_params) } # issue the challenge

    it "responds 422 with attempts_remaining and does not claim" do
      post_signup(signup_params.merge(claim_otp: "000000"))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.claim_otp_invalid")
      expect(parsed_error["details"]["attempts_remaining"]).to eq(4)

      pending_user.reload
      expect(pending_user.claimed_at).to be_nil
      expect(pending_user.claim_otp_attempts).to eq(1)
    end

    it "invalidates the code after 5 failed attempts, forcing a resend" do
      4.times do |i|
        post_signup(signup_params.merge(claim_otp: "000000"))
        expect(parsed_error["code"]).to eq("auth.claim_otp_invalid")
        expect(parsed_error["details"]["attempts_remaining"]).to eq(4 - i)
      end

      post_signup(signup_params.merge(claim_otp: "000000"))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.claim_otp_expired")

      pending_user.reload
      expect(pending_user.claim_otp_digest).to be_nil
      expect(pending_user.claimed_at).to be_nil

      # Even the correct code no longer works — a resend is required.
      post_signup(signup_params.merge(claim_otp: "123455"))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.claim_otp_expired")
    end
  end

  describe "expired claim_otp" do
    it "responds 422 auth.claim_otp_expired" do
      post_signup(signup_params)
      pending_user.reload.update_columns(claim_otp_sent_at: 11.minutes.ago)

      post_signup(signup_params.merge(claim_otp: "123455"))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.claim_otp_expired")
      expect(pending_user.reload.claimed_at).to be_nil
    end

    it "treats a claim_otp without any issued challenge as expired" do
      post_signup(signup_params.merge(claim_otp: "123455"))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.claim_otp_expired")
    end
  end

  describe "signup without a pending match" do
    it "creates a brand-new user with no OTP challenge" do
      fresh_params = signup_params.merge(
        email: "fresh.user@example.com",
        phone: "+593987654321"
      )

      expect do
        post_signup(fresh_params)
      end.to change(User, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["access_token"]).to be_present

      new_user = User.find_by(email: "fresh.user@example.com")
      expect(new_user.claimed_at).to be_present
      expect(new_user.claim_otp_digest).to be_nil
    end
  end

  # ActiveJob-enqueued mailer deliveries filtered by mailer method name.
  def enqueued_mailer_jobs(method_name)
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      job[:args].is_a?(Array) && job[:args].second == method_name
    end
  end
end
