require "ipaddr"

# Cloudflare edge ranges (https://www.cloudflare.com/ips/). Production traffic
# reaches Rails as client -> Cloudflare -> Render LB -> Puma, so without these
# every request's "client IP" is a Cloudflare edge address: logs and
# UserSession#ip are useless and Rack::Attack buckets are shared by everyone
# behind the same PoP. Trusting these ranges lets ActionDispatch::RemoteIp and
# Rack::Request#ip walk X-Forwarded-For right-to-left past Cloudflare and land
# on the real client, which a caller cannot spoof (Cloudflare appends the true
# peer address after anything the client sent).
#
# Ranges change rarely; if Cloudflare publishes new ones, add them here.
module CloudflareIps
  RANGES = %w[
    173.245.48.0/20
    103.21.244.0/22
    103.22.200.0/22
    103.31.4.0/22
    141.101.64.0/18
    108.162.192.0/18
    190.93.240.0/20
    188.114.96.0/20
    197.234.240.0/22
    198.41.128.0/17
    162.158.0.0/15
    104.16.0.0/13
    104.24.0.0/14
    172.64.0.0/13
    131.0.72.0/22
    2400:cb00::/32
    2606:4700::/32
    2803:f800::/32
    2405:b500::/32
    2405:8100::/32
    2a06:98c0::/29
    2c0f:f248::/32
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  def self.include?(ip)
    addr = IPAddr.new(ip.to_s)
    RANGES.any? { |range| range.family == addr.family && range.include?(addr) }
  rescue IPAddr::Error
    false
  end
end
