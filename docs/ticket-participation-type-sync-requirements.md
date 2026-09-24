# Dev Ticket: Add Participation Type and Paid Off Date to Salesforce → Asana Sync

## Background

Source: [ParticipationFieldLogic_Request.pdf](ParticipationFieldLogic_Request.pdf) (email thread, Ben Zimmitti → Alissa Czasonis, 9/14–9/15/2026, fwd'd to Lexi Taber) plus scoping discussion with Lexi (9/23/2026).

This ticket covers two independent field additions to the existing `OpportunityAsanaSyncHandler` → `AsanaTaskQueueable` → `AsanaTaskService` sync:

1. **Participation Type** — fixes a live bug in the **Loan Onboarding Tracker 2.0** project (GID `1213427513705845`).
2. **Paid Off Date** — adds a new tracked field feeding the **Loan Payoff Tracking** project (GID `1213453971889368`).

Both projects receive the **same underlying Asana task** as Loan Onboarding Tracker 2.0 — confirmed live via the Asana API: a task created at Closed stays on one `gid` and gets added to downstream projects (Active Loans 2.0, Loan Maturities 2.0, Loan Payoff Tracking, etc.) by existing Asana Rules as the loan progresses through its lifecycle, while retaining every previously-synced custom field value. `Asana_Task_GID__c` on the Opportunity always points at this one task regardless of which project(s) it currently belongs to. Practically, this means **both features are additive changes to the existing `updateTask()` payload** — no new task-creation path, no new project-membership logic, and no per-project branching required in Apex.

---

## Feature 1: Participation Type (bug fix)

Ben Zimmitti (Lending Administration) flagged that the **Participation Type (formula)** field in the Loan Onboarding Tracker 2.0 Asana project is wrong for any loan with more than one lender: it always shows **"NFF Participant,"** even when NFF is the lead lender that sold off a participation.

### How the field is currently populated (per Alissa, 9/14)

1. The Salesforce integration syncs `Participation_Loan1__c` (Yes/No) into a hidden Asana field, **"Participation Loan?"** (text, GID `1215983686119784`) — this is the only participation-related data point currently synced.
2. An Asana Rule (owned by Ops, external to this repo) converts that text into the visible **"Participation Type (formula)"** field (enum, GID `1215987679220031`, values `NFF Lead/No Participation` / `NFF Participant`):
   - `Participation Loan?` contains `Yes` → `NFF Participant`
   - `Participation Loan?` contains `No` → `NFF Lead/No Participation`

### Root cause

When `Participation_Loan1__c` = Yes, NFF can be on either side of the deal — **Lead Lender** (sold a participation to another lender) or **Participant** (purchased a portion from another lender). Salesforce already captures this distinction in `Participation_Type__c`, a picklist on Opportunity (values `Sold` / `Purchased`, dependent on `Participation_Loan1__c`) — confirmed via org describe, already exists in both `asanaint` and production. **This field is not synced to Asana today**, so the Asana Rule has no way to tell the two cases apart and defaults every "Yes" to "NFF Participant."

### Correct logic (per Ben, 9/15 — confirmed against the SF picklist values)

| `Participation_Loan1__c` | `Participation_Type__c` | `Participation Type (formula)` should be |
|---|---|---|
| No | *(n/a — dependent field, blank)* | NFF Lead/No Participation |
| Yes | Sold | NFF Lead/No Participation |
| Yes | Purchased | NFF Participant |

### Requirements — Salesforce integration (this repo)

**Status: done.** Deployed to `asanaint` sandbox, all 30 tests passing. Only remaining step is the Asana Rule update below.

1. **`OpportunityAsanaSyncHandler.cls`** — ✅ added `Participation_Type__c` to `SYNCED_FIELDS`.
2. **`AsanaTaskService.cls`** — ✅ added `CF_PARTICIPATION_TYPE = '1218783762811670'` (real GID — Lexi created the "Participation Type (SF)" field on Loan Onboarding Tracker 2.0 on 9/24/2026) and included it in `buildPayload()`, mapped from `opp.Participation_Type__c`.
3. **`AsanaTaskServiceTest.cls`** — ✅ added `updateTask_participationTypeSold_includedInPayload` / `updateTask_participationTypeBlank_omittedFromPayload`.
4. No new Salesforce custom field or `package.xml` change needed — `Participation_Type__c` already exists in both orgs.
5. Bonus fix found while writing these tests: `buildPayload()` was sending blank optional fields as explicit `null` instead of omitting them (a pre-existing gap in all fields, not just the new ones) — fixed via a `putIfNotNull()` helper. See `AsanaTaskService.cls` and `docs/ticket-component-descriptions.md` for detail.

### Requirements — Asana (owned by Ops/Alissa's team)

1. ~~Create a new hidden custom field on the Loan Onboarding Tracker 2.0 project to receive the raw synced value~~ — ✅ done: **"Participation Type (SF)"** (text, GID `1218783762811670`), created 9/24/2026.
2. **Update the existing Asana Rule** that computes `Participation Type (formula)` to branch on both fields:
   - `Participation Loan?` contains `No` → `NFF Lead/No Participation`
   - `Participation Loan?` contains `Yes` AND `Participation Type (SF)` contains `Sold` → `NFF Lead/No Participation`
   - `Participation Loan?` contains `Yes` AND `Participation Type (SF)` contains `Purchased` → `NFF Participant`

### Requirements — Reconciliation audit (post-fix)

Every currently-open task where `Participation Loan?` = Yes has been running through the old 2-branch rule, so any task where NFF is actually the **lead/seller** (SF `Participation_Type__c` = Sold) is very likely mismarked as `NFF Participant` in Asana today. Once the fix ships:

1. Query Salesforce for all `Loan`/`Loan_NYC_Recovery` Opportunities with `Asana_Task_GID__c` populated, `Participation_Loan1__c` = Yes, and `Participation_Type__c` = Sold.
2. For each, look up the matching Asana task by GID and confirm/correct `Participation Type (formula)` to `NFF Lead/No Participation`.
3. Document findings the same way as [Incident_TrackedFieldsSync/reconciliation-report.md](../Incident_TrackedFieldsSync/reconciliation-report.md) — record count affected, before/after values, and confirm no corrective write is needed on the Salesforce side (SF is already correct; only Asana needs fixing).

### Acceptance Criteria

- Updating `Participation_Type__c` on a `Loan`/`Loan_NYC_Recovery` Opportunity that already has an `Asana_Task_GID__c` pushes an update to the Asana task.
- The new custom field payload correctly reflects `Sold`, `Purchased`, and null (when `Participation_Loan1__c` = No).
- After the Asana Rule is updated, a Closed loan with `Participation_Loan1__c` = Yes and `Participation_Type__c` = Sold shows `Participation Type (formula)` = `NFF Lead/No Participation` in Asana; `Purchased` shows `NFF Participant`.
- Reconciliation audit completed and documented; any mismarked existing tasks in Asana are corrected.

---

## Feature 2: Paid Off Date (new synced field)

Add `Opportunity.Paid_off_Date__c` (Date) to the sync so it lands on the Asana task's **"Paid Off Date"** custom field, which feeds the Loan Payoff Tracking project.

### Findings (confirmed live via Asana API, 9/23/2026)

- The **"Paid Off Date"** custom field already exists in Asana (date type, GID `1218421167420225`) and is already attached to the Loan Payoff Tracking project's custom field settings — pulled a sample task in that project and confirmed the field is present, currently blank, alongside all of our other already-synced fields (Salesforce Stage, Loan Number, Outstanding Amount, Close Date, Participation Loan?, Opportunity Owner, Loan Fund, Maturity Date, Lead Lender).
- **No Asana-side setup is required for this feature** — unlike Participation Type, the field already exists and no Rule needs to change. This is a pure Salesforce/Apex change.
- `Opportunity.Paid_off_Date__c` (label "Paid off Date") already exists in both orgs — confirmed via describe.

### Requirements — Salesforce integration (this repo)

**Status: done.** Deployed to `asanaint` sandbox, all tests passing. No Asana-side dependency — ready to ship independently of Feature 1.

1. **`OpportunityAsanaSyncHandler.cls`** — ✅ added `Paid_off_Date__c` to `SYNCED_FIELDS`.
2. **`AsanaTaskService.cls`** — ✅ added `CF_PAID_OFF_DATE = '1218421167420225'` and included it in `buildPayload()` via the existing `asDateValue()` helper (same pattern as `Maturity_Date__c`/`Close_Date__c`), mapped from `opp.Paid_off_Date__c`.
3. **`AsanaTaskServiceTest.cls`** — ✅ added `updateTask_paidOffDate_includedInPayload_correctDateShape` / `updateTask_paidOffDateBlank_omittedFromPayload`.
4. **`AsanaTaskQueueable.cls`** — ✅ added `Participation_Type__c, Paid_off_Date__c` to the re-query SOQL (needed for both features, since the queueable re-fetches Opportunities by Id before building the payload).
5. No new Salesforce custom field, no `package.xml` change needed.

### Acceptance Criteria

- Setting `Paid_off_Date__c` on an Opportunity that already has an `Asana_Task_GID__c` pushes an update to the Asana task.
- The Asana task's "Paid Off Date" custom field reflects the SF value in the correct date format.
- Field is omitted from the payload (not sent as explicit `null`) when `Paid_off_Date__c` is blank, consistent with existing null-handling.

---

## Shared documentation updates

- **`docs/ticket-integration-requirements.md`** — add `Participation_Type__c` and `Paid_off_Date__c` to the tracked-fields list and field-mapping table.
- **`docs/ticket-component-descriptions.md`** — update the `AsanaTaskService.cls` custom field GID list for both new constants.

## Out of scope

- Any additional Opportunity fields beyond `Participation_Type__c` and `Paid_off_Date__c` — Alissa asked the LS team (Ayana, Justin) if there are other fields they'd like added to the sync while this is open, but none were named in this thread. File as a separate ticket once a concrete list exists.
- Identity of the counterparty lenders (`Lead_Participant__c` is already synced as "Lead Lender"; `Participant__c`/`Participant1__c`/etc. are not in scope here).
- Loan Payoff Tracking's other unsynced custom fields (Payoff Type, Payoff Amount, Payoff Stage, Expected Payoff Date, etc.) — only `Paid Off Date` was requested.
