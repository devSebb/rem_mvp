require "rails_helper"

# Production traffic is client -> Cloudflare -> Render LB (private IP) -> Puma.
# These specs simulate that hop chain to prove (a) the real client IP is
# recovered, (b) it can't be spoofed, and (c) Rack::Attack keys on it.
RSpec.describe "Client IP resolution and throttling", type: :request do
  RENDER_LB = "10.0.0.5".freeze
  CF_EDGE_A = "172.71.150.252".freeze
  CF_EDGE_B = "104.22.160.25".freeze

  def via_cloudflare(client_ip, edge: CF_EDGE_A, extra: {})
    { "REMOTE_ADDR" => RENDER_LB, "HTTP_X_FORWARDED_FOR" => "#{client_ip}, #{edge}" }.merge(extra)
  end

  before { Rack::Attack.reset! }
  after  { Rack::Attack.reset! }

  describe "Rack::Request#ip (used by Rack::Attack)" do
    def rack_ip(env)
      Rack::Request.new(Rack::MockRequest.env_for("/", env)).ip
    end

    it "skips Cloudflare edges and returns the real client" do
      expect(rack_ip(via_cloudflare("203.0.113.9"))).to eq("203.0.113.9")
    end

    it "uses the address Cloudflare appended, not one the client prepended" do
      env = via_cloudflare("203.0.113.9").merge("HTTP_X_FORWARDED_FOR" => "1.2.3.4, 203.0.113.9, #{CF_EDGE_A}")
      expect(rack_ip(env)).to eq("203.0.113.9")
    end

    it "ignores a spoofed RFC 7239 Forwarded header" do
      expect(rack_ip(via_cloudflare("203.0.113.9", extra: { "HTTP_FORWARDED" => "for=198.51.100.77" }))).to eq("203.0.113.9")
      expect(rack_ip(via_cloudflare("203.0.113.9", extra: { "HTTP_FORWARDED" => "for=127.0.0.1" }))).to eq("203.0.113.9")
    end
  end

  describe "request.remote_ip (logs, UserSession#ip)" do
    it "is configured in the app's RemoteIp middleware to trust Cloudflare" do
      remote_ip_mw = Rails.application.middleware.find { |m| m.klass == ActionDispatch::RemoteIp }
      trusted = remote_ip_mw.args.last
      expect(trusted).to include(*CloudflareIps::RANGES)

      env = Rack::MockRequest.env_for("/", via_cloudflare("203.0.113.9"))
      ActionDispatch::RemoteIp.new(->(_) { [200, {}, []] }, true, trusted).call(env)
      expect(ActionDispatch::Request.new(env).remote_ip).to eq("203.0.113.9")
    end
  end

  describe "Rack::Attack keyed on the real client" do
    def request_reset(client_ip, edge: CF_EDGE_A, extra: {})
      post user_password_path,
           params: { user: { email: "nobody-#{SecureRandom.hex(4)}@example.com" } },
           env: via_cloudflare(client_ip, edge: edge, extra: extra)
      response.status
    end

    it "throttles one client even when its requests arrive via different Cloudflare edges" do
      statuses = 6.times.map { |i| request_reset("198.51.100.10", edge: i.even? ? CF_EDGE_A : CF_EDGE_B) }
      expect(statuses.first(5)).not_to include(429)
      expect(statuses.last).to eq(429)
    end

    it "does not throttle a different client that shares the same Cloudflare edge" do
      5.times { request_reset("198.51.100.10") }
      expect(request_reset("198.51.100.10")).to eq(429)
      expect(request_reset("198.51.100.11")).not_to eq(429)
    end

    it "can't be bypassed by rotating a spoofed Forwarded header" do
      statuses = 6.times.map { |i| request_reset("198.51.100.12", extra: { "HTTP_FORWARDED" => "for=203.0.113.#{i}" }) }
      expect(statuses.last).to eq(429)
    end

    it "throttles password-reset emails per target address across IPs" do
      statuses = 4.times.map do |i|
        post "/api/v1/auth/forgot_password",
             params: { email: "Victim@Example.com " }.to_json,
             headers: { "CONTENT_TYPE" => "application/json" },
             env: via_cloudflare("198.51.100.#{50 + i}")
        response.status
      end
      expect(statuses.first(3)).not_to include(429)
      expect(statuses.last).to eq(429)
    end

    it "answers API throttles with the app's JSON error envelope (not an auth.* code)" do
      json = nil
      4.times do |i|
        post "/api/v1/auth/forgot_password",
             params: { email: "json-shape@example.com" }.to_json,
             headers: { "CONTENT_TYPE" => "application/json" },
             env: via_cloudflare("198.51.100.#{70 + i}")
        json = JSON.parse(response.body) if response.status == 429
      end

      expect(json.dig("error", "code")).to eq("rate_limited")
      expect(json.dig("error", "message")).to include("Demasiados intentos")
      expect(response.headers["retry-after"].to_i).to be_positive
    end

    it "lets a gift recipient finish a normal claim (signup re-POSTs) without hitting the per-email cap" do
      statuses = 6.times.map do |i|
        post "/api/v1/auth/signup",
             params: { email: "recipient-claim@example.com", password: "Password!23", first_name: "R",
                       last_name: "C", phone: "+593991230000" }.to_json,
             headers: { "CONTENT_TYPE" => "application/json" },
             env: via_cloudflare("198.51.100.#{80 + i}")
        response.status
      end
      expect(statuses).not_to include(429)
    end

    it "throttles web sign-up per client" do
      statuses = 6.times.map do |i|
        post user_registration_path,
             params: { user: { email: "spam#{i}-#{SecureRandom.hex(3)}@example.com", password: "Password!23",
                               password_confirmation: "Password!23", first_name: "S", last_name: "P",
                               phone: "+59399#{rand(1_000_000..9_999_999)}" } },
             env: via_cloudflare("198.51.100.20")
        response.status
      end
      expect(statuses.last).to eq(429)
    end
  end

  it "blocks unauthenticated Active Storage direct uploads" do
    post "/rails/active_storage/direct_uploads",
         params: { blob: { filename: "x.png", byte_size: 10, checksum: "abc", content_type: "image/png" } },
         env: via_cloudflare("198.51.100.30")
    expect(response).to have_http_status(:forbidden)
  end
end
