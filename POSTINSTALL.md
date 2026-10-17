**With Cloudron user management:** sign in with your Cloudron account. The first person to sign in
creates the first organization; others see only what they are invited to (and may create their own).

**Without it:** open the **File Manager**, set your email as `LANGFUSE_INIT_USER_EMAIL` in
`/app/data/env.sh` and **restart** the app. Your password is in the **Web Terminal**:
`grep INITIAL_ADMIN /app/data/.secrets/secrets.env`. Sign-up is closed to everyone else.

Then create a project and its API keys, and point your SDKs at `https://$CLOUDRON-APP-DOMAIN`.
