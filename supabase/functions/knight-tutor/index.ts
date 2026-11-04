// Supabase Edge Function: knight-tutor
// Required secrets: GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigin = "https://arsinkhalilpour.github.io";
function makeCorsHeaders(origin: string | null) {
  return {
    "Access-Control-Allow-Origin": origin === allowedOrigin ? origin : allowedOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const cors = makeCorsHeaders(origin);
  if (origin && origin !== allowedOrigin) return Response.json({ error: "مبدأ درخواست مجاز نیست." }, { status: 403, headers: cors });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return Response.json({ error: "روش درخواست معتبر نیست." }, { status: 405, headers: cors });

  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization) return Response.json({ error: "ابتدا وارد حساب شو." }, { status: 401, headers: cors });

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const groqKey = Deno.env.get("GROQ_API_KEY");
    if (!supabaseUrl || !anonKey) return Response.json({ error: "تنظیمات اتصال سرور کامل نیست." }, { status: 503, headers: cors });
    if (!groqKey) return Response.json({ error: "کلید Groq در Secrets سرور تنظیم نشده است." }, { status: 503, headers: cors });

    const supabase = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) return Response.json({ error: "نشست معتبر نیست؛ دوباره وارد شو." }, { status: 401, headers: cors });

    const { data: profile, error: profileError } = await supabase
      .from("ka_profiles").select("role,approved").eq("id", user.id).single();
    if (profileError || profile?.role !== "student" || profile?.approved !== true) {
      return Response.json({ error: "دسترسی دانش‌آموز تأییدشده لازم است." }, { status: 403, headers: cors });
    }

    const body = await req.json();
    const question = String(body.question ?? "").trim();
    if (!question || question.length > 1500) {
      return Response.json({ error: "سؤال باید بین ۱ تا ۱۵۰۰ نویسه باشد." }, { status: 400, headers: cors });
    }

    const prompt = "تو معلم مهربان و دقیق آکادمی شوالیه برای دانش‌آموز پایه پنجم دبستان ایران هستی. فارسی ساده و مناسب سن پاسخ بده. مرحله‌به‌مرحله راهنمایی کن، جواب تکلیف را بی‌توضیح تحویل نده و دانش‌آموز را به فکر کردن تشویق کن. اگر سؤال خارج از آموزش مدرسه بود، کوتاه و امن پاسخ بده و به درس برگردان. پرسش دانش‌آموز: " + question;
    const groqResponse = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": "Bearer " + groqKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "openai/gpt-oss-20b",
        messages: [
          { role: "system", content: "You are a kind, careful Persian-language elementary school tutor. Keep responses age-appropriate and educational." },
          { role: "user", content: prompt },
        ],
        temperature: 0.5,
        max_tokens: 700,
      }),
    });

    const result = await groqResponse.json();
    if (!groqResponse.ok) {
      console.error("Groq API error", { status: groqResponse.status, error: result?.error?.message || "Unknown provider error" });
      return Response.json({ error: "پاسخ‌گویی Groq ناموفق بود. وضعیت سرویس یا کلید API را بررسی کن." }, { status: 502, headers: cors });
    }
    const answer = result.choices?.[0]?.message?.content?.trim();
    if (!answer) return Response.json({ error: "پاسخی از Groq دریافت نشد؛ دوباره تلاش کن." }, { status: 502, headers: cors });
    return Response.json({ answer }, { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (error) {
    console.error("Knight tutor error", error);
    return Response.json({ error: "خطای موقت در معلم هوشمند." }, { status: 500, headers: cors });
  }
});
