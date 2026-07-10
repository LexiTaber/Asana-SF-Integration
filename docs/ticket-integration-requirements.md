# Dev Ticket: Salesforce → Asana Integration (Apex Replacement)

## Background

The Loan Onboarding Tracker 2.0 Asana project previously relied on the Asana-native connector (managed package) to auto-generate Salesforce Flows. Those Flows created tasks and kept custom fields in sync when a loan Opportunity moved to Closed stage. Two specific Asana Rules drove this behavior — Rule #1 (Create Task) and Rule #2 (Keep In Sync).

This approach had two known failure modes:
- **Orphaned Flows**: the Asana-managed package created Salesforce Flows that persisted after the integration was modified, causing conflicts.
- **Intermittent firing**: the Asana Rules would occasionally fail to fire with no clear error (hyp. record refreshes or lack of execution order enforcement in flows as built by Asana managed package)

## Goal

Replace the Asana-managed Rules entirely with Apex The Salesforce side owns the integration end-to-end. The Asana-native connector and its generated Flows are no longer involved in task creation or field population. Asana becomes the listener for the data flow.

## Integration Requirements

### Task Creation
- A new Asana task is created in the **Loan Onboarding Tracker 2.0** project (GID `1213427513705845`) when a Salesforce Opportunity:
  - Has record type `Loan` or `Loan - Recovery`
  - Has `StageName` = `Closed`
  - Does **not** already have an `Asana_Task_GID__c` value
  - This applies on both **insert** (Opp created directly at Closed) and **update** (stage transitions to Closed from another value)

### Task Updates
- When an Opportunity already has an `Asana_Task_GID__c` and any of the following fields change, the corresponding Asana task is updated via PUT:
  - `Name`, `Colson_Number__c`, `Maturity_Date__c`, `Outstanding_Amount__c`, `StageName`, `Opportunity_Owner_Name__c`, `CloseDate`, `TEA_Loan_Fund__c`, `Participation_Loan1__c`, `Lead_Participant__c`

### Field Mapping
| Salesforce Field | Asana Custom Field GID | Asana Field Type |
|---|---|---|
| `Colson_Number__c` | `1213472337751772` | text |
| `Maturity_Date__c` | `1213472337751784` | date |
| `Outstanding_Amount__c` | `1213472337751908` | number |
| `StageName` | `1213472337751766` | text |
| `Opportunity_Owner_Name__c` | `1213558974165924` | text (formula — read-only in SF) |
| `Close_Date__c` | `1213558974165918` | date |
| `TEA_Loan_Fund__c` | `1215983658524794` | text (formula — read-only in SF) |
| `Participation_Loan1__c` | `1215983686119784` | text |
| `Lead_Participant__c` | `1216018561523010` | text |

The Opportunity `Name` is used as the Asana task name on create only.

## Technical Approach

- **Apex Trigger** on Opportunity (`after insert`, `after update`) — entry point
- **Handler class** (`OpportunityAsanaSyncHandler`) — applies eligibility filters and routing logic; queues async job
- **Queueable class** (`AsanaTaskQueueable`) — deferred async executor that performs the HTTP callout; required because Salesforce does not allow synchronous callouts from trigger context
- **Service class** (`AsanaTaskService`) — builds the JSON payload, makes the callout via Named Credential, parses the response
- On successful task creation, the returned Asana task GID is written back to `Asana_Task_GID__c` (Text 20) on the Opportunity

## Configuration Dependencies

| Item | Value / Location |
|---|---|
| Named Credential | `Asana` (Summer '26 External Credential + Named Credential model, Custom auth protocol, Bearer token) |
| Auth | Personal Access Token (PAT) — temporary |
| `Asana_Task_GID__c` | Custom Text(20) field on Opportunity — must exist in org before deploy |
| Eligible Record Types | `Loan` (GID `0126Q0000005RfcQAE`), `Loan_NYC_Recovery` (GID `0120d000000cXlVAAU`) |

## Out of Scope

The following are owned by other systems/processes:
- People-field resolution JavaScript script
- Section-mover rules
- Subtask rules

## Acceptance Criteria

- Creating or Updating a `Loan` or `Loan - Recovery` Opportunity with `StageName = Closed` results in a new task in the Asana project within seconds
- The task's custom fields are populated from the mapped Salesforce fields
- The `Asana_Task_GID__c` field on the Opportunity is populated with the returned task GID after creation
- Updating a tracked field on an Opportunity that already has a GID results in the Asana task being updated
- All 4 `AsanaTaskServiceTest` tests pass