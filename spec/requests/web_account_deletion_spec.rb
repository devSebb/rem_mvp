require "rails_helper"

RSpec.describe "Web account deletion", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user, password: "Password!23", password_confirmation: "Password!23") }

  it "requires the current password and leaves the account intact without it" do
    sign_in user
    delete user_registration_path, params: { user: { current_password: "wrong-password" } }

    expect(response).to redirect_to(edit_user_registration_path)
    expect(User.find(user.id)).not_to be_deleted
  end

  it "soft-deletes and anonymizes through Users::DeleteAccount (never a hard delete)" do
    original_email = user.email
    sign_in user
    delete user_registration_path, params: { user: { current_password: "Password!23" } }

    expect(response).to redirect_to(root_path)
    reloaded = User.find(user.id) # row still exists
    expect(reloaded).to be_deleted
    expect(reloaded.email).not_to eq(original_email)
  end

  it "refuses to delete merchant accounts from the web" do
    merchant_user = create(:user, role: :merchant, password: "Password!23", password_confirmation: "Password!23")
    create(:merchant, user: merchant_user)
    sign_in merchant_user

    delete user_registration_path, params: { user: { current_password: "Password!23" } }
    expect(User.find(merchant_user.id)).not_to be_deleted
  end
end
