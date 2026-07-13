require "rails_helper"

RSpec.describe "Well-known universal-link association files", type: :request do
  describe "GET /.well-known/apple-app-site-association" do
    it "serves the applinks payload as JSON" do
      get "/.well-known/apple-app-site-association"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      payload = JSON.parse(response.body)
      details = payload.dig("applinks", "details")
      expect(details.length).to eq(1)
      expect(details.first["appID"]).to eq(WellKnownController::IOS_APP_ID)
      expect(details.first["paths"]).to eq(["/claim/*", "/reset"])
    end
  end

  describe "GET /.well-known/assetlinks.json" do
    it "serves the Android statement with fingerprints from the environment" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ANDROID_CERT_SHA256_FINGERPRINTS")
        .and_return("AA:BB:CC, DD:EE:FF")

      get "/.well-known/assetlinks.json"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      statement = JSON.parse(response.body).first
      expect(statement["relation"]).to eq(["delegate_permission/common.handle_all_urls"])
      expect(statement["target"]).to include(
        "namespace" => "android_app",
        "package_name" => WellKnownController::ANDROID_PACKAGE,
        "sha256_cert_fingerprints" => ["AA:BB:CC", "DD:EE:FF"]
      )
    end
  end
end
