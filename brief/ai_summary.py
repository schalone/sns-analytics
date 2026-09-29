"""AI narrative for the morning brief. Claude reads the deterministic numbers and writes a short read of
what changed, why, and what to do. Auth = Workload Identity Federation (Google identity token for the
ads-builder service account -> Anthropic token); no API key anywhere. Any failure returns None so the
brief still posts without a narrative."""
import os

MODEL = "claude-opus-5"
AUDIENCE = "https://api.anthropic.com"
DEFAULTS = {"ANTHROPIC_FEDERATION_RULE_ID": "fdrl_01DeyYjK2CitumthUG1dqVm5",
            "ANTHROPIC_ORGANIZATION_ID": "6b6f3926-f414-4288-9d14-d9c85e874398",
            "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_01R9YZ7NYdEL3Ys53FbUto2f",
            "ANTHROPIC_WORKSPACE_ID": "wrkspc_01TezEU4bYbdcBZRj2tnSAue"}

SYSTEM = """You are the analytics lead for Sip & Script, a US company that runs in-person modern-calligraphy classes at local venues (tickets about $65–70, all materials included). You write a short daily read for the founders' Slack channel.

You are given two deterministic reports: yesterday's website metrics from GA4 (orders = unique transaction IDs) and yesterday's Google Ads search performance. Google Ads search campaigns launched on 2026-09-25 and are in bidding-strategy learning; the first days will look sparse and noisy — say so rather than over-interpreting them. Organic search traffic is depressed by a known SEO issue being fixed in parallel.

Rules: use only numbers that appear in the reports, never compute or estimate new ones; quote a number only when it carries the point. Write 4–6 plain sentences and at most 130 words, no bullet points, no headings, no preamble: what changed and how much, the most likely reason grounded in the data, and one or two concrete actions worth taking today (or say that no action is needed). If a metric looks like a tracking or data problem rather than real behaviour, say that explicitly."""


def build_prompt(ga_text, ads_text):
    return f"WEBSITE (GA4):\n{ga_text}\n\nGOOGLE ADS:\n{ads_text}\n\nWrite today's read."


def make_client():
    import anthropic, google.auth.transport.requests, google.oauth2.id_token
    from anthropic import WorkloadIdentityCredentials
    env = {k: os.environ.get(k, v) for k, v in DEFAULTS.items()}
    def google_id_token():
        # Cloud Run: metadata server. Local: GOOGLE_APPLICATION_CREDENTIALS pointing at the ads-builder key.
        return google.oauth2.id_token.fetch_id_token(google.auth.transport.requests.Request(), AUDIENCE)
    return anthropic.Anthropic(credentials=WorkloadIdentityCredentials(
        identity_token_provider=google_id_token,
        federation_rule_id=env["ANTHROPIC_FEDERATION_RULE_ID"], organization_id=env["ANTHROPIC_ORGANIZATION_ID"],
        service_account_id=env["ANTHROPIC_SERVICE_ACCOUNT_ID"], workspace_id=env["ANTHROPIC_WORKSPACE_ID"]))


def narrative(ga_text, ads_text, client=None):
    """Returns the narrative string, or None if anything fails (the brief must never depend on it)."""
    try:
        client = client or make_client()
        msg = client.beta.messages.create(
            model=MODEL, max_tokens=4096, output_config={"effort": "low"},   # short, routine daily read
            betas=["server-side-fallback-2026-07-01"], fallbacks="default",
            system=SYSTEM, messages=[{"role": "user", "content": build_prompt(ga_text, ads_text)}])
        if msg.stop_reason == "refusal":
            print("ai summary: refusal", getattr(msg, "stop_details", None)); return None
        text = " ".join(b.text for b in msg.content if b.type == "text").strip()
        if msg.stop_reason == "max_tokens": text = text.rsplit(".", 1)[0] + "." if "." in text else text
        print(f"ai summary: {msg.model} in={msg.usage.input_tokens} out={msg.usage.output_tokens}")
        return text or None
    except Exception as e:  # noqa: BLE001 — additive feature, never block the brief
        print("ai summary failed:", type(e).__name__, e); return None
