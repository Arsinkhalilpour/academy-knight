// Supabase Edge Function: knight-tutor
// Required Edge Function secrets: GEMINI_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return Response.json({ error: "روش درخواست معتبر نیست." }, { status: 405, headers: corsHeaders });

  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization) return Response.json({ error: "ابتدا وارد حساب شو." }, { status: 401, headers: corsHeaders });

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const geminiKey = Deno.env.get("GEMINI_API_KEY");
    if (!geminiKey) return Response.json({ error: "کلید امن هوش مصنوعی هنوز در سرور تنظیم نشده است." }, { status: 503, headers: corsHeaders });

    const supabase = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) return Response.json({ error: "نشست معتبر نیست؛ دوباره وارد شو." }, { status: 401, headers: corsHeaders });

    const { data: profile, error: profileError } = await supabase
      .from("ka_profiles").select("role,approved").eq("id", user.id).single();
    if (profileError || profile?.role !== "student" || profile?.approved !== true) {
      return Response.json({ error: "دسترسی دانش‌آموز تأییدشده لازم است." }, { status: 403, headers: corsHeaders });
    }

    const body = await req.json();
    const question = String(body.question ?? "").trim();
    if (!question || question.length > 1500) {
      return Response.json({ error: "سؤال باید بین ۱ تا ۱۵۰۰ نویسه باشد." }, { status: 400, headers: corsHeaders });
    }

    const prompt = "تو معلم مهربان و دقیق آکادمی شوالیه برای دانش‌آموز پایه پنجم دبستان ایران هستی. فارسی ساده و مناسب سن پاسخ بده. مرحله‌به‌مرحله راهنمایی کن، جواب تکلیف را بی‌توضیح تحویل نده و دانش‌آموز را به فکر کردن تشویق کن. اگر سؤال خارج از آموزش مدرسه بود، کوتاه و امن پاسخ بده و به درس برگردان. پرسش دانش‌آموز: " + question;
    const geminiResponse = await fetch("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" + encodeURIComponent(geminiKey), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { temperature: 0.5, maxOutputTokens: 700 } }),
    });
    const result = await geminiResponse.json();
    if (!geminiResponse.ok) {
      console.error("Gemini error", result);
      return Response.json({ error: "فعلاً معلم هوشمند پاسخ نمی‌دهد. کمی بعد دوباره امتحان کن." }, { status: 502, headers: corsHeaders });
    }
    const answer = result.candidates?.[0]?.content?.parts?.map((p: {text?: string}) => p.text ?? "").join("").trim();
    if (!answer) return Response.json({ error: "پاسخی دریافت نشد؛ دوباره تلاش کن." }, { status: 502, headers: corsHeaders });
    return Response.json({ answer }, { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    console.error(error);
    return Response.json({ error: "خطای موقت در معلم هوشمند." }, { status: 500, headers: corsHeaders });
  }
});
