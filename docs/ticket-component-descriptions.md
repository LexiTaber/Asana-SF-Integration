# Dev Ticket: Component Descriptions

## Architecture Overview

```
OpportunityTrigger.trigger  (after insert, after update)
  └─ OpportunityAsanaSyncHandler.cls  (eligibility filter + create/update routing)
       └─ AsanaTaskQueueable.cls  (async wrapper — required for callouts in trigger context)
            └─ AsanaTaskService.cls  (JSON payload builder, HTTP callout, response parser)
```

---

## OpportunityTrigger.trigger

The modified version of the existing `OpportunityTrigger`. This trigger already existed in the org and handled Action Plan deletions and SharePoint folder stamping. The Asana integration was added to the `after insert` and `after update` contexts.

**Added:**
- `after update`: calls `OpportunityAsanaSyncHandler.handleAfter(Trigger.new, Trigger.oldMap)`
- `after insert`: calls `OpportunityAsanaSyncHandler.handleAfter(Trigger.new, null)` — passes `null` for `oldMap` because there is no prior state on insert

**`after insert`/`after update` is the standard pattern for async callout chains. The existing `before delete` (Action Plan cleanup) and `after undelete` (Action Plan restore) logic is untouched.

---

## OpportunityAsanaSyncHandler.cls

The decision layer between the trigger and the async callout. Applies all eligibility filters and determines whether each Opportunity in the batch should result in a task create, a task update, or nothing.

**Key logic:**

1. **Record type filter** — Queries `RecordType` for Opportunities with `DeveloperName IN ('Loan', 'Loan_NYC_Recovery')`. Any Opportunity whose `RecordTypeId` is not in this set is skipped entirely. Result is cached per transaction to avoid redundant SOQL.

2. **Create path** — Fires when `StageName == 'Closed'` AND either (a) this is an insert (`oldOpp == null`) or (b) the prior stage was not `Closed`. Also requires `Asana_Task_GID__c` to be blank — prevents creating a second task if one already exists.

3. **Update path** — Fires when `Asana_Task_GID__c` is populated AND at least one of the 10 tracked fields differs between old and new values.

4. **Async enqueue** — Qualifying Opportunity IDs are collected into `toCreate` and `toUpdate` lists, then enqueued as separate `AsanaTaskQueueable` jobs. The handler never makes a callout directly.

**Important design note:** The `ELIGIBLE_RECORD_TYPES` constant stores DeveloperNames (strings), not record type IDs. DeveloperNames are stable across sandboxes and refreshes; IDs are not. The lookup from DeveloperName → Id happens at runtime via SOQL.

---

## AsanaTaskQueueable.cls

The async execution wrapper that performs the actual callout. Salesforce triggers cannot make synchronous HTTP callouts, so this class implements `Queueable` and `Database.AllowsCallouts` to defer the work to a separate execution context.

**Steps:**

1. Re-queries the Opportunities by ID to get current field values (the IDs passed from the handler are the only thing carried across the async boundary).
2. For each Opportunity, calls either `AsanaTaskService.createTask(opp)` or `AsanaTaskService.updateTask(opp)` depending on the `Mode` enum value.
3. On a successful `CREATE_TASK`, collects the returned GID and writes it back to `Asana_Task_GID__c` via `Database.update(..., false)` (partial success — one failure does not kill others).
4. Catches all exceptions per Opportunity and logs them at `ERROR` level via `System.debug`. Exceptions do not re-throw — the trigger has already committed, so there is nothing to roll back.

**Known limitation:** Failures are currently logged only via `System.debug`. They will not appear unless a debug trace is active for the running user. A future phase should write failures to an `Integration_Log__c` custom object and surface alerts.

**Mode enum:** `CREATE_TASK` or `UPDATE_TASK`. Passed in at construction time by the handler.

---

## AsanaTaskService.cls

The Asana API client. It encapsulates the Asana REST API data — the endpoint, authentication, JSON payload structure, custom field GID mappings, and response parsing.

**Named Credential:** All callouts go through the `Asana` Named Credential (`callout:Asana`), which handles Bearer token injection. The actual PAT is stored in the credential, not in code.

**Payload construction — create:**
```json
{
  "data": {
    "name": "<Opportunity Name>",
    "projects": ["1213427513705845"],
    "custom_fields": { ... }
  }
}
```

**Payload construction — update (PUT to `/tasks/<gid>`):**
Same structure without `name` or `projects` — only `custom_fields`.

**Date field format:** Asana date custom fields require a JSON object `{"date": "YYYY-MM-DD"}`, not a plain string. The `asDateValue()` helper produces this format. Plain strings are rejected by the API with a 400 error.

**Null handling:** `JSON.serialize(..., true)` is used with suppress-nulls enabled. Fields with null values are omitted from the payload rather than sent as `null`, which prevents accidentally clearing Asana fields that aren't mapped.

**Custom field GID constants:** Defined as private `static final String` constants at the top of the class. If field GIDs change in Asana (e.g., fields are deleted and recreated), update the constants here. If the field mapping grows significantly, consider migrating to Custom Metadata.

**Error handling:** Any non-2xx HTTP response throws `AsanaException`. The caller (queueable) is responsible for catching it.

---

## AsanaTaskServiceTest.cls

The test class for `AsanaTaskService`. It uses an `HttpCalloutMock` implementation (`AsanaMock`) to simulate Asana API responses without making real callouts.

**What is covered:**
- `createTask_success_returnsGid` — 201 response returns the GID from the response body
- `updateTask_success_noException` — 200 response completes without error
- `updateTask_missingGid_throws` — calling `updateTask` on an Opp with no GID throws `AsanaException`
- `createTask_apiError_throws` — 400 response throws `AsanaException`

**What is NOT covered (known gap):**
- `OpportunityTrigger` — 0% coverage
- `OpportunityAsanaSyncHandler` — 0% coverage
- `AsanaTaskQueueable` — 0% coverage

This gap does not block sandbox deploys but **will block a production deploy**, which requires 75% coverage per class. Tests for the trigger, handler, and queueable must be written before going to production.

**`buildOpp()` helper:** Constructs a minimal in-memory `Opportunity` object for test use. Does not insert to the database — avoids DML overhead and trigger side effects not relevant to service-layer tests. `Lead_Participant__c` is set to `null` (not `''`) because it is a Lookup field; empty string throws `System.StringException: Invalid id`.

**Formula fields:** `Opportunity_Owner_Name__c` and `TEA_Loan_Fund__c` are not assigned in `buildOpp()` because formula fields are not writable in Apex test context.
