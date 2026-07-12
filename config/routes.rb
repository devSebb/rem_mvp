Rails.application.routes.draw do
  devise_for :users, controllers: { registrations: 'registrations' }
  
  root to: "marketing#landing"
  get "about", to: "marketing#about", as: :about
  get "contact", to: "marketing#contact", as: :contact
  get "proximamente", to: "marketing#proximamente", as: :proximamente
  
  get "home", to: "home#index", as: :home
  
  # Legal Hub routes
  get "legal", to: "legal#index", as: :legal
  get "legal/terminos", to: "legal#terminos", as: :legal_terminos
  get "legal/privacidad", to: "legal#privacidad", as: :legal_privacidad
  get "legal/tarjetas-regalo", to: "legal#tarjetas_regalo", as: :legal_tarjetas_regalo
  get "legal/pagos-reembolsos", to: "legal#pagos_reembolsos", as: :legal_pagos_reembolsos
  get "legal/uso-aceptable", to: "legal#uso_aceptable", as: :legal_uso_aceptable
  get "legal/eliminacion-datos", to: "legal#eliminacion_datos", as: :legal_eliminacion_datos

  # Public account-deletion landing page. Required by Google Play; provides
  # instructions for users to delete their account via the mobile app or
  # by emailing support. The actual deletion runs through Users::DeleteAccount.
  get "eliminar-cuenta", to: "users/deletion_requests#new", as: :delete_account

  # Web purchase flow removed — purchases are done exclusively through the
  # mobile app. Web wallet (index/show) and transfers remain available.
  resources :gift_cards, only: [:index, :show] do
    resources :transfers, only: [:new, :create] do
      get :confirm, on: :collection
      post :process_transfer, on: :collection
    end
  end

  namespace :api do
    namespace :v1 do
      resources :gift_cards, only: [] do
        resource :redemption_token, only: :create, module: :gift_cards
      end

      post "gift_cards/validate", to: "gift_cards#validate"
      get  "gift_cards/:token",   to: "gift_cards#show"

      # Kept path for backwards compatibility; now backed by Transaction records.
      resources :redemptions, only: [:create, :show] do
        post :refund, on: :member
      end

      namespace :auth do
        post :signup, to: "registrations#create"
        post :login, to: "sessions#login"
        post :refresh, to: "sessions#refresh"
        post :logout, to: "sessions#logout"
        post :logout_all, to: "sessions#logout_all"
        post :forgot_password, to: "passwords#forgot_password"
        post :reset_password, to: "passwords#reset_password"
      end

      get "me", to: "me#show"
      patch "me", to: "me#update"
      delete "me", to: "me#destroy"
      get "me/deletion_preview", to: "me#deletion_preview"
      post "checkout/validate_kyc", to: "checkout#validate_kyc"
      post "checkout/quote", to: "checkout#quote"
      post "checkout/payment_intent", to: "checkout#payment_intent"

      # Public remote config (fees, limits, kill switches, min app versions)
      get "config", to: "config#show"

      # Mobile post-checkout polling: returns the buyer's gift card for a
      # Stripe payment intent once the webhook has created it (404 until then).
      get "gift_cards/by_payment_intent/:payment_intent_id", to: "me/gift_cards#by_payment_intent"

      namespace :me do
        resources :gift_cards, only: [:index, :show] do
          post :redemption_token, on: :member
        end
        resource :push_tokens, only: [:create, :destroy]
      end

      post "me/avatar", to: "me/avatars#create"
      resources :merchants, only: [:index, :show]
      post "merchants/:id/logo", to: "merchants#upload_logo"

      namespace :public do
        resources :merchants, only: [:index, :show]
      end
    end
  end

  # Public merchant profile (for regular users browsing)
  resources :merchants, only: [:show]

  namespace :webhooks do
    post :stripe, to: "stripe#receive"
    post :twilio_status, to: "twilio#status"
  end

  # Gift card redemption routes (removed - using direct merchant redemption only)

  namespace :merchant do
    root to: "dashboard#index"
    resources :redemptions, only: [:new, :create] do
      get :confirm, on: :collection
      post :redeem, on: :collection
      get :success, on: :collection
    end
    resources :gift_cards, only: [:show] do
      post "transactions/:transaction_id/refund", to: "transactions#refund", as: :refund_transaction
    end
    resources :settlements, only: [:index, :show]
    resource :profile, only: [:show, :update]
  end

  namespace :admin do
    root to: "dashboard#index"
    resources :users, only: [:index, :show]
    resources :merchants, only: [:index, :new, :create, :show, :edit, :update, :destroy] do
      member do
        patch :suspend
        patch :reactivate
        post :regenerate_secret
      end
    end
    resources :gift_cards, only: [] do
      resources :refunds, only: [:new, :create], path: 'refund'
    end
    resources :payouts, only: [:index, :show, :create] do
      member { post :mark_paid }
    end
    resources :holds, only: [:index] do
      member { post :release }
    end
    resource :platform_settings, only: [:show, :update]
  end

  # Mount Sidekiq web interface at /sidekiq (admin only)
  mount Sidekiq::Web => '/sidekiq', constraints: ->(request) { 
    request.env['warden'].user&.admin? 
  }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
