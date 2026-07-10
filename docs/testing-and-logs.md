# Testing and Log Interpretation Guide

## Functional Test Procedure

### Prerequisites
- Deploy is current (`sf project deploy start --source-dir force-app`)
- The `Asana` Named Credential is active and the PAT is valid
- A debug trace is set for the running user in Setup → Debug Logs (recommended for first-run verification; not required for ongoing use)

### Steps

1. In Salesforce, create a new Opportunity with:
   - **Record Type:** `Loan` or `Loan - Recovery`
   - **Stage:** `Closed`
   - **Close Date:** any date
   - Any other required fields

2. Save the record.

3. Within a few seconds, verify success via **three signals**:

   **Signal 1 — Asana task created**
   Navigate to the [TEST] Loan Onboarding Tracker 2.0 project in Asana. A new task matching the Opportunity name should appear, with custom fields populated.

   **Signal 2 — GID written back to Salesforce**
   On the Opportunity record, `Asana_Task_GID__c` should contain a numeric GID (e.g., `1216097868821433`). If this field is blank, the callout failed silently.

   **Signal 3 — Queueable job completed**
   Run this in Execute Anonymous to confirm the async job ran successfully:
   ```apex
   for (AsyncApexJob j : [
       SELECT Id, Status, ExtendedStatus, CreatedDate
       FROM AsyncApexJob
       WHERE ApexClass.Name = 'AsanaTaskQueueable'
       ORDER BY CreatedDate DESC
       LIMIT 3
   ]) {
       System.debug(j.CreatedDate + ' | ' + j.Status + ' | ' + j.ExtendedStatus);
   }
   ```
   A successful run shows: `Status = Completed`, `ExtendedStatus = null`.
   A failed run shows: `Status = Failed` with an error message in `ExtendedStatus`.

---

## Direct Callout Test (Execute Anonymous)

Use this to test the Asana callout independently of the trigger — useful for diagnosing auth or payload issues without needing to create a new Opportunity each time.

```apex
Opportunity opp = [
    SELECT Id, Name, Asana_Task_GID__c,
           Colson_Number__c, Maturity_Date__c, Outstanding_Amount__c,
           StageName, Opportunity_Owner_Name__c, CloseDate,
           TEA_Loan_Fund__c, Participation_Loan1__c, Lead_Participant__c
    FROM Opportunity
    ORDER BY CreatedDate DESC
    LIMIT 1
];
System.debug('Testing callout for: ' + opp.Name);
try {
    String gid = AsanaTaskService.createTask(opp);
    System.debug('SUCCESS - GID: ' + gid);
} catch (Exception e) {
    System.debug('FAILED - ' + e.getTypeName() + ': ' + e.getMessage());
}
```

**Confirmed successful output:**
```
Testing callout for: LT Test Loan 628504: 628437
SUCCESS - GID: 1216097868821433
```

---

## Debug Log Interpretation

Enable a trace for the user in **Setup → Debug Logs** with `APEX_CODE = FINEST`. After saving an Opportunity, retrieve the log via `sf apex log list --target-org asanaint` and `sf apex log get --target-org asanaint --log-id <ID>`.

### What a successful create looks like in the trigger log

The trigger log covers the synchronous portion — the trigger firing, the handler running, and the queueable being enqueued. The callout itself runs in a separate async log.

**1. Trigger fires on AfterInsert:**
```
CODE_UNIT_STARTED|OpportunityTrigger on Opportunity trigger event AfterInsert
```

**2. Handler enters and queries record types:**
```
METHOD_ENTRY|OpportunityAsanaSyncHandler.handleAfter(List<Opportunity>, Map<Id,Opportunity>)
METHOD_ENTRY|OpportunityAsanaSyncHandler.getEligibleRecordTypeIds()
```

**3. Record type IDs are populated (non-empty set = eligible record types found):**
```
VARIABLE_ASSIGNMENT|cachedRecordTypeIds|[0126Q0000005RfcQAE, 0120d000000cXlVAAU]
```
If this shows `[]` (empty), the record type filter is blocking all opportunities — check `ELIGIBLE_RECORD_TYPES` in `OpportunityAsanaSyncHandler`.

**4. Queueable enqueued (cumulative limit usage section at end of execution):**
```
Number of queueable jobs added to the queue: 1 out of 50
```
If this shows `0`, the handler ran but did not enqueue — the Opportunity did not meet the create or update criteria (wrong stage, wrong record type, or GID already set).

### What a successful create looks like in the queueable log

The queueable runs in a separate execution and generates its own log entry (look for an `Unknown` / `Api` operation log close in time to the trigger log).

**Callout sent:**
```
CALLOUT_REQUEST|System.HttpRequest[Endpoint=callout:Asana/tasks, Method=POST]
```

**201 response received:**
```
CALLOUT_RESPONSE|System.HttpResponse[Status=Created, StatusCode=201]
```

**GID written back to Opportunity:**
```
DML_BEGIN|[N]|Op:Update|Type:Opportunity|Rows:1
```

---

## Failure Patterns

### Handler exits without enqueuing — record type not matched
**Symptom:** No queueable job in `AsyncApexJob`, `Asana_Task_GID__c` remains blank.
**Log signal:** `cachedRecordTypeIds|[]` — empty set returned from `getEligibleRecordTypeIds()`.
**Cause:** The Opportunity's record type `DeveloperName` is not in `ELIGIBLE_RECORD_TYPES` in `OpportunityAsanaSyncHandler`.

### Queueable completed but GID not written — callout failed silently
**Symptom:** `AsyncApexJob` shows `Status = Completed`, `Asana_Task_GID__c` is still blank.
**Log signal (if trace active):** `USER_DEBUG|ERROR|Asana sync failed for Opp <Id>: <error message>`
**Common causes:**
- Named Credential auth failure (expired PAT) — Asana returns 401
- Malformed payload — Asana returns 400
- Network/timeout issue

Run the direct Execute Anonymous callout test above to surface the actual error message.

### 400 — date field format error
**Error:** `Asana API 400: {"errors":[{"message":"date_value: DayAndDateTime is not a JSON object: 2026-06-24"...`
**Cause:** Date custom fields must be sent as `{"date": "YYYY-MM-DD"}`, not as a plain string. Fixed in `AsanaTaskService.asDateValue()`.

### 404 — wrong task GID on update
**Error:** `Asana API 404: {"errors":[{"message":"task: Not a recognized ID:...`
**Cause:** `Asana_Task_GID__c` on the Opportunity contains a stale or invalid GID. Clear the field and let the create path re-run, or correct the GID manually.

---

## Test Command Reference

```bash
# Run tests explicitly (confirms 4/4 pass)
sf apex run test --tests AsanaTaskServiceTest --result-format human --synchronous

# Deploy (ask before running — state what's changing and why)
sf project deploy start --source-dir force-app

# Deploy with test enforcement (blocks on <75% coverage for trigger/handler/queueable)
sf project deploy start --source-dir force-app --test-level RunSpecifiedTests --tests AsanaTaskServiceTest

# View recent logs
sf apex log list --target-org asanaint

# Retrieve a specific log
sf apex log get --target-org asanaint --log-id <LOG_ID>
```