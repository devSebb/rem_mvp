# Secure Gift Card Notification & Redemption System

This document describes the complete secure notification and redemption system implemented for the REM gift card application.

## 🔐 Security Features

### Token Generation
- **Link Token**: 32-byte urlsafe base64 token (7-day expiry)
- **OTP Code**: 6-digit numeric code (1-hour expiry)
- **Storage**: Only BCrypt digests stored in database
- **Single Use**: Tokens are consumed after successful redemption

### Database Schema
The following fields were added to the `gift_cards` table:
- `link_token_digest` (string, unique)
- `link_token_expires_at` (datetime)
- `otp_digest` (string, unique)
- `otp_expires_at` (datetime)
- `sent_via_whatsapp` (boolean, default: false)
- `sent_via_sms` (boolean, default: false)
- `sent_via_email` (boolean, default: false)

## 📱 Notification Channels

### WhatsApp
- Uses Twilio WhatsApp API
- Sends formatted message with gift card details
- Includes secure redemption link and OTP code

### SMS
- Uses Twilio SMS API
- Sends concise message with essential details
- Includes secure redemption link and OTP code

### Email
- Uses ActionMailer with SendGrid
- Beautiful HTML template with QR code
- Plain text fallback
- Includes all redemption details and instructions

## 🚀 Usage

### Triggering Notifications
```ruby
# After creating a gift card with a recipient
gift_card = GiftCard.create!(
  sender: current_user,
  recipient: recipient_user,
  amount: 5000, # $50.00 in cents
  currency: 'USD'
)

# Send notifications via all available channels
gift_card.send_notifications!
```

### Manual Token Generation
```ruby
# Generate tokens manually
tokens = gift_card.generate_delivery_tokens!
# Returns: { link: "raw_link_token", otp: "123456" }

# Validate tokens
gift_card.valid_link_token?(raw_token)
gift_card.valid_otp?(raw_otp)

# Consume tokens (single-use)
gift_card.consume_link_token!
gift_card.consume_otp!
```

## 🔧 Configuration

### Required Environment Variables
```bash
# Twilio Configuration
TWILIO_ACCOUNT_SID=your_twilio_account_sid
TWILIO_AUTH_TOKEN=your_twilio_auth_token
TWILIO_PHONE_NUMBER=+1234567890
TWILIO_WHATSAPP_NUMBER=+1234567890

# Email Configuration
SENDGRID_API_KEY=your_sendgrid_api_key
DEFAULT_FROM_EMAIL=noreply@yourdomain.com

# App Configuration
APP_HOST=http://localhost:3000
```

### Gems Required
- `twilio-ruby` - For SMS and WhatsApp
- `sendgrid-ruby` - For email delivery
- `rqrcode` - For QR code generation
- `sidekiq` - For background job processing

## 🛣️ Routes

```ruby
# Redemption routes
get '/redeem', to: 'redeems#show'
post '/redeem/claim', to: 'redeems#claim'
get '/redeem/success', to: 'redeems#success'

# Webhook routes
post '/webhooks/twilio/status', to: 'webhooks#twilio#status'
```

## 📋 Redemption Flow

1. **Recipient receives notification** via WhatsApp/SMS/Email
2. **Clicks secure link** with embedded token
3. **Enters 6-digit OTP** code
4. **Selects merchant** for redemption
5. **Submits form** for processing
6. **Tokens are consumed** after successful redemption
7. **Success page** shows confirmation

## 🔄 Background Jobs

### SendGiftCardNotificationsJob
- Processes notification delivery asynchronously
- Handles all three channels (WhatsApp, SMS, Email)
- Updates delivery status flags
- Logs results and errors

## 📧 Email Templates

### HTML Template
- Responsive design with Tailwind CSS
- Gift card amount prominently displayed
- QR code for easy mobile redemption
- Clear expiry information
- Step-by-step redemption instructions

### Text Template
- Plain text fallback
- All essential information included
- Mobile-friendly format

## 🛡️ Security Considerations

1. **Token Expiry**: Link tokens expire in 7 days, OTP codes in 1 hour
2. **Single Use**: Tokens are consumed after successful redemption
3. **BCrypt Hashing**: Only hashed versions stored in database
4. **Validation**: Comprehensive token validation before redemption
5. **Rate Limiting**: Can be implemented via Rack::Attack

## 🧪 Testing

### Development Testing
```ruby
# In Rails console
gift_card = GiftCard.first
gift_card.send_notifications!

# Check delivery status
gift_card.sent_via_whatsapp? # => true/false
gift_card.sent_via_sms?      # => true/false
gift_card.sent_via_email?    # => true/false
```

### Manual Testing
1. Create a gift card with recipient
2. Trigger notifications
3. Check all delivery channels
4. Test redemption flow
5. Verify token consumption

## 🚨 Error Handling

- **Missing Recipient**: Job fails gracefully with logging
- **Invalid Tokens**: Clear error messages for users
- **Expired Tokens**: Automatic expiry checking
- **Delivery Failures**: Individual channel failures don't block others
- **Webhook Processing**: Twilio status webhooks for delivery tracking

## 📊 Monitoring

- **Delivery Status**: Track which channels succeeded/failed
- **Token Usage**: Monitor token generation and consumption
- **Error Logging**: Comprehensive error logging for debugging
- **Webhook Logs**: Twilio delivery status tracking

## 🔮 Future Enhancements

1. **Retry Logic**: Automatic retry for failed deliveries
2. **Admin Dashboard**: Monitor delivery status and failures
3. **Analytics**: Track redemption rates and channel effectiveness
4. **Custom Templates**: Allow merchants to customize messages
5. **Bulk Notifications**: Send to multiple recipients
6. **Delivery Preferences**: Let users choose preferred channels
