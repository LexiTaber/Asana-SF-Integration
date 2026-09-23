# Incident: Tracked Field Sync Failures (Salesforce → Asana)

**Status:** Both root causes fixed and verified. Data reconciliation audit complete, pending sign-off on corrective writes to Asana.
**Systems:** Salesforce (`nff-prod`), Asana (Loan Onboarding Tracker 2.0 and downstream projects)
**Integration:** `OpportunityAsanaSyncHandler` → `AsanaTaskQueueable` → `AsanaTaskService` (Apex, async Queueable, calls Asana API via `Asana_API` Named Credential)

This incident covers two independent, silent failure modes that both broke the SF→Asana sync for a subset of users, plus the data reconciliation audit performed afterward to find and quantify the resulting drift.

---

## Issue 1: Asana Task GID never wrote back to Salesforce after task creation

### Background
When a Loan/Loan_NYC_Recovery Opportunity's stage becomes "Closed", `OpportunityAsanaSyncHandler` creates an Asana task via `AsanaTaskQueueable`, then writes the new task's GID back onto the Opportunity's `Asana_Task_GID__c` field so future updates can be pushed to the correct task.

### Expected
Every Closed, eligible Opportunity should have `Asana_Task_GID__c` populated shortly after close, regardless of which user closed the loan.

### Observed
For loans closed by certain (non-admin) users, `Asana_Task_GID__c` remained blank even though a real Asana task had in fact been created — producing no visible error anywhere.

### Investigation
`AsanaTaskQueueable` is Queueable Apex, which inherits the identity of the user who *enqueued* it (i.e., whoever closed the loan) rather than running as a service account. The GID write-back uses `Database.update(..., false)` (partial-success mode), which silently swallows failures instead of surfacing them.

### Root Cause
The `Lockdown_on_Opp_In_Closed_Stage` validation rule on Opportunity blocks *any* field edit on a Closed/Paid Off/Charged Off loan unless the running user is a System Administrator or holds the `Loan_Administrator` permission. For any loan officer without that permission, the rule silently rejected the queueable's GID write-back.

### Resolution
Added a narrow carve-out to the validation rule:
```
NOT(AND(ISCHANGED(Asana_Task_GID__c), ISBLANK(PRIORVALUE(Asana_Task_GID__c))))
```
This bypasses lockdown *only* for the one-time blank → populated GID write; no other exemption was widened. Deployed directly to production.

**Backlog (not urgent):** 6 duplicate `Lockdown_on_Opp_In_Closed_Stage`-style rules exist across related objects, using 3 different exemption mechanisms (`$Permission.Loan_Administrator`, a hardcoded `$Profile.Name` check, `$Permission.Impact_Data_Team`). Worth consolidating onto one formula field ("is terminal stage") and one exemption mechanism.

---

## Issue 2: Tracked field updates (Maturity Date, etc.) not syncing SF → Asana for some users

### Background
`OpportunityAsanaSyncHandler` pushes an update to the linked Asana task whenever any `SYNCED_FIELDS` value changes on an Opportunity that already has `Asana_Task_GID__c` populated.

### Expected
Any user editing a tracked field (e.g., Maturity Date) on a synced Opportunity should see that change reflected on the Asana task shortly after saving.

### Observed
One user's (Ben's) edits to tracked fields never appeared in Asana. Another user's (Ayana's) edits synced correctly. No error was visible to either user in Salesforce.

### Investigation
Ruled out, in order: field-level security, permission set membership, profile, Asana custom field type (confirmed plain Date), Asana Rules (none write to Maturity Date — only read it as a trigger condition), Asana project-level "admins only" field restrictions (ruled out — same restriction exists on the Onboarding project where sync demonstrably works), record-type/project mismatch (partial match only).

Reproduced live via Salesforce "Login As" as Ben, with a Debug Log trace flag capturing FINEST Apex/Callout logs. The log showed:
```
System.CalloutException: You don't have read permissions on the User External Credential object.
```

### Root Cause
The `Asana_Integration_Access` permission set granted External Credential *Principal Access* but never granted Read on the standard `UserExternalCredential` object — a separate, additional requirement of Salesforce's External Credential model. Ben lacked this; Ayana had it incidentally via `CRMUserPsl`, a Salesforce-standard PSL-backed permission set that happens to grant `UserExternalCredential` CRUD (and nothing else relevant here).

### Resolution
Added `UserExternalCredential` Read access directly to `Asana_Integration_Access` so the integration's own permission set is self-sufficient, rather than granting it to Ben individually. Verified by repeating the exact Login-As-Ben reproduction: clean `200 OK` callout, no exception.

**Side investigation (informational, no action taken):** `CRMUserPsl` is assigned to 76 of 109 active users — looks like a dropped legacy onboarding step (long-tenured users have it, newer hires often don't). Recommended *against* restricting it to admins-only: it's the actual enabler for any regular user triggering External-Credential-based callouts, and several other permission sets (MuleSoft, RPA, Marketing Cloud, etc.) also grant this object permission, suggesting broader org-wide reliance on it. Also flagged a `PermissionSetLicense` discrepancy (TotalLicenses: 10, UsedLicenses: 41) worth raising with whoever manages the SF license agreement — unrelated to this fix.

---

## Data Reconciliation Audit (post-fix)

With both silent failure modes fixed, ran a reconciliation to find and quantify SF↔Asana data drift accumulated while the sync was broken.

### Method
1. Queried all Closed, GID-linked, eligible (Loan / Loan_NYC_Recovery) Opportunities from `nff-prod` with their `SYNCED_FIELDS` values (147 records).
2. Pulled all tasks and custom field values from the four in-scope Asana projects (Loan Onboarding Tracker 2.0, Active Loans 2.0, Loan Modifications Renewals & Extensions 2.0, Loan Maturities 2.0), matched to SF records by task GID.
3. Diffed each `SYNCED_FIELDS`-mapped field, SF vs. Asana, normalizing date formats and numeric formatting before comparing.

### Findings
- **146 / 147** SF records matched a task by GID in the four scoped projects.
- **1** SF record's GID has no matching task in scope: *2023-1: Ali Forney Center Bridge Loan: 900677* (SF Id `0066Q0000225yvzQAA`, GID `1216862322082545`, Stage: Paid Off). Confirmed via direct `get_task` lookup (not just absence from the 4-project pull) that this GID no longer resolves to any task — it was deleted from Asana, not missed by the pull. Likely explanation: consolidated into the related "2023-1: Ali Forney Center Term Loan: 900678" (same borrower/close date), which has its own live, correctly-matched task (GID `1216862281503102`). **Decision (2026-08-17, Lexi):** ignore — the Bridge Loan is paid off and no longer tracked, so the dead GID doesn't need to be cleared or backfilled.
- **67** matched records have at least one field mismatch:
  - **64** `Outstanding_Amount__c` mismatches — overwhelmingly Asana showing a higher (stale) balance than SF's current, paid-down figure, consistent with drift accumulated during the sync outage. A few outliers reversed direction or involve SF showing $0 (BEAM Circular LOC, Out Teach working capital loan) or Asana lower than SF (The Food Trust LOC) — worth manual sanity-checking rather than blind correction.
  - **3** `Maturity_Date__c` mismatches, Asana stale by 6–12 months in each case — consistent with loan extensions recorded in SF that never pushed to Asana.
  - Full 64-row Outstanding Amount table, the 3 Maturity Date rows, and the missing-task record are in [reconciliation-report.md](reconciliation-report.md).

### Status / Next Steps
No corrective writes have been made to Asana. Per agreed process, SF is the source of truth for every mismatched field regardless of amount or direction — no case-by-case review of the values themselves is needed before correcting.

1. ~~Resolve the missing-task record~~ — done, no action needed (see Findings above).
2. **Scoped for a teammate to execute manually** — see [asana-correction-worklist.md](asana-correction-worklist.md) for the full list of 3 Maturity_Date__c and 64 Outstanding_Amount__c corrections, each with a direct Asana task link and the correct (SF) value to set.
3. Once applied, spot-check a sample of updated Asana tasks, then mark this incident resolved.
