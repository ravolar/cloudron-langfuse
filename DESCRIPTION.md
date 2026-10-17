This is an **unofficial community package**, not affiliated with or supported by Langfuse GmbH.

Langfuse is an open-source LLM engineering platform: trace and debug LLM applications and agents,
run evaluations, manage and version prompts, build datasets and track cost, latency and quality.
It works with the Langfuse SDKs (Python, JS/TS), OpenTelemetry and integrations such as LangChain,
LlamaIndex, the OpenAI SDK and LiteLLM.

### This package

* Langfuse web and worker, with a bundled ClickHouse (traces) and S3 server (raw events, media);
  PostgreSQL, Redis and outgoing email provided by Cloudron.
* Sign-in with Cloudron accounts, another OpenID Connect provider, or email and password;
  sign-up is closed by default.
* Cloudron backups and restore cover all of it, ClickHouse included.
