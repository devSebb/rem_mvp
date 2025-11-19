# Troubleshooting Guide: Gift Card Notifications

## Issue: Recipient Not Receiving Gift Cards

If you're experiencing issues where gift cards are purchased successfully but recipients don't receive notifications, follow these steps:

## 🔍 Root Cause Analysis

The most common issue is that **Stripe webhooks are not being forwarded to your local development server**. Without webhooks, your app never knows that a payment completed, so it never creates the gift card or sends notifications.

## ✅ Quick Fix Checklist

### 1. Start Stripe Webhook Forwarding

**This is the most critical step!** Without this, webhooks never reach your app.

```bash
# Option 1: Use the helper script
bin/stripe-webhook

# Option 2: Run directly
stripe listen --forward-to http://localhost:3000/webhooks/stripe
```

**Important:** Keep this running in a separate terminal while testing!

### 2. Set Webhook Secret

When you run `stripe listen`, it will output a webhook signing secret like:
```
> Ready! Your webhook signing secret is whsec_xxxxxxxxxxxxx
```

Copy this value to your `.env` file:
```bash
STRIPE_WEBHOOK_SECRET=whsec_xxxxxxxxxxxxx
```

**Restart your Rails server** after updating the env var.

### 3. Verify Webhooks Are Being Received

Check your Rails logs. You should see messages like:
```
🔔 Stripe webhook received: evt_xxxxx
✅ Webhook signature verified. Processing event: checkout.session.completed
✅ Found sender: sender@test.com (ID: 1)
✅ Found/created recipient: recipient@test.com (ID: 2)
✅ Created gift card 123 for session cs_test_xxxxx
📤 Sent notification for gift card 123
```

If you don't see these messages, webhooks aren't being received.

### 4. Check Notification Delivery

After a successful webhook, check logs for:
```
📧 Sending notifications for gift card 123 to recipient@test.com
   ✓ Email sent successfully
```

If you see errors, check:
- **Email**: Check `tmp/mail/` directory for file-based delivery in development
- **SMS/WhatsApp**: Verify Twilio credentials are set correctly

## 🐛 Common Issues & Solutions

### Issue: "Invalid Stripe webhook signature"

**Solution:**
1. Make sure `STRIPE_WEBHOOK_SECRET` in `.env` matches the secret from `stripe listen`
2. Restart your Rails server after updating the env var
3. Make sure you're using the correct Stripe account (test vs live)

### Issue: "No webhooks received"

**Solution:**
1. Verify `stripe listen` is running in a separate terminal
2. Check that it's forwarding to the correct URL: `http://localhost:3000/webhooks/stripe`
3. Make sure your Rails server is running on port 3000
4. Try triggering a test event: `stripe trigger checkout.session.completed`

### Issue: "Gift card created but no notification sent"

**Solution:**
1. Check Rails logs for notification errors
2. Verify recipient has email or phone number
3. Check if Sidekiq is running (notifications will still work without it, but slower)
4. For email: Check `tmp/mail/` directory in development
5. For SMS: Verify Twilio credentials in `.env`

### Issue: "Recipient not found"

**Solution:**
1. Verify the recipient email/phone in the database matches what you entered
2. Check logs for: `🔍 Looking for recipient with email: recipient@test.com`
3. The system will create a new user if recipient doesn't exist, but they need email or phone

## 📊 Debugging Steps

### Step 1: Check Webhook Reception

```bash
# In Rails console
tail -f log/development.log | grep "Stripe webhook"
```

You should see webhook events when payments complete.

### Step 2: Check Gift Card Creation

```bash
# In Rails console
rails console
> GiftCard.last
> GiftCard.last.recipient
```

Verify the gift card exists and has a recipient.

### Step 3: Check Notification Status

```bash
# In Rails console
gc = GiftCard.last
gc.sent_via_email  # Should be true if email was sent
gc.sent_via_sms    # Should be true if SMS was sent
```

### Step 4: Manually Trigger Notification

If gift card exists but notification wasn't sent:

```ruby
# In Rails console
gc = GiftCard.find_by(checkout_session_id: 'cs_test_xxxxx')
raw_code = gc.generate_code!
NotificationJob.perform_now(gc.id, raw_code)
```

## 🔧 Testing the Complete Flow

1. **Start all services:**
   ```bash
   # Terminal 1: Rails server
   bin/dev
   
   # Terminal 2: Stripe webhook forwarding
   bin/stripe-webhook
   ```

2. **Make a test purchase:**
   - Login as sender@test.com
   - Go to "Buy Gift Card"
   - Enter recipient@test.com as recipient
   - Complete Stripe checkout with test card: `4242 4242 4242 4242`

3. **Check logs:**
   - Webhook received ✅
   - Gift card created ✅
   - Notification sent ✅

4. **Verify delivery:**
   - Email: Check `tmp/mail/` directory
   - SMS: Check Twilio logs (if configured)

## 📝 Enhanced Logging

The app now includes detailed logging with emojis for easy scanning:
- 🔔 Webhook received
- ✅ Success operations
- ❌ Errors
- ⚠️ Warnings
- 📤 Notifications
- 📧 Email operations

Check your `log/development.log` for these markers.

## 🆘 Still Having Issues?

1. **Check all logs** - Both Rails and Stripe CLI output
2. **Verify environment variables** - All required vars should be set
3. **Test with Stripe CLI** - `stripe trigger checkout.session.completed`
4. **Check database** - Verify users and gift cards exist
5. **Review recent changes** - Make sure nothing broke the flow

## 📚 Additional Resources

- [Stripe CLI Documentation](https://stripe.com/docs/stripe-cli)
- [Stripe Webhooks Guide](https://stripe.com/docs/webhooks)
- See `README.md` for full setup instructions

