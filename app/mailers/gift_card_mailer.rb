class GiftCardMailer < ApplicationMailer
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'noreply@rem.com'

  def deliver_gift_card(gift_card, tokens)
    @gift_card = gift_card
    @tokens = tokens
    @recipient = gift_card.recipient
    @sender = gift_card.sender
    @redeem_url = "#{ENV['APP_HOST']}/redeem?token=#{tokens[:link]}"
    @qr_code = generate_qr_code

    mail(
      to: @recipient.email,
      subject: "You've received a REM gift card! 🎁"
    )
  end

  private

  def generate_qr_code
    return nil unless @redeem_url

    qr = RQRCode::QRCode.new(@redeem_url)
    qr.as_svg(
      offset: 0,
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 6,
      standalone: true
    )
  rescue => e
    Rails.logger.error "Failed to generate QR code: #{e.message}"
    nil
  end
end
