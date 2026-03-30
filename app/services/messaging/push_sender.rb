require "net/http"
require "json"

module Messaging
  class PushSender
    EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send"

    def send_to_user(user, title:, body:, data: {})
      tokens = user.push_tokens.active.pluck(:token)
      return { success: false, error: "No active push tokens" } if tokens.empty?

      messages = tokens.map do |token|
        {
          to: token,
          title: title,
          body: body,
          data: data,
          sound: "default"
        }
      end

      response = send_to_expo(messages)
      handle_response(response, tokens, user)

      { success: true, tokens_sent: tokens.size }
    rescue => e
      Rails.logger.error "[PushSender] Failed to send push notification: #{e.class} - #{e.message}"
      { success: false, error: e.message }
    end

    private

    def send_to_expo(messages)
      uri = URI(EXPO_PUSH_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = messages.to_json

      response = http.request(request)
      JSON.parse(response.body)
    end

    def handle_response(response, tokens, user)
      tickets = response["data"] || []

      tickets.each_with_index do |ticket, idx|
        next if ticket["status"] == "ok"

        token = tokens[idx]
        error_type = ticket.dig("details", "error")

        if error_type == "DeviceNotRegistered"
          Rails.logger.info "[PushSender] Deactivating unregistered token for user #{user.id}"
          user.push_tokens.where(token: token).update_all(active: false)
        else
          Rails.logger.warn "[PushSender] Error sending to #{token[0..20]}...: #{ticket["message"]}"
        end
      end
    end
  end
end
