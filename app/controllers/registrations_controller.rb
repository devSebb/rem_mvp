class RegistrationsController < Devise::RegistrationsController
  # Override Devise's create to support the pending-recipient claim flow.
  # If the email or phone matches a pending User (created by the Stripe
  # webhook when someone was sent a gift card), claim that record instead
  # of creating a duplicate. Otherwise, fall through to standard Devise
  # behavior.
  #
  # Mirrors the API claim flow in Api::V1::Auth::RegistrationsController.
  def create
    pending = find_pending_recipient_for_signup
    return super unless pending

    self.resource = pending
    populate_pending_recipient(pending)

    if pending.save
      set_flash_message! :notice, :signed_up
      sign_up(resource_name, pending)
      respond_with pending, location: after_sign_up_path_for(pending)
    else
      clean_up_passwords(pending)
      set_minimum_password_length
      respond_with pending
    end
  end

  def update
    self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)
    prev_unconfirmed_email = resource.unconfirmed_email if resource.respond_to?(:unconfirmed_email)

    # Check if this is an avatar-only update (from separate form)
    if params[:avatar_only].present?
      avatar_file = params[:user][:avatar] if params[:user].present?
      if avatar_file.present?
        # Attach the avatar first
        resource.avatar.attach(avatar_file)
        
        # Manually validate only the avatar (check size and type)
        # We skip other validations since this is an avatar-only update
        avatar_valid = true
        if resource.avatar.attached?
          blob = resource.avatar.blob
          if blob.byte_size > 5.megabytes
            resource.errors.add(:avatar, "is too large (max 5MB)")
            avatar_valid = false
          elsif !blob.content_type&.start_with?("image/")
            resource.errors.add(:avatar, "must be an image")
            avatar_valid = false
          end
        end
        
        if avatar_valid
          # Save without running validations on other fields
          # The avatar attachment will be persisted
          resource.save(validate: false)
          # Reload to ensure we have the latest data including the avatar
          resource.reload
          flash[:notice] = "Foto de perfil actualizada correctamente."
        else
          # Purge the avatar if validation failed
          resource.avatar.purge if resource.avatar.attached?
          flash[:alert] = resource.errors.full_messages.to_sentence
        end
        
        # Force a full page reload to show the updated avatar
        # Use status: :see_other to ensure Turbo doesn't intercept and forces a GET request
        redirect_to edit_user_registration_path, status: :see_other
        return
      end
    end

    # Normal update flow (with password requirement for other fields)
    params_hash = account_update_params
    resource_updated = update_resource(resource, params_hash)
    yield resource if block_given?
    if resource_updated
      set_flash_message_for_update(resource, prev_unconfirmed_email)
      bypass_sign_in resource, scope: resource_name if sign_in_after_change_password?

      respond_with resource, location: after_update_path_for(resource)
    else
      clean_up_passwords resource
      set_minimum_password_length
      respond_with resource
    end
  end

  protected

  def update_resource(resource, params)
    # Handle avatar separately if present
    avatar_file = params.delete(:avatar)
    
    # Determine if this update requires password verification
    # Password is required only for: changing password or changing email
    changing_password = params[:password].present?
    changing_email = params[:email].present? && params[:email] != resource.email
    requires_password = changing_password || changing_email
    
    if requires_password
      # Sensitive changes require current password
      result = resource.update_with_password(params)
    else
      # Non-sensitive changes (name, phone, KYC fields) don't require password
      # Remove password fields to avoid validation issues
      params.delete(:current_password)
      params.delete(:password)
      params.delete(:password_confirmation)
      result = resource.update(params)
    end
    
    # Attach avatar if provided (after other updates)
    if avatar_file.present? && result
      resource.avatar.attach(avatar_file)
      # Re-validate to check avatar constraints
      unless resource.valid?
        resource.avatar.purge if resource.avatar.attached?
        result = false
      end
    end
    
    result
  end

  def account_update_params
    params.require(:user).permit(:first_name, :last_name, :email, :phone, :password, :password_confirmation, :current_password, :date_of_birth, :address, :country_of_residence, :national_id)
  end

  private

  # Look for an existing pending User (claimed_at: nil) whose email or phone
  # matches the signup form. Returns nil if none — Devise's standard create
  # then runs as usual.
  def find_pending_recipient_for_signup
    attrs = sign_up_params
    email = attrs[:email].to_s.strip.downcase.presence
    phone = attrs[:phone].to_s.strip.presence
    return nil if email.blank? && phone.blank?

    scope = User.where(claimed_at: nil)
    if email.present? && phone.present?
      scope.where("LOWER(email) = ? OR phone = ?", email, phone).first
    elsif email.present?
      scope.where("LOWER(email) = ?", email).first
    else
      scope.where(phone: phone).first
    end
  end

  # Populate the claimed pending User with the signup values, replacing any
  # placeholder email/phone with the real ones the user just provided.
  def populate_pending_recipient(user)
    attrs = sign_up_params
    user.email = attrs[:email].to_s.strip.downcase if attrs[:email].present?
    user.phone = attrs[:phone] if attrs.key?(:phone)
    user.first_name = attrs[:first_name] if attrs[:first_name].present?
    user.last_name = attrs[:last_name] if attrs[:last_name].present?
    user.password = attrs[:password] if attrs.key?(:password)
    user.password_confirmation = attrs[:password_confirmation] if attrs.key?(:password_confirmation)
    user.role ||= :user
    user.claimed_at = Time.current
  end
end

