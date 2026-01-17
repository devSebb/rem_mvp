module Api
  module V1
    class CheckoutController < Api::V1::BaseController
      def validate_kyc
        result = Kyc::CheckoutValidator.call(user: current_user)

        data = {
          ok: result[:ok],
          missing: result[:missing]
        }
        data[:errors] = result[:errors] if result[:errors].present?

        render_success(data:)
      end

      def payment_intent
        # Validate KYC first
        kyc_result = Kyc::CheckoutValidator.call(user: current_user)
        unless kyc_result[:ok]
          return render_error(
            code: "kyc_incomplete",
            message: "Please complete your details (#{kyc_result[:missing].join(', ')}) before checkout.",
            status: :unprocessable_entity
          )
        end

        # Parse and validate parameters
        merchant_id = params.require(:merchant_id).to_s.strip
        amount_cents = params.require(:amount_cents).to_i
        currency = params.require(:currency).to_s.upcase
        recipient_params = params.require(:recipient).permit(:name, :email, :phone, :note)

        # Validate merchant
        unless merchant_id.match?(/\A\d+\z/)
          return render_error(
            code: "invalid_merchant",
            message: "Please select a valid merchant",
            status: :unprocessable_entity
          )
        end

        merchant = Merchant.find_by(id: merchant_id)
        unless merchant
          return render_error(
            code: "invalid_merchant",
            message: "Please select a valid merchant",
            status: :unprocessable_entity
          )
        end

        # Validate amount
        if amount_cents <= 0
          return render_error(
            code: "invalid_amount",
            message: "Amount must be greater than 0",
            status: :unprocessable_entity
          )
        end

        if amount_cents < 100
          return render_error(
            code: "invalid_amount",
            message: "Amount must be at least $1.00",
            status: :unprocessable_entity
          )
        end

        if amount_cents > GiftCard::MAX_AMOUNT_CENTS
          return render_error(
            code: "invalid_amount",
            message: "El monto máximo por tarjeta de regalo es $#{GiftCard::MAX_AMOUNT_CENTS / 100.0} USD",
            status: :unprocessable_entity
          )
        end

        # Validate recipient
        if recipient_params[:phone].blank? && recipient_params[:email].blank?
          return render_error(
            code: "invalid_recipient",
            message: "Recipient phone or email is required",
            status: :unprocessable_entity
          )
        end

        # Check purchase limit
        limit_check = GiftCardPurchaseLimiter.can_purchase?(user: current_user)
        unless limit_check[:allowed]
          return render_error(
            code: "purchase_limit_exceeded",
            message: "Has alcanzado el límite de #{limit_check[:limit]} tarjetas de regalo en las últimas 24 horas. Por favor intenta de nuevo mañana.",
            status: :unprocessable_entity
          )
        end

        # Create Stripe PaymentIntent
        begin
          payment_intent = Stripe::PaymentIntent.create(
            amount: amount_cents,
            currency: currency.downcase,
            payment_method_types: ['card'],
            metadata: {
              sender_id: current_user.id.to_s,
              recipient_email: recipient_params[:email] || '',
              recipient_phone: recipient_params[:phone] || '',
              recipient_name: recipient_params[:name] || 'Gift Card Recipient',
              recipient_note: recipient_params[:note] || '',
              merchant_id: merchant.id.to_s
            }
          )

          render_success(data: {
            client_secret: payment_intent.client_secret,
            payment_intent_id: payment_intent.id
          })
        rescue Stripe::StripeError => e
          Rails.logger.error "Stripe PaymentIntent creation error: #{e.message}"
          render_error(
            code: "payment_error",
            message: "Unable to process payment. Please try again.",
            status: :internal_server_error
          )
        end
      end
    end
  end
end

