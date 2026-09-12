module Api
  module V1
    class CheckoutController < Api::V1::BaseController
      SUPPORTED_CURRENCIES = %w[USD].freeze

      def validate_kyc
        result = Kyc::CheckoutValidator.call(user: current_user)

        data = {
          ok: result[:ok],
          missing: result[:missing]
        }
        data[:errors] = result[:errors] if result[:errors].present?

        render_success(data: data)
      end

      # Server-authoritative price breakdown so the app can show fee/total
      # before the buyer confirms. Fees come from PlatformSetting (admin-editable).
      def quote
        return unless ensure_purchases_enabled!

        amount_cents = params.require(:amount_cents).to_i
        currency = params[:currency].presence&.to_s&.upcase || "USD"

        return unless validate_currency!(currency)
        return unless validate_amount!(amount_cents)

        quote = Checkout::Quote.call(amount_cents: amount_cents, currency: currency)
        render_success(data: quote_payload(quote))
      end

      def payment_intent
        return unless ensure_purchases_enabled!

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
        recipient_params = params.require(:recipient).permit(:name, :email, :phone, :note, :self)
        draft_id = params[:draft_id].to_s.strip.presence
        # §8.3: `recipient.self: true` reloads the buyer's own card.
        self_load = ActiveModel::Type::Boolean.new.cast(recipient_params[:self]) == true

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

        unless merchant.active?
          return render_error(
            code: "invalid_merchant",
            message: "Please select a valid merchant",
            status: :unprocessable_entity
          )
        end

        # Validate currency and amount
        return unless validate_currency!(currency)
        return unless validate_amount!(amount_cents)

        # Validate recipient
        if !self_load && recipient_params[:phone].blank? && recipient_params[:email].blank?
          return render_error(
            code: "invalid_recipient",
            message: "Recipient phone or email is required",
            status: :unprocessable_entity
          )
        end

        # §4.1 caps (D7). The prospective recipient is resolved exactly as the
        # webhook will (self → buyer; else phone → email) but never created
        # here; recipient- and card-level caps are re-checked at fulfilment.
        prospective_recipient =
          if self_load
            current_user
          else
            Loads::Fulfill.find_recipient(
              "recipient_phone" => recipient_params[:phone], "recipient_email" => recipient_params[:email]
            )
          end
        begin
          cap_result = Loads::CapChecker.check!(
            buyer: current_user, recipient: prospective_recipient, merchant: merchant, amount_cents: amount_cents
          )
        rescue Loads::CapChecker::CapExceeded => e
          return render_error(
            code: e.error_code,
            message: cap_message(e),
            status: :unprocessable_entity,
            details: e.details
          )
        end

        # What the webhook will resolve the recipient to, so Loads::Fulfill
        # needs no second lookup for self-loads (§5.2).
        recipient_metadata =
          if self_load
            {
              recipient_user_id: current_user.id.to_s,
              recipient_email: current_user.placeholder_email? ? '' : current_user.email.to_s,
              recipient_phone: current_user.phone.to_s,
              recipient_name: current_user.full_name.presence || current_user.name.to_s,
              recipient_note: ''
            }
          else
            {
              recipient_email: recipient_params[:email] || '',
              recipient_phone: recipient_params[:phone] || '',
              recipient_name: recipient_params[:name] || 'Gift Card Recipient',
              recipient_note: recipient_params[:note] || ''
            }
          end

        # Server-side price breakdown: the buyer is charged subtotal + fee.
        # The gift card's face value stays the subtotal (webhook reads the
        # metadata below). With fees at 0 this is identical to charging the
        # face value directly.
        quote = Checkout::Quote.call(amount_cents: amount_cents, currency: currency)

        # Generate Stripe-level idempotency key to prevent duplicate PaymentIntents on retries
        idempotency_key = generate_stripe_idempotency_key(
          draft_id: draft_id,
          user_id: current_user.id,
          merchant_id: merchant.id,
          amount_cents: amount_cents,
          currency: currency,
          recipient_params: recipient_params
        )

        # Log the payment intent creation attempt
        Rails.logger.info(
          "[PaymentIntent] Creating: request_id=#{request.request_id} " \
          "user_id=#{current_user.id} merchant_id=#{merchant.id} " \
          "amount_cents=#{amount_cents} currency=#{currency} " \
          "idempotency_key=#{idempotency_key[0..15]}..."
        )

        # Create Stripe PaymentIntent
        begin
          payment_intent = Stripe::PaymentIntent.create(
            {
              amount: quote.total_cents,
              currency: currency.downcase,
              payment_method_types: ['card'],
              # Let Stripe Radar decide when 3DS is required: liability for
              # fraud disputes shifts to the issuer on 3DS-confirmed charges.
              # Zero UX cost on the normal path; Radar only prompts when warranted.
              payment_method_options: {
                card: { request_three_d_secure: "automatic" }
              },
              metadata: recipient_metadata.merge(
                sender_id: current_user.id.to_s,
                merchant_id: merchant.id.to_s,
                subtotal_cents: quote.subtotal_cents.to_s,
                fee_cents: quote.fee_cents.to_s
              )
            },
            { idempotency_key: idempotency_key }
          )

          # Log success with Stripe request ID for debugging
          stripe_request_id = payment_intent.respond_to?(:last_response) ? payment_intent.last_response&.request_id : nil
          Rails.logger.info(
            "[PaymentIntent] Created: request_id=#{request.request_id} " \
            "payment_intent_id=#{payment_intent.id} " \
            "stripe_request_id=#{stripe_request_id || 'N/A'}"
          )

          # §8.3 `target`: the card this payment will land on (nil when the
          # recipient has no card at this merchant yet) and the projected balance.
          render_success(data: {
            client_secret: payment_intent.client_secret,
            payment_intent_id: payment_intent.id,
            quote: quote_payload(quote),
            target: {
              self: self_load,
              existing_card_id: cap_result.card&.id,
              current_balance_cents: cap_result.current_balance_cents,
              projected_balance_cents: cap_result.projected_balance_cents
            }
          })
        rescue Stripe::StripeError => e
          log_stripe_error(e)
          render_error(
            code: "payment_error",
            message: "Unable to process payment. Please try again.",
            status: :internal_server_error
          )
        end
      end

      private

      # Kill switch (admin-editable): lets purchases be paused during an
      # incident without a deploy. Returns false after rendering the error.
      def ensure_purchases_enabled!
        return true if PlatformSetting.current.purchases_enabled?

        render_error(
          code: "purchases_disabled",
          message: "Las compras están temporalmente deshabilitadas. Intenta de nuevo más tarde.",
          status: :service_unavailable
        )
        false
      end

      def validate_currency!(currency)
        return true if SUPPORTED_CURRENCIES.include?(currency)

        render_error(
          code: "invalid_currency",
          message: "Only USD is supported",
          status: :unprocessable_entity
        )
        false
      end

      # Coarse sanity check; the real per-load range (§4.1) is enforced by
      # Loads::CapChecker (`checkout.load_amount_out_of_range`).
      def validate_amount!(amount_cents)
        message =
          if amount_cents <= 0
            "Amount must be greater than 0"
          elsif amount_cents < 100
            "Amount must be at least $1.00"
          elsif amount_cents > GiftCardLoad::MAX_LOAD_CENTS
            "El monto máximo por recarga es $#{GiftCardLoad::MAX_LOAD_CENTS / 100.0} USD"
          end

        return true if message.nil?

        render_error(code: "invalid_amount", message: message, status: :unprocessable_entity)
        false
      end

      # Spanish copy per §4.1 cap; the app shows the room from `details`.
      def cap_message(error)
        d = error.details
        room = d[:room_cents] ? format("$%.2f", d[:room_cents] / 100.0) : nil
        case error.code
        when :load_amount_out_of_range
          "El monto por recarga debe estar entre $#{d[:min_cents] / 100.0} y $#{d[:max_cents] / 100.0} USD."
        when :buyer_dispute_open
          "Tienes una disputa de pago abierta. No puedes hacer recargas hasta que se resuelva."
        when :card_daily_count_limit, :buyer_daily_count_limit
          "Alcanzaste el máximo de #{d[:limit]} recargas en 24 horas. Intenta de nuevo mañana."
        when :card_daily_load_limit, :buyer_daily_limit
          "Hoy puedes recargar hasta #{room} más. Intenta de nuevo mañana."
        when :card_balance_limit
          "Esta tarjeta puede tener un saldo máximo de $#{d[:limit_cents] / 100.0}. Puedes recargar hasta #{room}."
        when :recipient_monthly_limit, :buyer_monthly_limit
          "Alcanzaste el límite de 30 días. Puedes recargar hasta #{room} más."
        else
          "No es posible completar esta recarga por ahora."
        end
      end

      def quote_payload(quote)
        {
          subtotal_cents: quote.subtotal_cents,
          fee_cents: quote.fee_cents,
          total_cents: quote.total_cents,
          currency: quote.currency
        }
      end

      # Generate a deterministic idempotency key for Stripe PaymentIntent creation.
      # This prevents duplicate PaymentIntents when the mobile client retries on network errors.
      #
      # If draft_id is provided (e.g., from mobile app's local draft), use that directly.
      # Otherwise, use a hash of the purchase inputs + a 10-minute time bucket to allow
      # legitimate repeated purchases while preventing accidental duplicates.
      def generate_stripe_idempotency_key(draft_id:, user_id:, merchant_id:, amount_cents:, currency:, recipient_params:)
        if draft_id.present?
          "mobile_pi:draft:#{draft_id}"
        else
          # Time bucket: 10 minutes (600 seconds)
          time_bucket = Time.now.to_i / 600
          recipient_identifier = recipient_params[:email].presence || recipient_params[:phone].presence || (recipient_params[:self].present? ? "self:#{user_id}" : '')
          recipient_name = recipient_params[:name].presence || ''

          raw_key = [
            user_id,
            merchant_id,
            amount_cents,
            currency,
            recipient_identifier,
            recipient_name,
            time_bucket
          ].join(':')

          "mobile_pi:#{Digest::SHA256.hexdigest(raw_key)[0..31]}"
        end
      end

      # Log Stripe error details for debugging without leaking internals to client
      def log_stripe_error(error)
        error_details = {
          message: error.message,
          code: error.respond_to?(:code) ? error.code : nil,
          type: error.respond_to?(:error) && error.error.respond_to?(:type) ? error.error.type : nil,
          stripe_request_id: error.respond_to?(:request_id) ? error.request_id : nil
        }.compact

        Rails.logger.error(
          "[PaymentIntent] Stripe error: request_id=#{request.request_id} " \
          "user_id=#{current_user&.id} #{error_details.map { |k, v| "#{k}=#{v}" }.join(' ')}"
        )
      end
    end
  end
end
