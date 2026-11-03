// Supabase Edge Function: create-teacher
// Required secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
// The service-role key must remain in Edge Function secrets and must never be sent to the browser.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigin = "https://arsinkhalilpour.github.io";

function cors(origin: string | null) {
  return {
    "Access-Control-Allow-Origin": origin === allowedOrigin ? origin : allowedOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function reply(body: Record<string, unknown>, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(origin), "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (origin && origin !== allowedOrigin) {
    return reply({ error: "مبدأ درخواست مجاز نیست." }, 403, origin);
  }
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(origin) });
  if (req.method !== "POST") return reply({ error: "روش درخواست معتبر نیست." }, 405, origin);

  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization) return reply({ error: "ابتدا وارد حساب Creator شو." }, 401, origin);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return reply({ error: "تنظیمات امن سرور کامل نیست." }, 503, origin);
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) return reply({ error: "نشست معتبر نیست؛ دوباره وارد شو." }, 401, origin);

    const { data: profile, error: profileError } = await userClient
      .from("ka_profiles").select("role,approved").eq("id", user.id).single();
    if (profileError || profile?.role !== "creator" || profile?.approved !== true) {
      return reply({ error: "فقط Creator تأییدشده اجازه ساخت حساب معلم دارد." }, 403, origin);
    }

    const body = await req.json();
    const email = String(body.email ?? "").trim().toLowerCase();
    const fullName = String(body.full_name ?? "").trim().replace(/\s+/g, " ");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
      return reply({ error: "ایمیل معتبر وارد کن." }, 400, origin);
    }
    if (fullName.length < 3 || fullName.length > 100) {
      return reply({ error: "نام و نام خانوادگی باید بین ۳ تا ۱۰۰ نویسه باشد." }, 400, origin);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const siteUrl = (Deno.env.get("SITE_URL") || "https://arsinkhalilpour.github.io/academy-knight").replace(/\/$/, "");
    const { data: inviteData, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
      data: { full_name: fullName },
      redirectTo: siteUrl + "/",
    });
    if (inviteError || !inviteData.user) {
      return reply({ error: inviteError?.message?.toLowerCase().includes("already") ? "این ایمیل قبلاً حساب دارد؛ از بخش کاربران نقش آن را تغییر بده." : "ارسال دعوت‌نامه ناموفق بود. تنظیمات ایمیل Supabase را بررسی کن." }, 400, origin);
    }

    const { error: upsertError } = await adminClient.from("ka_profiles").upsert({
      id: inviteData.user.id,
      role: "teacher",
      approved: true,
    }, { onConflict: "id" });

    if (upsertError) {
      console.error("Teacher profile setup failed", upsertError);
      return reply({ error: "دعوت‌نامه ارسال شد، اما فعال‌سازی نقش معلم کامل نشد. حساب را در بخش کاربران تأییدشده بررسی کن." }, 500, origin);
    }

    return reply({ ok: true, message: "دعوت‌نامهٔ ورود معلم ارسال شد و نقش معلم فعال شد." }, 200, origin);
  } catch (error) {
    console.error("create-teacher failed", error);
    return reply({ error: "ساخت حساب معلم انجام نشد. ورودی‌ها و تنظیمات ایمیل را بررسی کن." }, 500, origin);
  }
});
