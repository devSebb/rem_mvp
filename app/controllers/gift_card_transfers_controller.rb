class GiftCardTransfersController < ApplicationController
  include ConsumerWebGate

  before_action :set_gift_card, only: [:new, :create, :confirm]

  def new
    authorize @gift_card, :transfer?
  end

  def create
    authorize @gift_card, :transfer?
    
    email = params[:email]&.strip&.downcase
    phone = params[:phone]&.strip
    
    if email.blank? && phone.blank?
      flash[:alert] = 'Please provide either an email address or phone number.'
      redirect_to new_gift_card_transfer_path(@gift_card) and return
    end

    # Find recipient by email or phone
    @new_recipient = nil
    
    if email.present?
      @new_recipient = User.find_by(email: email)
    end
    
    if @new_recipient.nil? && phone.present?
      @new_recipient = User.find_by(phone: phone)
    end

    if @new_recipient.nil?
      flash[:alert] = 'No user found with that email address or phone number. The recipient must be registered on our platform.'
      redirect_to new_gift_card_transfer_path(@gift_card) and return
    end

    if @new_recipient == @gift_card.recipient
      flash[:alert] = 'You cannot transfer the gift card to yourself.'
      redirect_to new_gift_card_transfer_path(@gift_card) and return
    end

    # Redirect to confirmation page
    redirect_to confirm_gift_card_transfer_path(@gift_card, new_recipient_id: @new_recipient.id)
  end

  def confirm
    authorize @gift_card, :transfer?
    
    @new_recipient = User.find(params[:new_recipient_id])
    
    if @new_recipient.nil?
      flash[:alert] = 'Recipient not found.'
      redirect_to new_gift_card_transfer_path(@gift_card) and return
    end
  end

  def process_transfer
    @gift_card = GiftCard.find(params[:gift_card_id])
    authorize @gift_card, :transfer?
    
    @new_recipient = User.find(params[:new_recipient_id])
    
    if @new_recipient.nil?
      flash[:alert] = 'Recipient not found.'
      redirect_to new_gift_card_transfer_path(@gift_card) and return
    end

    # Process the transfer
    if @gift_card.transfer_to!(new_recipient: @new_recipient, actor: current_user)
      flash[:notice] = "Successfully transferred gift card to #{@new_recipient.name}. They will receive a notification."
      redirect_to gift_card_path(@gift_card)
    else
      flash[:alert] = 'Failed to transfer gift card. Please try again.'
      redirect_to new_gift_card_transfer_path(@gift_card)
    end
  end

  private

  def set_gift_card
    @gift_card = GiftCard.find(params[:gift_card_id])
  end
end
