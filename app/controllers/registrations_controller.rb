class RegistrationsController < Devise::RegistrationsController
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
    
    # Update other attributes (password update handled by Devise)
    if params[:password].present?
      result = resource.update_with_password(params)
    else
      result = resource.update_without_password(params)
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
    params.require(:user).permit(:first_name, :last_name, :email, :phone, :password, :password_confirmation, :current_password)
  end
end

