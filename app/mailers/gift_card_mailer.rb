class GiftCardMailer < ApplicationMailer
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'

  def deliver_gift_card(gift_card, raw_code)
    @gift_card = gift_card
    @raw_code = raw_code
    @recipient = gift_card.recipient
    @sender = gift_card.sender
    @qr_code = generate_qr_code

    mail(
      to: @recipient.email,
      subject: "🎁 Recibiste una tarjeta de regalo Papayal"
    )
  end

  private

  def generate_qr_code
    return nil unless @raw_code

    qr = RQRCode::QRCode.new(@raw_code)
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
