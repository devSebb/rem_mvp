require "rails_helper"

# Web sessions can view the wallet and mint redemption codes, and gifts are
# routed by email, so a consumer needs a PROVEN email to sign in on the web.
RSpec.describe "Web sign-in requires a verified email", type: :request do
  include Devise::Test::IntegrationHelpers

  def web_login(email, password)
    post user_session_path, params: { user: { email: email, password: password } }
  end

  it "web sign-up no longer auto-verifies or signs the user in" do
    post user_registration_path, params: {
      user: { email: "websignup@example.com", password: "Password!23", password_confirmation: "Password!23",
              first_name: "W", last_name: "S", phone: "+593990000050" }
    }

    user = User.find_by(email: "websignup@example.com")
    expect(user).to be_present
    expect(user).not_to be_email_verified
    expect(flash[:notice]).to include("app Papayal")

    get edit_user_registration_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "refuses web sign-in for an unverified consumer, with guidance" do
    User.create!(email: "unver@example.com", password: "Password!23", password_confirmation: "Password!23",
                 first_name: "U", last_name: "V", phone: "+593990000051", require_email_verification: true)

    web_login("unver@example.com", "Password!23")
    follow_redirect!

    expect(response.body).to include("Confirma tu correo")
    get edit_user_registration_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "allows a verified consumer" do
    create(:user, email: "ok@example.com", password: "Password!23", password_confirmation: "Password!23")
    web_login("ok@example.com", "Password!23")
    get edit_user_registration_path
    expect(response).to have_http_status(:ok)
  end

  it "exempts merchant and admin accounts (created by admins)" do
    merchant_user = create(:user, role: :merchant, email: "m@example.com", password: "Password!23",
                                  password_confirmation: "Password!23")
    merchant_user.update_columns(email_verified_at: nil)
    create(:merchant, user: merchant_user)

    web_login("m@example.com", "Password!23")
    get merchant_root_path
    expect(response).to have_http_status(:ok)
  end

  it "changing the email on the web drops verification (and the web session)" do
    user = create(:user, email: "before@example.com", password: "Password!23", password_confirmation: "Password!23")
    sign_in user

    put user_registration_path, params: { user: { email: "after@example.com", current_password: "Password!23" } }

    user.reload
    expect(user.email).to eq("after@example.com")
    expect(user).not_to be_email_verified
    get edit_user_registration_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "keeps verification for a case-only email change" do
    user = create(:user, email: "case@example.com")
    user.update!(email: "CASE@example.com")
    expect(user.reload).to be_email_verified
  end
end
