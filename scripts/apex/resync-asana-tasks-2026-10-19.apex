// One-time resync: re-push every synced Loan Opportunity's current SF values to its
// existing Asana task, AFTER deploying the participation-type/downstream-projects fix.
//
// Why: before the fix, updates to tasks that had moved out of Loan Onboarding Tracker
// 2.0 (Active Loans 2.0, Loan Maturities 2.0, ...) failed whenever the payload named
// a field those projects don't have (Participation Type (SF), Paid Off Date), and the
// "Participation Type (formula)" Asana Rule never ran on those tasks at all. So their
// Participation Type (formula) - and any field changed since 10/1, e.g. Stage on
// 900662 - can be stale. Prod as of 10/19: 155 Opps with a task, 15 of them Yes+Sold.
//
// Safe to re-run: it only writes current SF values onto existing tasks (UPDATE_TASK
// never creates tasks or touches Salesforce). AsanaTaskQueueable chains itself in
// chunks to stay under the callout limit, so one enqueue is enough.

List<Id> oppIds = new List<Id>();
for (Opportunity o : [
    SELECT Id FROM Opportunity
    WHERE Asana_Task_GID__c != null
    AND RecordType.DeveloperName IN ('Loan', 'Loan_NYC_Recovery')
]) {
    oppIds.add(o.Id);
}

System.debug('Resync target count: ' + oppIds.size());
System.enqueueJob(new AsanaTaskQueueable(oppIds, AsanaTaskQueueable.Mode.UPDATE_TASK));

// ---------------------------------------------------------------------
// AFTER the jobs finish (one AsanaTaskQueueable row per 45 Opps in
// AsyncApexJob), spot-check Ben's loans in Asana - 900582, 900597 and
// 900618 should now read "NFF Lead/No Participation", and 900662's
// Salesforce Stage should read "Paid Off". Per-task failures are only
// in System.debug (AsanaTaskQueueable swallows them), so set a debug
// trace on the running user first if you want a record of any.
// ---------------------------------------------------------------------
