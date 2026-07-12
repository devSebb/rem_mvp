# Shared base for every Admin::* controller: one place for the admin gate
# instead of a copy-pasted ensure_admin per controller.
class Admin::BaseController < ApplicationController
  before_action :ensure_admin

  private

  def ensure_admin
    return if current_user&.admin?

    flash[:alert] = "Debes ser administrador para acceder a esta sección."
    redirect_to root_path
  end
end
