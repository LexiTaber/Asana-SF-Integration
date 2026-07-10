/**
 * Handles Opportunity → Asana task sync.
 *
 * Replaces Asana Rules #1 (Create Task) and #2 (Keep In Sync) on the
 * Loan Onboarding Tracker 2.0 project.
 *
 * Trigger semantics:
 *   - CREATE: Opp stage transitions to 'Closed' AND no Asana_Task_GID__c yet
 *   - UPDATE: Opp has an Asana_Task_GID__c AND any tracked field changed
 *
 * Callouts run async via AsanaTaskQueueable (triggers cannot make
 * synchronous HTTP callouts).
 */
public with sharing class OpportunityAsanaSyncHandler {

    // Record types eligible for Asana sync (IDs: 0126Q0000005RfcQAE, 0120d000000cXlVAAU)
    private static final Set<String> ELIGIBLE_RECORD_TYPES = new Set<String>{
        'Loan',
        'Loan_NYC_Recovery'
    };

    private static final String CLOSED_STAGE = 'Closed';

    // Fields whose changes should push an update to Asana.
    // Mirrors the field map agreed in design.
    private static final Set<String> SYNCED_FIELDS = new Set<String>{
        'Name',
        'Colson_Number__c',
        'Maturity_Date__c',
        'Outstanding_Amount__c',
        'StageName',
        'Opportunity_Owner_Name__c',
        'Close_Date__c',
        'TEA_Loan_Fund__c',
        'Participation_Loan1__c',
        'Lead_Participant__c'
    };

    // Cached per transaction
    private static Set<Id> cachedRecordTypeIds;

    // Prevents double-firing when a workflow/DML in the same transaction re-triggers the after update
    private static Boolean hasRun = false;

    public static void handleAfter(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        if (hasRun) return;
        hasRun = true;

        Set<Id> recordTypeIds = getEligibleRecordTypeIds();
        if (recordTypeIds.isEmpty()) return;

        List<Id> toCreate = new List<Id>();
        List<Id> toUpdate = new List<Id>();

        for (Opportunity opp : newList) {
            if (!recordTypeIds.contains(opp.RecordTypeId)) continue;

            Opportunity oldOpp = (oldMap != null) ? oldMap.get(opp.Id) : null;

            // CREATE path: stage just became Closed and no task exists
            Boolean stageBecameClosed = opp.StageName == CLOSED_STAGE
                && (oldOpp == null || oldOpp.StageName != CLOSED_STAGE);

            if (stageBecameClosed && String.isBlank(opp.Asana_Task_GID__c)) {
                toCreate.add(opp.Id);
                continue;
            }

            // UPDATE path: task exists and a tracked field changed
            if (String.isNotBlank(opp.Asana_Task_GID__c) && oldOpp != null) {
                if (anyTrackedFieldChanged(opp, oldOpp)) {
                    toUpdate.add(opp.Id);
                }
            }
        }

        if (!toCreate.isEmpty()) {
            System.enqueueJob(new AsanaTaskQueueable(toCreate, AsanaTaskQueueable.Mode.CREATE_TASK));
        }
        if (!toUpdate.isEmpty()) {
            System.enqueueJob(new AsanaTaskQueueable(toUpdate, AsanaTaskQueueable.Mode.UPDATE_TASK));
        }
    }

    private static Boolean anyTrackedFieldChanged(Opportunity newOpp, Opportunity oldOpp) {
        for (String f : SYNCED_FIELDS) {
            if (newOpp.get(f) != oldOpp.get(f)) return true;
        }
        return false;
    }

    private static Set<Id> getEligibleRecordTypeIds() {
        if (cachedRecordTypeIds == null) {
            cachedRecordTypeIds = new Set<Id>();
            for (RecordType rt : [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Opportunity'
                AND DeveloperName IN :ELIGIBLE_RECORD_TYPES
            ]) {
                cachedRecordTypeIds.add(rt.Id);
            }
        }
        return cachedRecordTypeIds;
    }
}
