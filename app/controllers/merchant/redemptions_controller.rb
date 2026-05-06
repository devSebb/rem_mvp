class Merchant::RedemptionsController < ApplicationController
  before_action :ensure_merchant

  def new
    @gift_card = nil
  end

  def create
    raw_input = params[:code]
    token_candidate = normalized_token(raw_input)
    code = normalized_code(raw_input)
    Rails.logger.info "🔍 Merchant redemption attempt - Code: #{code}, Merchant: #{current_user.merchant&.store_name || 'NONE'}"

    if code.blank?
      Rails.logger.warn "❌ Empty code provided"
      flash[:alert] = 'Please enter a gift card code or dynamic token.'
      redirect_to new_merchant_redemption_path and return
    end

    # 1) Try dynamic redemption token first (QR/manual token from recipient wallet)
    if (active_token = active_redemption_token_for(token_candidate))
      @gift_card = active_token.gift_card

      unless @gift_card.can_be_redeemed?
        Rails.logger.warn "❌ Gift card #{@gift_card.id} cannot be redeemed - Status: #{@gift_card.status}, Expired: #{@gift_card.expired?}, Balance: #{@gift_card.remaining_balance}"
        flash[:alert] = 'This gift card cannot be redeemed (expired, inactive, or has no remaining balance).'
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

    # 2) Fallback to raw gift card code (REM-XXXX-XXXX-XXXX)
    @gift_card = GiftCard.find_active_by_code(code)

    if @gift_card.nil?
      Rails.logger.warn "❌ Gift card not found for code: #{code}"
      flash[:alert] = 'Gift card not found or already redeemed.'
      redirect_to new_merchant_redemption_path and return
    end

    Rails.logger.info "✅ Found gift card #{@gift_card.id} - Status: #{@gift_card.status}, Balance: #{@gift_card.remaining_balance}"

    unless @gift_card.can_be_redeemed?
      Rails.logger.warn "❌ Gift card #{@gift_card.id} cannot be redeemed - Status: #{@gift_card.status}, Expired: #{@gift_card.expired?}, Balance: #{@gift_card.remaining_balance}"
      flash[:alert] = 'This gift card cannot be redeemed (expired, inactive, or has no remaining balance).'
      redirect_to new_merchant_redemption_path and return
    end

    # Show confirmation page
    Rails.logger.info "✅ Redirecting to confirmation for gift card #{@gift_card.id}"
    redirect_to confirm_merchant_redemptions_path(
      gift_card_id: @gift_card.id,
      redemption_mode: "code"
    )
  end

  def confirm
    gift_card_id = params[:gift_card_id]
    @gift_card = GiftCard.find(gift_card_id)
    @redemption_mode = params[:redemption_mode].presence || "code"
    @redemption_token_value = normalized_token(params[:redemption_token]) if @redemption_mode == "token"
    @redemption_token = active_redemption_token_for(@redemption_token_value) if @redemption_token_value.present?

    # Network redemption: any merchant in the network can redeem any gift card.
    # Track issuing vs redeeming merchant for transparency in UI.
    @issuing_merchant = @gift_card.merchant
    @redeeming_merchant = current_user.merchant
    @is_cross_merchant = @issuing_merchant.id != @redeeming_merchant.id

    if @redemption_mode == "token"
      unless @redemption_token && @redemption_token.gift_card_id == @gift_card.id
        flash[:alert] = 'The dynamic code is invalid, expired, or does not match this gift card.'
        redirect_to new_merchant_redemption_path and return
      end
    end
    
    # Generate idempotency token for this redemption
    @idempotency_token = RedemptionIdempotencyService.generate_token
    
    # Pre-store the token so it exists when the form is submitted
    # We'll store it with placeholder values that will be updated in redeem action
    begin
      RedemptionIdempotencyService.store_token(
        @idempotency_token, 
        gift_card_id, 
        @gift_card.remaining_balance, # Default to full balance, will be updated
        current_user.merchant.id
      )
      Rails.logger.info "✅ Stored idempotency token for confirmation: #{@idempotency_token}"
    rescue => e
      Rails.logger.warn "⚠️ Failed to pre-store idempotency token: #{e.message}"
      # Continue anyway - validation will be more lenient in development
    end
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  end

  def redeem
    gift_card_id = params[:gift_card_id]
    redemption_amount = params[:redemption_amount]&.to_f&.*(100)&.to_i # Convert to cents
    idempotency_token = params[:idempotency_token]
    redemption_mode = params[:redemption_mode].presence || "code"
    redemption_token_value = normalized_token(params[:redemption_token]) if redemption_mode == "token"
    
    Rails.logger.info "💰 Processing redemption - Gift Card ID: #{gift_card_id}, Amount: #{redemption_amount}, Token: #{idempotency_token.present? ? 'present' : 'missing'}"
    
    # Check merchant association
    unless current_user.merchant
      Rails.logger.error "❌ User #{current_user.id} has no merchant association"
      flash[:alert] = 'Merchant account not found. Please contact support.'
      redirect_to merchant_root_path and return
    end
    
    @gift_card = GiftCard.find(gift_card_id)
    Rails.logger.info "✅ Found gift card #{@gift_card.id} - Balance: #{@gift_card.remaining_balance}"

    # If we are redeeming with a dynamic token, use the centralized service
    if redemption_mode == "token"
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
          redemption_mode: redemption_mode,
          redemption_token: redemption_token_value
        ) and return
      end

      if result[:approved]
        @gift_card = GiftCard.find(result[:gift_card_id])
        begin
          RedemptionIdempotencyService.consume_token(idempotency_token)
        rescue => e
          Rails.logger.warn "⚠️ Failed to consume idempotency token after dynamic redemption: #{e.message}"
        end

        notify_recipient_of_redemption(@gift_card, result[:amount_cents])

        flash[:notice] = "Successfully redeemed #{format_amount(result[:amount_cents], result[:currency])}. Remaining balance: #{format_amount(result[:remaining_balance_cents], result[:currency])}."
        redirect_to success_merchant_redemptions_path(gift_card_id: @gift_card.id)
      else
        Rails.logger.warn "❌ Dynamic token redemption declined: #{result[:decline_reason] || 'unknown_reason'}"
        flash[:alert] = "Could not redeem: #{(result[:decline_reason] || 'invalid or expired token').to_s.humanize}."
        redirect_to confirm_merchant_redemptions_path(
          gift_card_id: @gift_card.id,
          redemption_mode: redemption_mode,
          redemption_token: redemption_token_value
        )
      end
      return
    end

    # Validate idempotency token (with fallback if Redis not available)
    token_valid = false
    begin
      token_valid = idempotency_token.present? && RedemptionIdempotencyService.token_exists?(idempotency_token)
      Rails.logger.info "   Token exists check: #{token_valid}"
    rescue => e
      Rails.logger.warn "⚠️ Idempotency check failed: #{e.message}"
      # The service itself handles development fallback, so if we get here, it's a real error
      token_valid = false
    end
    
    unless token_valid
      Rails.logger.warn "❌ Invalid or expired idempotency token: #{idempotency_token}"
      Rails.logger.warn "   Token present: #{idempotency_token.present?}"
      # In development, provide more helpful error message
      if Rails.env.development?
        Rails.logger.warn "   💡 Development tip: Make sure Redis is running or the token format is valid UUID"
      end
      flash[:alert] = 'Invalid or expired redemption request. Please try again.'
      redirect_to new_merchant_redemption_path and return
    end

    # Validate redemption amount
    if redemption_amount.nil? || redemption_amount <= 0
      Rails.logger.warn "❌ Invalid redemption amount: #{redemption_amount}"
      flash[:alert] = 'Please enter a valid redemption amount.'
      redirect_to confirm_merchant_redemptions_path(gift_card_id: @gift_card.id) and return
    end

    if redemption_amount > @gift_card.remaining_balance
      Rails.logger.warn "❌ Redemption amount #{redemption_amount} exceeds balance #{@gift_card.remaining_balance}"
      flash[:alert] = "Redemption amount cannot exceed remaining balance of #{format_amount(@gift_card.remaining_balance, @gift_card.currency)}."
      redirect_to confirm_merchant_redemptions_path(gift_card_id: @gift_card.id) and return
    end

    # Store idempotency data before processing (with error handling)
    begin
      RedemptionIdempotencyService.store_token(idempotency_token, gift_card_id, redemption_amount, current_user.merchant.id)
    rescue => e
      Rails.logger.warn "⚠️ Failed to store idempotency token (Redis may not be available): #{e.message}"
      # Continue anyway - idempotency is nice to have but not critical
    end

    Rails.logger.info "🔄 Attempting to redeem #{redemption_amount} from gift card #{@gift_card.id}"
    
    if @gift_card.partial_redeem!(redemption_amount: redemption_amount, merchant: current_user.merchant, actor: current_user)
      Rails.logger.info "✅ Successfully redeemed #{redemption_amount} from gift card #{@gift_card.id}"

      # Consume the token after successful redemption
      begin
        RedemptionIdempotencyService.consume_token(idempotency_token)
      rescue => e
        Rails.logger.warn "⚠️ Failed to consume idempotency token: #{e.message}"
      end

      notify_recipient_of_redemption(@gift_card, redemption_amount)

      flash[:notice] = "Successfully redeemed #{format_amount(redemption_amount, @gift_card.currency)}. Remaining balance: #{format_amount(@gift_card.reload.remaining_balance, @gift_card.currency)}."
      redirect_to success_merchant_redemptions_path(gift_card_id: @gift_card.id)
    else
      Rails.logger.error "❌ Failed to redeem gift card #{@gift_card.id}"
      flash[:alert] = 'Failed to redeem gift card. Please try again.'
      redirect_to new_merchant_redemption_path
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
    case currency.upcase
    when 'USD'
      "$#{amount_cents / 100.0}"
    when 'EUR'
      "€#{amount_cents / 100.0}"
    else
      "#{amount_cents / 100.0} #{currency}"
    end
  end

  def normalized_code(value)
    value.to_s.strip.upcase
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

  def redeemable_for_merchant?(_gift_card)
    true
  end
end
