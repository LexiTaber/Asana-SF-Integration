# External Credential & Named Credential Setup (Asana)

The Asana callout in `AsanaTaskService` authenticates through Salesforce's
External Credential + Named Credential model (Summer '24+), not a
Named-Credential-only legacy auth config. The External Credential holds the
Bearer token; the Named Credential holds the endpoint URL and points at the
External Credential for auth. Apex never sees the token — it only references
`callout:Asana`.

This is a one-time manual setup in each org (sandbox and production each need
their own). It is not captured in the metadata deployed by this repo, so a
fresh org (or a lost/rotated token) requires redoing these steps.

## Prerequisites
- System Administrator access in the target org
- A valid Asana Personal Access Token (PAT), generated at
  https://app.asana.com/0/my-apps
- Know which org you're configuring (`sf org list` / check the target-org alias, e.g. `asanaint`)

## 1. Create the External Credential

**Setup → Security → Named Credentials → External Credentials tab → New**

| Field | Value |
|---|---|
| Label | `Asana` |
| Name | `Asana` |
| Authentication Protocol | **Custom** |

Save, then on the External Credential detail page:

1. Under **Principals**, click **New** and add a Principal (e.g. Parameter Name `AsanaPrincipal`).
2. Under **Custom Headers** (or **Parameters**, depending on org version), add a
   parameter on the principal:
   - Name: `Authorization`
   - Value: `Bearer <PASTE_PAT_HERE>`
3. Save.

The PAT lives only on this principal — it is never stored in Apex, Custom
Metadata, or version control.

## 2. Create the Named Credential

**Setup → Security → Named Credentials → Named Credentials tab → New**

| Field | Value |
|---|---|
| Label | `Asana` |
| Name | `Asana` |
| URL | `https://app.asana.com/api/1.0` |
| External Credential | `Asana` (the one created in step 1) |
| Generate Authorization Header | checked |
| Allow Formulas in HTTP Header | unchecked (not needed) |

Save. `AsanaTaskService` calls `callout:Asana/tasks`, `callout:Asana/tasks/{gid}`,
etc. — the base URL above is prepended automatically, so paths in Apex must
start with `/`.

## 3. Grant Principal Access (required — easy to miss)

Callouts fail with an authentication error if the running user's Permission
Set isn't mapped to the External Credential Principal, even if the Named
Credential and External Credential are configured correctly.

**Setup → Permission Sets** (or use an existing one assigned to integration users):

1. Open the Permission Set the running user (or automated process) has assigned.
2. **External Credential Principal Access** → Edit → add the `Asana` /
   `AsanaPrincipal` principal from step 1.
3. Save and confirm the Permission Set is assigned to the user who will
   trigger the callout (whoever saves/updates the Opportunity, since the
   Queueable runs in that user's context).

## 4. Verify

Run the direct callout test in
[testing-and-logs.md](testing-and-logs.md#direct-callout-test-execute-anonymous).
A `401` at this stage almost always means either the PAT is invalid/expired
(step 1) or the running user's Permission Set isn't mapped to the principal
(step 3) — not a code issue.

## Rotating the PAT

Asana PATs used here are treated as temporary (see
[ticket-integration-requirements.md](ticket-integration-requirements.md)).
To rotate:

1. Generate a new PAT at https://app.asana.com/0/my-apps.
2. Go back to the External Credential (step 1) → open the principal → update
   the `Authorization` parameter value to `Bearer <NEW_PAT>`.
3. Revoke the old PAT in Asana.
4. Re-run the verification test in step 4.

No Named Credential, Apex, or metadata changes are needed for a token
rotation — it's isolated to the External Credential principal.
