// Supabase Edge Function: reject-signup
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
  if (origin && origin !== allowedOrigin) return reply({ error: "مبدأ درخواست مجاز نیست." }, 403, origin);
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

    const { data: actor, error: actorError } = await userClient
      .from("ka_profiles").select("role,approved").eq("id", user.id).single();
    if (actorError || actor?.role !== "creator" || actor?.approved !== true) {
      return reply({ error: "فقط Creator تأییدشده اجازه رد درخواست دارد." }, 403, origin);
    }

    const body = await req.json();
    const targetId = String(body.user_id ?? "");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetId)) {
      return reply({ error: "شناسه درخواست معتبر نیست." }, 400, origin);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: target, error: targetError } = await adminClient
      .from("ka_profiles").select("role,approved").eq("id", targetId).single();
    if (targetError || target?.role !== "student" || target?.approved !== false) {
      return reply({ error: "فقط درخواستِ تأییدنشدهٔ دانش‌آموز قابل رد است." }, 404, origin);
    }
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(targetId);
    if (deleteError) {
      console.error("Pending signup deletion failed", deleteError);
      return reply({ error: "حذف حساب انجام نشد. تنظیمات دیتابیس و Auth را بررسی کن." }, 500, origin);
    }
    return reply({ ok: true, message: "درخواست رد و حساب تأییدنشده حذف شد." }, 200, origin);
  } catch (error) {
    console.error("reject-signup failed", error);
    return reply({ error: "رد درخواست انجام نشد؛ دوباره تلاش کن." }, 500, origin);
  }
});
