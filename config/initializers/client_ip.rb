# Rack::Request#ip (what Rack::Attack keys every throttle on) must agree with
# request.remote_ip and must not be spoofable.
#
# 1. Ignore the RFC 7239 `Forwarded` header. Rack 3 reads it BEFORE
#    X-Forwarded-For by default, and neither Cloudflare nor Render overwrites
#    it, so a client could send `Forwarded: for=<anything>` and pick its own
#    rate-limit bucket (or `for=127.0.0.1` to look like localhost).
#    ActionDispatch::RemoteIp never reads it either, so this keeps both in sync.
Rack::Request.forwarded_priority = [:x_forwarded]

# 2. Treat Cloudflare edges as trusted proxies, like the private ranges Rack
#    already trusts, so #ip skips past them to the real client.
rack_default_ip_filter = Rack::Request.ip_filter
Rack::Request.ip_filter = ->(ip) { rack_default_ip_filter.call(ip) || CloudflareIps.include?(ip) }
