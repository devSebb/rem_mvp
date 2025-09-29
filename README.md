# Gift Card MVP

A production-lean MVP for buying and sending gift cards, with merchant redemption capabilities.

## Features

- **User Management**: Sign up, login, and role-based access (user, merchant, admin)
- **Gift Card Purchase**: Buy gift cards with Stripe payment processing
- **Gift Card Delivery**: Automatic SMS/WhatsApp notifications with secure codes
- **Merchant Portal**: Dedicated interface for merchants to redeem gift cards
- **QR Code Support**: Generate QR codes for easy redemption
- **Transaction Tracking**: Complete audit trail of all gift card activities
- **Settlement Management**: Track merchant payouts and settlements

## Tech Stack

- **Ruby 3.3.x** with **Rails 7.1.x**
- **PostgreSQL 14+** for data persistence
- **Redis** for Sidekiq background jobs
- **Stripe** for payment processing
- **Twilio** for SMS/WhatsApp notifications
- **Tailwind CSS** for styling
- **Pundit** for authorization
- **RSpec** for testing

## Setup

### Prerequisites

- Ruby 3.3.x
- PostgreSQL 14+
- Redis
- Node.js (for asset compilation)

### Installation

1. **Clone and install dependencies:**
   ```bash
   git clone <repository-url>
   cd rem_mvp
   bundle install
   yarn install
   ```

2. **Set up environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env with your actual values
   ```

3. **Configure database:**
   ```bash
   rails db:create
   rails db:migrate
   rails db:seed
   ```

4. **Build assets:**
   ```bash
   yarn build:css
   yarn build
   ```

### Environment Variables

Required environment variables (see `.env.example`):

```bash
# Stripe Configuration
STRIPE_SECRET_KEY=sk_test_...
STRIPE_PUBLISHABLE_KEY=pk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...

# Twilio Configuration
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...
TWILIO_FROM_NUMBER=+1234567890

# Application Configuration
APP_HOST=http://localhost:3000
DEFAULT_CURRENCY=USD

# Database Configuration
DATABASE_URL=postgresql://localhost/rem_mvp_development

# Redis Configuration
REDIS_URL=redis://localhost:6379/0
```

## Running the Application

### Development

```bash
# Start the application
bin/dev

# Or run separately:
rails server
sidekiq
```

### Production

```bash
# Using foreman
foreman start

# Or using individual processes
rails server -e production
sidekiq -e production
```

## Testing

```bash
# Run all tests
bundle exec rspec

# Run specific test files
bundle exec rspec spec/models/gift_card_spec.rb
```

## Stripe Webhook Setup

For development, use the Stripe CLI to forward webhooks:

```bash
stripe listen --forward-to http://localhost:3000/webhooks/stripe
```

Copy the webhook signing secret to your `.env` file.

## Manual Testing Plan

### 1. User Registration & Login
- [ ] Register new user account
- [ ] Login with existing credentials
- [ ] Verify role-based navigation

### 2. Gift Card Purchase Flow
- [ ] Navigate to "Buy Gift Card"
- [ ] Fill out gift card form (amount, recipient, store)
- [ ] Complete Stripe checkout
- [ ] Verify webhook processing creates gift card
- [ ] Check SMS/email notification (check logs)

### 3. Merchant Redemption
- [ ] Login as merchant user
- [ ] Navigate to merchant portal
- [ ] Use "Redeem Gift Card" with gift card code
- [ ] Verify confirmation screen shows correct details
- [ ] Complete redemption
- [ ] Check transaction is recorded

### 4. Gift Card Management
- [ ] View gift card wallet
- [ ] Check gift card details and QR code
- [ ] Verify status updates (active/redeemed/expired)

### 5. Admin Functions
- [ ] Access Sidekiq dashboard at `/sidekiq`
- [ ] View settlement reports
- [ ] Monitor transaction logs

## Demo Credentials

After running `rails db:seed`:

- **Admin**: admin@example.com / password123
- **Merchant**: merchant@example.com / password123  
- **User**: user@example.com / password123

## Security Notes

### Code Security
- Gift card codes are generated using secure base32 alphabet (no confusing characters)
- Raw codes are never stored in the database - only bcrypt hashes
- Codes are only revealed via SMS/email notifications
- QR codes in the UI show masked information for security

### Rate Limiting
- Rack::Attack configured with IP-based throttling
- Login attempts limited to 5 per 20 minutes per IP/email
- Merchant redemption attempts limited to 10 per minute per IP
- Webhook endpoints throttled to prevent abuse

### Authorization
- Pundit policies enforce role-based access control
- Merchant portal restricted to merchant users only
- Admin functions (Sidekiq) restricted to admin users
- Gift card access limited to sender/recipient/admins

### Data Protection
- All sensitive data encrypted at rest
- Audit trail maintained for all transactions
- User data minimal (name, email, phone only)
- No storage of payment card details (handled by Stripe)

## API Endpoints

### Gift Cards
- `GET /gift_cards` - List user's gift cards
- `GET /gift_cards/:id` - Show gift card details
- `POST /gift_cards/checkout` - Create Stripe checkout session
- `GET /gift_cards/success` - Payment success page
- `GET /gift_cards/cancel` - Payment cancellation page

### Merchant Portal
- `GET /merchant` - Merchant dashboard
- `GET /merchant/redemptions/new` - Redeem gift card form
- `POST /merchant/redemptions` - Process redemption
- `POST /merchant/redemptions/confirm` - Confirm redemption
- `GET /merchant/settlements` - View settlements
- `GET /merchant/profile` - Merchant profile

### Webhooks
- `POST /webhooks/stripe` - Stripe webhook handler

## Deployment

The application is configured for deployment on:
- **Render** (recommended)
- **Fly.io**
- **Heroku**

Use the provided `Procfile` for process management.

## License

Private - All rights reserved.