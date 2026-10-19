# Personalities in conversations

The chat toolbar offers **ECAI default** and the signed-in account's confirmed
personality purchases. Choose a personality before starting a chat or change it
on an existing conversation. The choice is saved with the conversation and
restored when it is reopened. Changing it affects subsequent replies; existing
messages remain unchanged.

Anonymous chats and conversations created before this feature use ECAI default.
The default uses the existing configured chat system prompt and does not depend
on the sales service. The UI clears purchase choices when accounts change.

## Entitlements and editions

An owned choice is a purchase whose NFT issuance has reached the verified
`minted` state in the personality coordinator. Invoice creation, Lightning
payment alone and an unconfirmed mint do not unlock conversation use. Access
belongs to the purchasing account, matching the hosted package download policy.
Importing an NFT from another wallet or transferring hosted access with an NFT
is not implemented. The configured LLM still supplies inference; the NFT does
not include model credits or change tool permissions.

Each selection is `default` or `purchase:<order-id>`. A purchase reference pins
the package bytes and version saved at checkout. Runtime resolution checks the
account, fulfillment status, package SHA-256, schema, product id and version.
Editing the catalog or disabling new sales does not alter an existing purchase.
The picker returns descriptors only; it never publishes package instructions.

An unavailable or unauthorized saved selection fails explicitly. It is never
silently replaced with the default. The user can choose ECAI default to resume.

## HTTP integration

These routes use the existing authenticated conversation API and derive the
owner from the server's authenticated principal. Clients cannot supply an owner
or a raw personality prompt.

| Method | Route | Result |
|---|---|---|
| GET | `/ecai/conversations/personalities` | `{ "ok": true, "items": [...] }` with default and owned descriptors |
| POST | `/ecai/conversations` | Accepts optional `personality_ref`, alongside `title` and `project_id` |
| PATCH | `/ecai/conversations/:id` | Accepts `personality_ref` to change subsequent replies |
| GET | `/ecai/conversations/:id` | Returns the saved reference in `conversation.personality_ref` |
| POST | `/ecai/conversations/:id/messages` | Uses the conversation's saved selection; body remains `{ "message": "..." }` |

Use a `ref` returned by the picker, for example:

```json
{ "title": "Release planning", "personality_ref": "default" }
```

Descriptors contain `ref`, `personality_id`, `name`, `version` and
`package_sha256`. Error responses use `invalid_personality` (400),
`personality_not_owned` (403) or `personality_unavailable` (503).

## Runtime behavior

Entitlement is checked on explicit selection and again before each model reply.
The HTTP handler checks it before appending the user turn. If the service fails
after that check, the generation error is returned and the saved user turn is
retained, matching existing conversation failure behavior.

The selected package's system instructions are added to the configured base
prompt for that request only. Project instructions and authorized conversation
history still supply context. Pooled worker state is never changed, so returning
to default restores the original prompt exactly. Assistant message metadata
records the reference used for that reply, including when another client changes
the conversation's selection while a generation is running.

The old direct-answer shortcut is removed: it could return an earlier cached
answer without applying the current personality. In-memory retrieval is scoped
to the exact owner and session; authorized related history still comes from the
account-scoped conversation store. Public `/ecai/chat` continues using the
default and does not accept a paid personality selection.

## Validation and rollout

The source archive includes the previous Lightning/NFT implementation and this
conversation integration. The incremental `ecai-personality-conversations.patch`
applies after the previous personalities/Lightning patch. Build and restart the
ECAI app inside the complete DamageBDD umbrella release. Existing conversation
records need no migration: a missing reference reads as `default`.

Tests use local deterministic adapters and captured model requests. They cover
purchase ownership and immutable snapshots, stored selection and restart,
HTTP access checks, model prompt isolation and browser selection behavior. They
do not exercise the parent release's real authentication, a live LLM, Lightning
payments or a deployed chain contract.

Validated on 19 October 2026: 46 EUnit tests passed (27 purchase/NFT,
12 conversation store/HTTP and 7 inference), 22 Chromium tests passed
(12 conversation selector and 10 purchase-flow regressions), and 4 targeted
console asset/DOM/navigation/API checks passed. Changed Erlang modules compile
with warnings treated as errors. Desktop and mobile selector layouts were
visually inspected. The older console suite's two previously documented baseline
failures are outside these targeted checks.

Test entry points from the umbrella root (with Erlang, JSX and Playwright installed):

```sh
bash apps/ecai/test/run_personalities_tests.sh
bash apps/ecai/test/conversation_personalities/run.sh
bash apps/ecai/test/personalities/chat/run.sh
node apps/ecai/test/test_chat_personality_browser.mjs
node apps/ecai/test/test_personalities_browser.mjs
```

For external dependencies, the first two scripts accept `ECAI_JSX_EBIN`; the
chat script accepts `JSX_EBIN`. Browser scripts accept `ECAI_PERSONALITIES_CHROMIUM`
when Chromium is installed outside Playwright's default location. Test doubles
live in isolated harness directories and must not be compiled into a production
application.
