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
   npm install
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
   npm run build:css
   npm run build
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

### Production / Render environment variables

Render deployments must not rely on local disk for uploads. Set these variables in Render (or your production environment):

- `RAILS_MASTER_KEY` (required)
- `APP_HOST` (public host, e.g., https://your-app.onrender.com)
- `ACTIVE_STORAGE_SERVICE` (optional, defaults to `amazon`)
- `AWS_S3_BUCKET` (required)
- `AWS_ACCESS_KEY_ID` (required)
- `AWS_SECRET_ACCESS_KEY` (required)
- `AWS_REGION` (defaults to `us-east-1`)
- `AWS_S3_ENDPOINT` (optional, e.g., for R2 or MinIO)
- `AWS_S3_FORCE_PATH_STYLE` (optional, set to `true` if your provider requires it)
- `SENDGRID_API_KEY` (optional; set to send real emails)
- `SENDGRID_DOMAIN` (optional, defaults to `APP_HOST` or `rem.com`)
- `DEFAULT_FROM_EMAIL` (recommended when enabling email delivery)

### Email delivery (SendGrid)

- Email is optional; deployments will succeed without SendGrid variables.
- To send real emails on Render, set `SENDGRID_API_KEY` and `DEFAULT_FROM_EMAIL`.
- Without those variables, the app will deploy but emails will not be delivered.

## Running the Application

### Development

**Important:** Make sure Redis is running before starting the app:

```bash
# Check if Redis is running
redis-cli ping
# Should return: PONG

# If not running, start Redis:
# macOS (Homebrew):
brew services start redis
# Or manually:
redis-server

# Linux:
sudo systemctl start redis
# Or:
redis-server
```

Then start the application:

```bash
# Start the application (includes Rails, Sidekiq, and asset watchers)
bin/dev

# Or run separately:
rails server
sidekiq
```

**Note:** Redis is required for:
- Idempotency tokens (prevents duplicate redemptions)
- Background job processing (Sidekiq)
- Caching

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

For development, you **MUST** use the Stripe CLI to forward webhooks to your local server.
Without this, Stripe cannot notify your app when payments complete, and gift cards won't be created.

### Quick Start

```bash
# Option 1: Use the helper script
bin/stripe-webhook

# Option 2: Run directly
stripe listen --forward-to http://localhost:3000/webhooks/stripe
```

### Important Steps

1. **Install Stripe CLI** (if not already installed):
   ```bash
   # macOS
   brew install stripe/stripe-cli/stripe
   
   # Or download from: https://stripe.com/docs/stripe-cli
   ```

2. **Login to Stripe CLI**:
   ```bash
   stripe login
   ```

3. **Start webhook forwarding** (in a separate terminal):
   ```bash
   bin/stripe-webhook
   # OR
   stripe listen --forward-to http://localhost:3000/webhooks/stripe
   ```

4. **Copy the webhook signing secret**:
   - When you run `stripe listen`, it will output a webhook signing secret like: `whsec_...`
   - Copy this value to your `.env` file as `STRIPE_WEBHOOK_SECRET=whsec_...`
   - **Restart your Rails server** after updating the env var

5. **Verify it's working**:
   - Check your Rails logs - you should see `🔔 Stripe webhook received` messages
   - After completing a test payment, check logs for gift card creation

### Troubleshooting

- **No webhooks received?** Make sure `stripe listen` is running in a separate terminal
- **Invalid signature errors?** Check that `STRIPE_WEBHOOK_SECRET` in `.env` matches the secret from `stripe listen`
- **Webhooks not creating gift cards?** Check Rails logs for detailed error messages

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
- **Merchant 2**: merchant2@example.com / password123
- **User**: user@example.com / password123

## Merchant Redemption API

1. **Run migrations**

   ```bash
   bin/rails db:migrate
   ```

2. **Seed development data (rotates demo API keys & prints secrets in `log/development.log`)**

   ```bash
   bin/rails db:seed
   ```

3. **Generate a rotating token from the recipient UI**  
   (Use the existing gift card page to issue a fresh code/QR and copy the raw token that the recipient sees.)

4. **Redeem via curl**

   ```bash
   curl -X POST http://localhost:3000/api/v1/redemptions \
     -H "Authorization: Bearer <MERCHANT_SECRET_KEY>" \
     -H "Content-Type: application/json" \
     -d '{
       "token":"<RAW_TOKEN>",
       "amount_cents":500,
       "idempotency_key":"test-uuid-1"
     }'
   ```

5. **Retrieve the redemption later**

   ```bash
   curl -X GET http://localhost:3000/api/v1/redemptions/<ID> \
     -H "Authorization: Bearer <MERCHANT_SECRET_KEY>"
   ```

6. **Refund a successful redemption (full refund)**

   **Note:** this refunds **100% of the redemption transaction amount** (no partial refunds yet).

   ```bash
   curl -X POST http://localhost:3000/api/v1/redemptions/<ID>/refund \
     -H "Authorization: Bearer <MERCHANT_SECRET_KEY>" \
     -H "Content-Type: application/json" \
     -d '{
       "idempotency_key":"refund-uuid-1",
       "reason":"customer asked"
     }'
   ```

Approved/declined redemption responses both return `200 OK` with an `approved` boolean, the resulting balances, and an optional `decline_reason`. Refund responses return `200 OK` with `refund_transaction_id`, `original_transaction_id`, and the restored `remaining_balance_cents`. Suspended or unknown merchants receive `403/401`, and malformed input returns `422`.

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