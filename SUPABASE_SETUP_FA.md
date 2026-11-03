# راه‌اندازی امن آکادمی شوالیه

این مخزن شامل رابط سایت، مهاجرت دیتابیس و کد دو تابع Edge است. فایل‌های HTML به‌تنهایی نمی‌توانند تنظیمات خصوصی Supabase را تغییر دهند؛ مراحل زیر باید روی پروژه Supabase اجرا شوند.

## ۱) اجرای مهاجرت دیتابیس

فایل زیر را باز کن:

`supabase/migrations/202611030001_secure_academy_workflows.sql`

محتوای آن را در **Supabase Dashboard → SQL Editor** اجرا کن، یا از Supabase CLI استفاده کن:

```bash
supabase login
supabase link --project-ref rdsermutogewhcdsyoon
supabase db push
```

این مهاجرت:
- برای حساب‌های Auth پروفایل پیش‌فرضِ دانش‌آموزِ در انتظار تأیید می‌سازد و حساب‌های قدیمیِ بدون پروفایل را تکمیل می‌کند.
- توابع RPC امن برای Creator و Admin ایجاد می‌کند.
- انتشار درس و مدیریت دسترسی معلم را پشتیبانی می‌کند.
- جدول‌های مستقل کارت تلاش و لوح تقدیر را با RLS می‌سازد. هر ۱۰ کارت معلم یا هر ۱ کارت مدیر، یک لوح ایجاد می‌کند.

## ۲) تنظیم اسرار توابع سمت سرور

در **Supabase → Project Settings → API** مقدارهای پروژه را پیدا کن. کلید محرمانهٔ service-role فقط باید در قسمت Secrets توابع ذخیره شود و هرگز نباید داخل فایل HTML یا GitHub قرار بگیرد.

با CLI:

```bash
supabase secrets set SUPABASE_URL="https://rdsermutogewhcdsyoon.supabase.co"
supabase secrets set SUPABASE_ANON_KEY="YOUR_PUBLISHABLE_OR_ANON_KEY"
supabase secrets set SUPABASE_SERVICE_ROLE_KEY="YOUR_SERVICE_ROLE_SECRET"
supabase secrets set SITE_URL="https://arsinkhalilpour.github.io/academy-knight"
```

برای معلم هوشمند نیز کلید Gemini را فقط به‌صورت Secret ثبت کن:

```bash
supabase secrets set GEMINI_API_KEY="YOUR_GEMINI_API_KEY"
```

## ۳) انتشار توابع

```bash
supabase functions deploy create-teacher
supabase functions deploy knight-tutor
```

تابع `create-teacher` فقط برای Creator تأییدشده کار می‌کند. دعوت‌نامهٔ ایمیلی ارسال می‌کند؛ معلم خودش از لینک ایمیل وارد می‌شود و رمز خود را تعیین می‌کند.

## ۴) تنظیم نشانی بازگشت ایمیل

در **Supabase → Authentication → URL Configuration** نشانی زیر را به Redirect URLs اضافه کن:

`https://arsinkhalilpour.github.io/academy-knight/`

ارسال دعوت‌نامه به فعال بودن Email Provider و تنظیم بودن سرویس ایمیل پروژه وابسته است.

## ۵) آزمون پیشنهادی

1. یک حساب آزمایشی دانش‌آموز ثبت‌نام کن و بررسی کن در بخش درخواست‌های Creator دیده شود.
2. آن را تأیید کن؛ سپس نقش آن را به معلم تغییر بده یا از فرم دعوت معلم استفاده کن.
3. در پنل معلم یک درس پیش‌نویس بساز، فایل بارگذاری کن و درس را منتشر کن.
4. با حساب دانش‌آموز بررسی کن درس و فایل آن نمایش داده شود و فایل باز شود.
5. با حساب معلم ۱۰ کارت آزمایشی به یک دانش‌آموز بده و صدور یک لوح را بررسی کن.
6. با حساب مدیر یک کارت آزمایشی بده و صدور یک لوح را بررسی کن.

**نکتهٔ امنیتی:** هیچ‌وقت `service_role` را در کد مرورگر، پیام عمومی، یا مخزن GitHub قرار نده. فقط کلید Publishable/Anon برای مرورگر مناسب است.
