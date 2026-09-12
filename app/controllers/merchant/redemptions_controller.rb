class Merchant::RedemptionsController < ApplicationController
  before_action :ensure_merchant

  def new
    @gift_card = nil
  end

  def create
    raw_input = params[:code]
    token_candidate = normalized_token(raw_input)
    Rails.logger.info "🔍 Merchant redemption attempt - Dynamic token present: #{token_candidate.present?}, Merchant: #{current_user.merchant&.store_name || 'NONE'}"

    if token_candidate.blank?
      Rails.logger.warn "❌ Empty dynamic token provided"
      flash[:alert] = 'Please enter the dynamic code generated in the customer’s Papayal app.'
      redirect_to new_merchant_redemption_path and return
    end

    if (active_token = active_redemption_token_for(token_candidate))
      @gift_card = active_token.gift_card

      # D6: only the issuing merchant or one in its redemption group.
      unless Merchants::CanRedeem.call(redeemer: current_user.merchant, issuer: @gift_card.merchant)
        Rails.logger.warn "❌ Gift card #{@gift_card.id} issued for merchant #{@gift_card.merchant_id}; #{current_user.merchant&.id} cannot redeem it"
        flash[:alert] = "Esta tarjeta es de #{@gift_card.merchant&.store_name} y no puede canjearse en tu comercio."
        redirect_to new_merchant_redemption_path and return
      end

      if @gift_card.frozen_by_admin?
        flash[:alert] = 'Esta tarjeta está congelada por Papayal y no puede canjearse.'
        redirect_to new_merchant_redemption_path and return
      end

      unless @gift_card.can_be_redeemed?
        balances = @gift_card.balances
        Rails.logger.warn "❌ Gift card #{@gift_card.id} cannot be redeemed - Status: #{@gift_card.status}, spendable: #{balances[:spendable_cents]} (held #{balances[:held_cents]}, disputed #{balances[:disputed_cents]})"
        flash[:alert] =
          if balances[:held_cents].positive?
            'Esta tarjeta tiene su saldo en revisión de seguridad. Inténtalo más tarde.'
          elsif balances[:disputed_cents].positive?
            'Esta tarjeta tiene su saldo en disputa y no puede canjearse por ahora.'
          else
            'Esta tarjeta no tiene saldo disponible o está inactiva.'
          end
        redirect_to new_merchant_redemption_path and return
      end

      Rails.logger.info "✅ Found gift card via dynamic token #{@gift_card.id}"
      redirect_to confirm_merchant_redemptions_path(
        gift_card_id: @gift_card.id,
        redemption_mode: "token",
        redemption_token: token_candidate
      ) and return
    elsif redemption_token_for(token_candidate)
      # Token existed but is no longer active
      flash[:alert] = 'This dynamic code is expired or already used. Please refresh the code from the customer.'
      redirect_to new_merchant_redemption_path and return
    end

    Rails.logger.warn "❌ Dynamic token not found"
    flash[:alert] = 'Dynamic code not found. Ask the customer to generate a new code from the app.'
    redirect_to new_merchant_redemption_path
  end

  def confirm
    gift_card_id = params[:gift_card_id]
    @gift_card = GiftCard.find(gift_card_id)
    @redemption_mode = "token"
    @redemption_token_value = normalized_token(params[:redemption_token])
    @redemption_token = active_redemption_token_for(@redemption_token_value) if @redemption_token_value.present?

    @issuing_merchant = @gift_card.merchant
    @redeeming_merchant = current_user.merchant
    @balances = @gift_card.balances

    unless @redemption_token && @redemption_token.gift_card_id == @gift_card.id
      flash[:alert] = 'The dynamic code is invalid, expired, or does not match this gift card.'
      redirect_to new_merchant_redemption_path and return
    end

    # D6 is a decline, not a banner (§5.12).
    unless Merchants::CanRedeem.call(redeemer: @redeeming_merchant, issuer: @issuing_merchant)
      flash[:alert] = "Esta tarjeta es de #{@issuing_merchant&.store_name} y no puede canjearse en tu comercio."
      redirect_to new_merchant_redemption_path and return
    end
    
    # One-shot idempotency key for the confirm form. A double submit replays
    # the same (merchant, key) and Redemptions::AuthorizeAndCapture returns
    # the original result instead of capturing twice.
    @idempotency_token = SecureRandom.uuid
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  end

  def redeem
    gift_card_id = params[:gift_card_id]
    redemption_amount = params[:redemption_amount]&.to_f&.*(100)&.to_i # Convert to cents
    idempotency_token = params[:idempotency_token]
    redemption_token_value = normalized_token(params[:redemption_token])
    
    Rails.logger.info "💰 Processing redemption - Gift Card ID: #{gift_card_id}, Amount: #{redemption_amount}, Token: #{idempotency_token.present? ? 'present' : 'missing'}"
    
    # Check merchant association
    unless current_user.merchant
      Rails.logger.error "❌ User #{current_user.id} has no merchant association"
      flash[:alert] = 'Merchant account not found. Please contact support.'
      redirect_to merchant_root_path and return
    end
    
    @gift_card = GiftCard.find(gift_card_id)
    Rails.logger.info "✅ Found gift card #{@gift_card.id} - Balance: #{@gift_card.remaining_balance}"

    if redemption_token_value.blank?
      Rails.logger.warn "❌ Dynamic token missing from redemption submit"
      flash[:alert] = 'Dynamic code is required. Ask the customer to generate a fresh code from the app.'
      redirect_to new_merchant_redemption_path and return
    end

    begin
      result = Redemptions::AuthorizeAndCapture.call(
        merchant: current_user.merchant,
        raw_token: redemption_token_value,
        amount_cents: redemption_amount,
        idempotency_key: idempotency_token,
        merchant_reference: params[:merchant_reference]
      )
    rescue Redemptions::AuthorizeAndCapture::ValidationError => e
      Rails.logger.warn "❌ Validation failed for dynamic token redemption: #{e.message}"
      flash[:alert] = e.message
      redirect_to confirm_merchant_redemptions_path(
        gift_card_id: @gift_card.id,
        redemption_mode: "token",
        redemption_token: redemption_token_value
      ) and return
    end

    if result[:approved]
      @gift_card = GiftCard.find(result[:gift_card_id])

      notify_recipient_of_redemption(@gift_card, result[:amount_cents])

      flash[:notice] = "Successfully redeemed #{format_amount(result[:amount_cents], result[:currency])}. Remaining balance: #{format_amount(result[:remaining_balance_cents], result[:currency])}."
      redirect_to success_merchant_redemptions_path(gift_card_id: @gift_card.id, amount_cents: result[:amount_cents])
    else
      Rails.logger.warn "❌ Dynamic token redemption declined: #{result[:decline_reason] || 'unknown_reason'}"
      flash[:alert] = "Could not redeem: #{(result[:decline_reason] || 'invalid or expired token').to_s.humanize}."
      redirect_to confirm_merchant_redemptions_path(
        gift_card_id: @gift_card.id,
        redemption_mode: "token",
        redemption_token: redemption_token_value
      )
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "❌ Gift card not found: #{e.message}"
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  rescue => e
    Rails.logger.error "💥 Redemption error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    flash[:alert] = "An error occurred: #{e.message}"
    redirect_to new_merchant_redemption_path
  end

  def success
    @gift_card = GiftCard.find(params[:gift_card_id]) if params[:gift_card_id]
    # Amount captured by the redemption that just happened (passed on redirect).
    # Never derive it from the card: total_loaded - remaining also counts refunds.
    @redeemed_cents = params[:amount_cents].to_i if params[:amount_cents].present?
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end

  def format_amount(amount_cents, currency)
    return "-" if amount_cents.nil?
    Messaging::Money.format(amount_cents, currency: currency)
  end

  def normalized_token(value)
    value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  # Best-effort push to the recipient that their card was redeemed.
  # Wrapped so any push/Expo failure can never block the merchant's flow.
  def notify_recipient_of_redemption(gift_card, amount_cents)
    Messaging::RedemptionPusher.call(
      gift_card: gift_card,
      amount_cents: amount_cents,
      merchant: current_user.merchant
    )
  rescue => e
    Rails.logger.warn "[RedemptionPusher] enqueue failed for gift_card_id=#{gift_card&.id}: #{e.class} - #{e.message}"
  end

  def active_redemption_token_for(raw_value)
    return nil if raw_value.blank?
    RedemptionToken.active.find_by(token_digest: RedemptionToken.digest(raw_value))
  end

  def redemption_token_for(raw_value)
    return nil if raw_value.blank?
    RedemptionToken.find_by(token_digest: RedemptionToken.digest(raw_value))
  end
end
