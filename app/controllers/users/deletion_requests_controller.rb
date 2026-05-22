module Users
  # Public landing page that satisfies Google Play's requirement of a
  # web-accessible account deletion path. V1 is instructions-only — the
  # canonical deletion flow lives in the mobile app (DELETE /api/v1/me)
  # and routes through Users::DeleteAccount. Users without app access
  # are pointed at the support email.
  class DeletionRequestsController < ApplicationController
    skip_before_action :authenticate_user!
    layout "marketing"

    def new
      @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'
    end
  end
end
