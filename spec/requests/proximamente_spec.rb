require "rails_helper"

RSpec.describe "Coming soon page and consumer web gating", type: :request do
  describe "GET /proximamente" do
    it "is publicly accessible" do
      get "/proximamente"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Muy pronto")
    end

    it "renders for signed-in consumers with the account-ready notice" do
      sign_in create(:user)

      get "/proximamente"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Tu cuenta ya está lista")
    end

    it "gives signed-in consumers a way out (sign out)" do
      sign_in create(:user)

      get "/proximamente"
      # Without a logout, a signed-in consumer is trapped: every consumer
      # page redirects back here and the marketing navbar used to offer
      # only Sign In / Sign Up.
      expect(response.body).to include("Cerrar sesión")
      expect(response.body).to include("Cerrar Sesión") # navbar button

      delete destroy_user_session_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end
  end

  describe "consumer web gating" do
    let(:consumer) { create(:user) }

    it "redirects consumers away from home" do
      sign_in consumer

      get home_path

      expect(response).to redirect_to(proximamente_path)
    end

    it "redirects consumers away from the web wallet" do
      sign_in consumer

      get gift_cards_path

      expect(response).to redirect_to(proximamente_path)
    end

    it "redirects consumers away from web merchant profiles" do
      merchant = create(:merchant)
      sign_in consumer

      get merchant_path(merchant)

      expect(response).to redirect_to(proximamente_path)
    end

    it "redirects consumers to the coming soon page after sign-in" do
      post user_session_path, params: { user: { email: consumer.email, password: "password123" } }

      expect(response).to redirect_to(proximamente_path)
    end

    it "redirects signed-in consumers from the marketing landing to the coming soon page" do
      sign_in consumer

      get root_path

      expect(response).to redirect_to(proximamente_path)
    end

    it "sends admins from home to the command center" do
      sign_in create(:user, role: :admin)

      get home_path

      expect(response).to redirect_to(admin_root_path)
    end

    it "keeps wallet access for admins" do
      sign_in create(:user, role: :admin)

      get gift_cards_path

      expect(response).to have_http_status(:ok)
    end

    it "sends merchants to their portal after sign-in" do
      merchant_user = create(:user, role: :merchant)
      create(:merchant, user: merchant_user)

      post user_session_path, params: { user: { email: merchant_user.email, password: "password123" } }

      expect(response).to redirect_to(merchant_root_path)
    end
  end
end
