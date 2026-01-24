# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/checkout/payment_intent", type: :request do
  let(:password) { "Password!23" }
  let(:user) do
    create(:user,
           password: password,
           address: "123 Main St",
           country_of_residence: "PE",
           date_of_birth: Date.new(1990, 1, 1))
  end
  let(:merchant) { create(:merchant) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  let(:valid_params) do
    {
      merchant_id: merchant.id,
      amount_cents: 2500,
      currency: "USD",
      recipient: {
        name: "John Doe",
        email: "recipient@example.com",
        phone: "+15551234567",
        note: "Happy birthday!"
      }
    }
  end

  describe "authentication" do
    it "returns 401 when Authorization header is missing" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: json_headers

      expect(response).to have_http_status(:unauthorized)
      expect(parsed_error["code"]).to eq("auth.missing_token")
    end

    it "returns 401 when token is invalid" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers("invalid_token")

      expect(response).to have_http_status(:unauthorized)
      expect(parsed_error["code"]).to eq("auth.invalid_token")
    end
  end

  describe "validation errors" do
    it "returns 422 when merchant_id is invalid (non-numeric)" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(merchant_id: "abc").to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("invalid_merchant")
    end

    it "returns 422 when merchant does not exist" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(merchant_id: 999_999).to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("invalid_merchant")
    end

    it "returns 422 when amount is zero" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(amount_cents: 0).to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("invalid_amount")
    end

    it "returns 422 when amount is below minimum ($1.00)" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(amount_cents: 50).to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("invalid_amount")
      expect(parsed_error["message"]).to include("at least $1.00")
    end

    it "returns 422 when amount exceeds maximum ($200)" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(amount_cents: 25_000).to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("invalid_amount")
    end

    it "returns 422 when recipient has neither email nor phone" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(recipient: { name: "John" }).to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("invalid_recipient")
    end

    it "returns 422 when KYC is incomplete" do
      user.update!(address: nil, country_of_residence: nil)

      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("kyc_incomplete")
    end
  end

  describe "successful payment intent creation" do
    before do
      # Mock Stripe to avoid real API calls in tests
      allow(Stripe::PaymentIntent).to receive(:create).and_return(
        double(
          id: "pi_test_123456",
          client_secret: "pi_test_123456_secret_abc",
          last_response: double(request_id: "req_test_789")
        )
      )
    end

    it "returns 200 with client_secret and payment_intent_id for valid payload" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["client_secret"]).to eq("pi_test_123456_secret_abc")
      expect(parsed_data["payment_intent_id"]).to eq("pi_test_123456")
      expect(parsed_body["request_id"]).to be_present
    end

    it "passes correct parameters to Stripe including metadata" do
      expect(Stripe::PaymentIntent).to receive(:create).with(
        hash_including(
          amount: 2500,
          currency: "usd",
          payment_method_types: ["card"],
          metadata: hash_including(
            sender_id: user.id.to_s,
            merchant_id: merchant.id.to_s,
            recipient_email: "recipient@example.com",
            recipient_phone: "+15551234567",
            recipient_name: "John Doe"
          )
        ),
        hash_including(:idempotency_key)
      ).and_return(
        double(
          id: "pi_test_123456",
          client_secret: "pi_test_123456_secret_abc",
          last_response: double(request_id: "req_test_789")
        )
      )

      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:ok)
    end

    it "accepts recipient with only email (no phone)" do
      params_email_only = valid_params.merge(
        recipient: { name: "Jane", email: "jane@example.com" }
      )

      post "/api/v1/checkout/payment_intent",
           params: params_email_only.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:ok)
    end

    it "accepts recipient with only phone (no email)" do
      params_phone_only = valid_params.merge(
        recipient: { name: "Jane", phone: "+15559876543" }
      )

      post "/api/v1/checkout/payment_intent",
           params: params_phone_only.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "idempotency key generation" do
    before do
      allow(Stripe::PaymentIntent).to receive(:create).and_return(
        double(
          id: "pi_test_123456",
          client_secret: "pi_test_123456_secret_abc",
          last_response: double(request_id: "req_test_789")
        )
      )
    end

    it "uses draft_id when provided for idempotency" do
      expect(Stripe::PaymentIntent).to receive(:create).with(
        anything,
        hash_including(idempotency_key: "mobile_pi:draft:my-draft-uuid-123")
      ).and_return(
        double(
          id: "pi_test_123456",
          client_secret: "pi_test_123456_secret_abc",
          last_response: nil
        )
      )

      post "/api/v1/checkout/payment_intent",
           params: valid_params.merge(draft_id: "my-draft-uuid-123").to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:ok)
    end

    it "generates deterministic idempotency key for same inputs within time bucket" do
      captured_keys = []

      allow(Stripe::PaymentIntent).to receive(:create) do |_params, options|
        captured_keys << options[:idempotency_key]
        double(
          id: "pi_test_123456",
          client_secret: "pi_test_123456_secret_abc",
          last_response: nil
        )
      end

      # First request
      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      # Second request with same params (simulating retry)
      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      # Both should use the same idempotency key (within same 10-min bucket)
      expect(captured_keys.first).to eq(captured_keys.second)
      expect(captured_keys.first).to start_with("mobile_pi:")
    end
  end

  describe "Stripe error handling" do
    it "returns 500 with safe error message when Stripe fails" do
      allow(Stripe::PaymentIntent).to receive(:create).and_raise(
        Stripe::APIError.new("Internal Stripe error")
      )

      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:internal_server_error)
      expect(parsed_error["code"]).to eq("payment_error")
      expect(parsed_error["message"]).to eq("Unable to process payment. Please try again.")
      # Should not leak Stripe error details
      expect(response.body).not_to include("Internal Stripe error")
    end
  end

  describe "purchase limit" do
    before do
      # Create 5 gift cards in the last 24 hours
      5.times do
        create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago)
      end
    end

    it "returns 422 when user has reached 24h purchase limit" do
      post "/api/v1/checkout/payment_intent",
           params: valid_params.to_json,
           headers: auth_headers(access_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("purchase_limit_exceeded")
    end
  end

  # Helper methods

  def access_token
    @access_token ||= begin
      post "/api/v1/auth/login",
           params: { email: user.email, password: password }.to_json,
           headers: json_headers

      JSON.parse(response.body).dig("data", "access_token")
    end
  end

  def parsed_body
    JSON.parse(response.body)
  end

  def parsed_data
    parsed_body["data"] || {}
  end

  def parsed_error
    parsed_body["error"] || {}
  end

  def auth_headers(token)
    json_headers.merge("Authorization" => "Bearer #{token}")
  end
end
