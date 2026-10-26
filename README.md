# WaterEase — setup guide

WaterEase is a mobile-friendly HTML/CSS/JavaScript frontend connected to Supabase for authentication, PostgreSQL storage, row-level security, and realtime subscriptions.

## Files
- `index.html` — full customer and administrator interface
- `supabase.sql` — database schema, RLS policies, ordering RPCs, status history, notifications, realtime publication setup, starter products and delivery slots

## 1. Create Supabase project
1. Create a project at https://supabase.com/.
2. Open **Project Settings → API** (or the API Keys page).
3. Copy the Project URL and the publishable/anon public key.
4. Open `index.html` and replace:
   - `YOUR_SUPABASE_PROJECT_URL`
   - `YOUR_SUPABASE_ANON_OR_PUBLISHABLE_KEY`
5. Never use a `service_role` or secret key in `index.html`.

## 2. Create database
1. In Supabase, open **SQL Editor → New query**.
2. Paste all of `supabase.sql` and run it.
3. Review any SQL error before proceeding. The script uses `pgcrypto`, creates the tables and functions, applies RLS, enables Realtime publication for relevant tables, and inserts starter products and future time slots.
4. Update the seeded product prices to match the actual refill station. Starter prices are examples and must be confirmed before real customer use.

## 3. Register and promote the administrator
1. Open `index.html` through a local web server (see section 5) and create your own account.
2. Confirm the email if Supabase email confirmation is enabled.
3. In Supabase SQL Editor, run this command with your exact registered email:
   `update public.users set role='admin' where email='YOUR_LOGIN_EMAIL';`
4. Log out and log in again so the frontend reloads the role.
5. Never allow users to choose the admin role during signup. New accounts are always `student`; only a trusted project owner should promote an admin in the database.

## 4. Authentication settings
- In **Authentication → URL Configuration**, add your local development URL and your deployed site URL to Site URL / Redirect URLs as appropriate.
- For email confirmation, configure SMTP for production. Supabase's default email service may have rate limits.
- Password reset uses the current page URL as the redirect. Add that URL to allowed redirect URLs.
- Set suitable password and session policies in Supabase Auth.

## 5. Run the frontend
Recommended: use VS Code with the Live Server extension, or run a local static server from this folder:
- Python: `python -m http.server 8000`
- Then open `http://localhost:8000` in your browser.
Opening the file directly with `file://` may cause auth redirect or browser restrictions.

## 6. Realtime and notifications
- Realtime subscriptions listen for actual Postgres changes to `orders`, `notifications`, `products`, and `delivery_schedules`. In-app updates refresh the view without a manual reload.
- Order notifications are inserted by database RPC functions during order creation, cancellation, and admin status updates. A unique index prevents duplicate notification events per order/recipient/event key.
- Browser push notifications are optional and only shown if the user has already granted browser permission. This project does not automatically request permission or send notifications while the browser is closed.
- True background push requires a service worker plus a push provider (such as Web Push/VAPID or Firebase Cloud Messaging) and secure HTTPS deployment.
- Delivery reminders before a scheduled slot require a scheduled server-side task, e.g. Supabase Edge Function + Supabase Cron/pg_cron. Configure the schedule and push/email/SMS provider credentials separately. No reminder is falsely shown as implemented by this starter.
- Email and SMS are not configured by default.

## 7. Security notes
- Customers can read only their own orders, notifications, and order history; admin policies allow staff to view/manage the administrative resources.
- Orders are created by `place_water_order`, which reads the product price from the database and locks the delivery slot while decrementing capacity to prevent overbooking.
- Status changes and customer cancellations use database RPC functions and write status history and notifications.
- Frontend validation is convenience only; database constraints and functions enforce core quantity, price, slot, and role checks.
- RLS is enabled. Never disable it to make the app “work.”
- Have a qualified developer review the policies and workflow before handling real student/customer data.

## 8. Test checklist
1. Register a student account and confirm it.
2. Log in, select a product, select an available slot, and submit an order.
3. Check that the total equals database unit price × quantity.
4. Open a separate browser/session and log in with the promoted admin account.
5. Open Manage Orders and change the status in a valid sequence: Pending → Confirmed → Preparing → Out for Delivery → Delivered.
6. Confirm the student session updates and receives a saved notification without refreshing.
7. Test cancellation while the order is Pending and verify slot capacity returns.
8. Try ordering from a full/closed slot and verify the database rejects it.
9. Verify a student cannot see another customer's orders by signing into a separate student account.
10. Test on phone and desktop screen sizes.

## Known scope / production follow-up
- The app provides responsive UI, auth, products, order placement, admin status changes, in-app notifications, saved notification history, profile editing, order history, reorder, and delivery-slot capacity checks.
- The admin interface supports creating/closing/deleting delivery slots and creating/editing product details.
- Rejection reason currently uses the admin status remarks field; the current UI uses a general remarks value for status updates. Add a dedicated rejection-reason prompt before production use.
- Browser notification display works only while the site is open and the browser has granted notification permission. Background push and scheduled reminders need a server-side function and provider setup.
- This is a complete starter implementation, but it has not been connected to your personal Supabase project or tested against your live credentials. Do not represent external-service-dependent features as live until configured and tested.
