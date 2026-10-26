-- WaterEase database setup for Supabase PostgreSQL
-- Run this whole script in Supabase Dashboard > SQL Editor.
-- Review the admin promotion step at the end. Do NOT put service_role keys in the browser.

create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('student','admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.water_order_status as enum ('Pending','Confirmed','Preparing','Out for Delivery','Delivered','Cancelled','Rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.delivery_slot_status as enum ('Open','Closed');
exception when duplicate_object then null; end $$;

create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 100),
  email text not null default '',
  phone text not null default '' check (char_length(phone) <= 30),
  delivery_address text not null default '' check (char_length(delivery_address) <= 500),
  role public.user_role not null default 'student',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  product_name text not null check (char_length(product_name) between 1 and 100),
  container_type text not null check (char_length(container_type) between 1 and 100),
  price numeric(10,2) not null check (price > 0),
  is_available boolean not null default true,
  description text not null default '' check (char_length(description) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.delivery_schedules (
  id uuid primary key default gen_random_uuid(),
  delivery_date date not null,
  time_slot text not null check (char_length(time_slot) between 1 and 80),
  max_capacity integer not null check (max_capacity between 1 and 200),
  available_capacity integer not null check (available_capacity between 0 and max_capacity),
  status public.delivery_slot_status not null default 'Open',
  created_at timestamptz not null default now(),
  unique(delivery_date,time_slot)
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('WE-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  customer_id uuid not null references public.users(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  schedule_id uuid references public.delivery_schedules(id) on delete set null,
  quantity integer not null check (quantity between 1 and 30),
  unit_price numeric(10,2) not null check (unit_price > 0),
  total_amount numeric(12,2) generated always as (quantity * unit_price) stored,
  delivery_address text not null check (char_length(delivery_address) between 1 and 500),
  phone text not null default '' check (char_length(phone) <= 30),
  scheduled_date date not null,
  scheduled_time_slot text not null,
  special_instructions text not null default '' check (char_length(special_instructions) <= 500),
  status public.water_order_status not null default 'Pending',
  rejection_reason text not null default '' check (char_length(rejection_reason) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.users(id) on delete cascade,
  order_id uuid references public.orders(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  message text not null check (char_length(message) between 1 and 1000),
  notification_type text not null default 'order_update',
  event_key text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index if not exists notifications_event_once
  on public.notifications(order_id,recipient_id,event_key)
  where event_key is not null;

create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  previous_status public.water_order_status,
  new_status public.water_order_status not null,
  changed_by uuid references public.users(id) on delete set null,
  remarks text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists orders_customer_created_idx on public.orders(customer_id,created_at desc);
create index if not exists orders_status_schedule_idx on public.orders(status,scheduled_date);
create index if not exists notifications_recipient_created_idx on public.notifications(recipient_id,created_at desc);
create index if not exists history_order_created_idx on public.order_status_history(order_id,created_at);

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin new.updated_at=now(); return new; end $$;

drop trigger if exists users_updated_at on public.users;
create trigger users_updated_at before update on public.users for each row execute function public.set_updated_at();
drop trigger if exists products_updated_at on public.products;
create trigger products_updated_at before update on public.products for each row execute function public.set_updated_at();
drop trigger if exists orders_updated_at on public.orders;
create trigger orders_updated_at before update on public.orders for each row execute function public.set_updated_at();

-- Create the profile automatically when Supabase Auth creates a user.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.users(id,email,full_name,phone,delivery_address,role)
  values(
    new.id, coalesce(new.email,''),
    coalesce(new.raw_user_meta_data->>'full_name',''),
    coalesce(new.raw_user_meta_data->>'phone',''),
    coalesce(new.raw_user_meta_data->>'delivery_address',''),
    'student'
  )
  on conflict(id) do update set email=excluded.email;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_auth_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.users where id=auth.uid() and role='admin')
$$;

-- Keep schedule capacity correct under concurrent orders.
create or replace function public.place_water_order(
  p_product_id uuid,
  p_quantity integer,
  p_schedule_id uuid,
  p_delivery_address text,
  p_phone text,
  p_special_instructions text default ''
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_product public.products%rowtype;
  v_slot public.delivery_schedules%rowtype;
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Please log in before ordering.'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 30 then raise exception 'Quantity must be from 1 to 30.'; end if;
  if length(trim(coalesce(p_delivery_address,'')))=0 or length(p_delivery_address)>500 then raise exception 'Enter a valid delivery address.'; end if;
  if length(coalesce(p_phone,''))>30 or length(coalesce(p_special_instructions,''))>500 then raise exception 'One of the fields is too long.'; end if;

  select * into v_product from public.products where id=p_product_id and is_available=true for share;
  if not found then raise exception 'This product is not available.'; end if;

  -- Lock the chosen slot row to prevent two concurrent orders consuming the same capacity.
  select * into v_slot from public.delivery_schedules where id=p_schedule_id for update;
  if not found or v_slot.status <> 'Open' then raise exception 'This delivery slot is unavailable.'; end if;
  if v_slot.delivery_date < (now() at time zone 'Asia/Manila')::date then raise exception 'Choose a future delivery date.'; end if;
  if v_slot.available_capacity < 1 then raise exception 'This delivery slot is full.'; end if;

  update public.delivery_schedules set available_capacity=available_capacity-1 where id=p_schedule_id;
  insert into public.orders(customer_id,product_id,schedule_id,quantity,unit_price,delivery_address,phone,scheduled_date,scheduled_time_slot,special_instructions,status)
  values(auth.uid(),v_product.id,p_schedule_id,p_quantity,v_product.price,trim(p_delivery_address),trim(coalesce(p_phone,'')),v_slot.delivery_date,v_slot.time_slot,trim(coalesce(p_special_instructions,'')),'Pending')
  returning * into v_order;

  insert into public.order_status_history(order_id,previous_status,new_status,changed_by,remarks)
  values(v_order.id,null,'Pending',auth.uid(),'Order submitted by customer');

  insert into public.notifications(recipient_id,order_id,title,message,notification_type,event_key)
  values(v_order.customer_id,v_order.id,'Order submitted','We received order '||v_order.order_number||'. The station will review your request.','order_update','submitted');

  return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'status',v_order.status,'total_amount',v_order.total_amount);
end $$;

create or replace function public.cancel_my_water_order(p_order_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_order public.orders%rowtype;
begin
  select * into v_order from public.orders where id=p_order_id and customer_id=auth.uid() for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.status <> 'Pending' then raise exception 'Only pending orders can be cancelled by the customer.'; end if;
  update public.orders set status='Cancelled' where id=p_order_id;
  if v_order.schedule_id is not null then
    update public.delivery_schedules set available_capacity=least(max_capacity,available_capacity+1) where id=v_order.schedule_id;
  end if;
  insert into public.order_status_history(order_id,previous_status,new_status,changed_by,remarks)
  values(p_order_id,v_order.status,'Cancelled',auth.uid(),'Cancelled by customer before confirmation');
  insert into public.notifications(recipient_id,order_id,title,message,notification_type,event_key)
  values(v_order.customer_id,v_order.id,'Order cancelled','Your order '||v_order.order_number||' has been cancelled.','order_update','status:Cancelled');
end $$;

create or replace function public.admin_update_order_status(p_order_id uuid,p_new_status public.water_order_status,p_remarks text default '')
returns void language plpgsql security definer set search_path=public as $$
declare v_order public.orders%rowtype; v_title text; v_message text;
begin
  if not public.is_admin() then raise exception 'Administrator access required.'; end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.status=p_new_status then raise exception 'The order already has this status.'; end if;
  if v_order.status in ('Delivered','Cancelled','Rejected') then raise exception 'A final-status order cannot be changed.'; end if;
  if p_new_status='Pending' then raise exception 'An order cannot be moved back to Pending.'; end if;
  if p_new_status='Confirmed' and v_order.status<>'Pending' then raise exception 'Only pending orders can be confirmed.'; end if;
  if p_new_status='Preparing' and v_order.status not in ('Confirmed','Preparing') then raise exception 'Confirm the order before preparing it.'; end if;
  if p_new_status='Out for Delivery' and v_order.status not in ('Preparing','Confirmed') then raise exception 'The order must be confirmed or preparing before dispatch.'; end if;
  if p_new_status='Delivered' and v_order.status<>'Out for Delivery' then raise exception 'Mark the order out for delivery first.'; end if;
  if p_new_status='Rejected' and v_order.status<>'Pending' then raise exception 'Only pending orders can be rejected.'; end if;
  if p_new_status='Cancelled' and v_order.status in ('Delivered','Cancelled','Rejected') then raise exception 'This order cannot be cancelled.'; end if;

  update public.orders set status=p_new_status,rejection_reason=case when p_new_status='Rejected' then left(coalesce(p_remarks,'Order cannot be fulfilled.'),500) else rejection_reason end where id=p_order_id;
  if p_new_status in ('Cancelled','Rejected') and v_order.schedule_id is not null then
    update public.delivery_schedules set available_capacity=least(max_capacity,available_capacity+1) where id=v_order.schedule_id;
  end if;
  insert into public.order_status_history(order_id,previous_status,new_status,changed_by,remarks)
  values(p_order_id,v_order.status,p_new_status,auth.uid(),left(coalesce(p_remarks,''),500));

  v_title:=case p_new_status
    when 'Confirmed' then 'Order confirmed'
    when 'Preparing' then 'Preparing your order'
    when 'Out for Delivery' then 'Out for delivery'
    when 'Delivered' then 'Order delivered'
    when 'Cancelled' then 'Order cancelled'
    when 'Rejected' then 'Order rejected'
    else 'Order updated' end;
  v_message:=case p_new_status
    when 'Confirmed' then 'The station accepted order '||v_order.order_number||'.'
    when 'Preparing' then 'Your water refill order '||v_order.order_number||' is being prepared.'
    when 'Out for Delivery' then 'Your delivery for order '||v_order.order_number||' is on the way.'
    when 'Delivered' then 'Order '||v_order.order_number||' has been marked delivered.'
    when 'Cancelled' then 'Order '||v_order.order_number||' has been cancelled.'
    when 'Rejected' then 'Order '||v_order.order_number||' could not be fulfilled. '||left(coalesce(p_remarks,'Please contact the station for details.'),500)
    else 'Your order '||v_order.order_number||' has an update.' end;
  insert into public.notifications(recipient_id,order_id,title,message,notification_type,event_key)
  values(v_order.customer_id,v_order.id,v_title,v_message,'order_update','status:'||p_new_status)
  on conflict do nothing;
end $$;

create or replace function public.send_water_announcement(p_title text,p_message text)
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Administrator access required.'; end if;
  if length(trim(coalesce(p_title,''))) not between 1 and 120 then raise exception 'Title must be 1 to 120 characters.'; end if;
  if length(trim(coalesce(p_message,''))) not between 1 and 1000 then raise exception 'Message must be 1 to 1000 characters.'; end if;
  insert into public.notifications(recipient_id,title,message,notification_type,event_key)
  select id,trim(p_title),trim(p_message),'announcement',null from public.users where role='student';
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Row Level Security
alter table public.users enable row level security;
alter table public.products enable row level security;
alter table public.delivery_schedules enable row level security;
alter table public.orders enable row level security;
alter table public.notifications enable row level security;
alter table public.order_status_history enable row level security;

drop policy if exists "users read own or admin" on public.users;
create policy "users read own or admin" on public.users for select to authenticated using (id=auth.uid() or public.is_admin());
drop policy if exists "users update own or admin" on public.users;
create policy "users update own or admin" on public.users for update to authenticated using (id=auth.uid() or public.is_admin()) with check (id=auth.uid() or public.is_admin());

drop policy if exists "products readable" on public.products;
create policy "products readable" on public.products for select to authenticated using (true);
drop policy if exists "products admin manage" on public.products;
create policy "products admin manage" on public.products for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "schedules readable" on public.delivery_schedules;
create policy "schedules readable" on public.delivery_schedules for select to authenticated using (true);
drop policy if exists "schedules admin manage" on public.delivery_schedules;
create policy "schedules admin manage" on public.delivery_schedules for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "orders read own or admin" on public.orders;
create policy "orders read own or admin" on public.orders for select to authenticated using (customer_id=auth.uid() or public.is_admin());
-- All order inserts/updates are via security-definer RPCs only.
drop policy if exists "notifications read own or admin" on public.notifications;
create policy "notifications read own or admin" on public.notifications for select to authenticated using (recipient_id=auth.uid() or public.is_admin());
drop policy if exists "notifications mark own read" on public.notifications;
create policy "notifications mark own read" on public.notifications for update to authenticated using (recipient_id=auth.uid()) with check (recipient_id=auth.uid());
drop policy if exists "history read own or admin" on public.order_status_history;
create policy "history read own or admin" on public.order_status_history for select to authenticated using (
  public.is_admin() or exists(select 1 from public.orders o where o.id=order_id and o.customer_id=auth.uid())
);

-- Restrict direct mutation grants; authenticated clients use the approved RPC functions.
revoke insert, update, delete on public.orders from anon, authenticated;
revoke insert, update, delete on public.order_status_history from anon, authenticated;
revoke insert, delete on public.notifications from anon, authenticated;
grant select on public.users,public.products,public.delivery_schedules,public.orders,public.notifications,public.order_status_history to authenticated;
grant update(full_name,phone,delivery_address) on public.users to authenticated;
grant update(is_read) on public.notifications to authenticated;
grant insert,update,delete on public.products,public.delivery_schedules to authenticated;

grant execute on function public.place_water_order(uuid,integer,uuid,text,text,text) to authenticated;
grant execute on function public.cancel_my_water_order(uuid) to authenticated;
grant execute on function public.admin_update_order_status(uuid,public.water_order_status,text) to authenticated;
grant execute on function public.send_water_announcement(text,text) to authenticated;

-- Enable realtime replication for the tables the browser subscribes to.
do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.products;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.delivery_schedules;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- Seed initial products and delivery slots. Change prices to the actual station prices.
insert into public.products(product_name,container_type,price,is_available,description)
select 'Purified Water Refill','5-gallon container',35,true,'Purified water refill for boarding houses, dorms, and rental rooms.'
where not exists(select 1 from public.products);
insert into public.products(product_name,container_type,price,is_available,description)
select 'Mineral Water Refill','5-gallon container',40,true,'Mineral water refill. Update price based on the actual station.'
where not exists(select 1 from public.products where product_name='Mineral Water Refill');

-- Create several sample future delivery windows. These are real slots in the DB, not fake orders.
insert into public.delivery_schedules(delivery_date,time_slot,max_capacity,available_capacity,status)
select d::date,t,10,10,'Open'
from generate_series((now() at time zone 'Asia/Manila')::date+1,(now() at time zone 'Asia/Manila')::date+7,interval '1 day') d
cross join (values ('9:00 AM – 11:00 AM'),('1:00 PM – 3:00 PM'),('4:00 PM – 6:00 PM')) as slots(t)
on conflict(delivery_date,time_slot) do nothing;

-- IMPORTANT: promote your own account to admin only after registering in the app.
-- Replace YOUR_LOGIN_EMAIL with the exact email you used to sign up, then run separately:
-- update public.users set role='admin' where email='YOUR_LOGIN_EMAIL';
