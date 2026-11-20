require "rails_helper"

RSpec.describe "Sessions and push tokens (mobile reliability)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:password) { "Password!23" }
  let(:user) { create(:user, password: password, password_confirmation: password) }

  def parsed_body = JSON.parse(response.body)

  def login(u = user)
    post "/api/v1/auth/login", params: { email: u.email, password: password }.to_json, headers: json_headers
    expect(response).to have_http_status(:ok)
    parsed_body["data"]
  end

  def refresh(token)
    post "/api/v1/auth/refresh", params: { refresh_token: token }.to_json, headers: json_headers
    response.status
  end

  # ── Refresh-token rotation grace ─────────────────────────────────────────

  describe "lost rotation response" do
    it "accepts a retry with the just-rotated token within the grace window" do
      r1 = login["refresh_token"]
      expect(refresh(r1)).to eq(200) # rotation; imagine this response never arrived

      travel(10.seconds) do
        expect(refresh(r1)).to eq(200) # retry with the old token: not logged out
        expect(parsed_body.dig("data", "refresh_token")).to be_present
      end
    end

    it "rejects the rotated token after the grace window" do
      r1 = login["refresh_token"]
      refresh(r1)

      travel(Auth::RefreshTokens::ROTATION_GRACE + 1.second) do
        expect(refresh(r1)).to eq(401)
        expect(parsed_body.dig("error", "code")).to eq("auth.refresh_revoked")
      end
    end

    it "gives no grace once the replacement was revoked (logout-all / password reset)" do
      r1 = login["refresh_token"]
      refresh(r1)
      UserSession.where(user: user, revoked_at: nil).update_all(revoked_at: Time.current) # logout everywhere

      expect(refresh(r1)).to eq(401)
    end

    it "gives no grace to a token revoked by logout (not rotation)" do
      r1 = login["refresh_token"]
      post "/api/v1/auth/logout", params: { refresh_token: r1 }.to_json, headers: json_headers

      expect(refresh(r1)).to eq(401)
    end
  end

  # ── Push tokens on a shared phone ────────────────────────────────────────

  describe "POST /api/v1/me/push_tokens" do
    let(:other) { create(:user, password: password, password_confirmation: password) }
    let(:device_token) { "ExponentPushToken[shared-phone-123]" }

    def register(access_token)
      post push_path, params: { token: device_token, platform: "ios" }.to_json,
                      headers: json_headers.merge("Authorization" => "Bearer #{access_token}")
      response.status
    end

    def push_path = "/api/v1/me/push_tokens"

    it "moves the device token to whoever signs in next on the same phone" do
      expect(register(login(user)["access_token"])).to eq(204)
      expect(PushToken.find_by(token: device_token).user).to eq(user)

      expect(register(login(other)["access_token"])).to eq(204) # was a 422 before
      token = PushToken.find_by(token: device_token)
      expect(token.user).to eq(other)
      expect(token).to be_active
      expect(PushToken.where(token: device_token).count).to eq(1)
      expect(user.push_tokens.active).to be_empty # previous user's pushes no longer go to this phone
    end
  end
end
