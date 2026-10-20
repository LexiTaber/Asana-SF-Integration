/**
 * Async executor for Asana task create/update callouts.
 *
 * Apex triggers cannot make synchronous HTTP callouts; queueable defers
 * the work to a separate execution context that allows callouts.
 *
 * On CREATE, writes the returned Asana task GID back to the Opportunity.
 * On UPDATE, no DML is needed.
 *
 * Failures are logged but do not throw. The trigger has already committed,
 * so a thrown exception here cannot roll back the SF change.
 * TODO (Phase 2): write failures to Integration_Log__c and surface alerts.
 */
public without sharing class AsanaTaskQueueable implements Queueable, Database.AllowsCallouts {

    public enum Mode { CREATE_TASK, UPDATE_TASK }

    // Each UPDATE_TASK makes 2 callouts (read the task's fields, then PUT), against a
    // 100-callout limit per job. Anything past this is chained to a follow-up job.
    @TestVisible
    private static Integer maxOppsPerJob = 45;
    @TestVisible
    private static List<Id> chainedRemainder;

    private List<Id> opportunityIds;
    private Mode taskMode;

    public AsanaTaskQueueable(List<Id> opportunityIds, Mode taskMode) {
        this.opportunityIds = opportunityIds;
        this.taskMode = taskMode;
    }

    public void execute(QueueableContext ctx) {
        if (opportunityIds.size() > maxOppsPerJob) {
            List<Id> thisJob = new List<Id>();
            List<Id> remainder = new List<Id>();
            for (Id oppId : opportunityIds) {
                if (thisJob.size() < maxOppsPerJob) {
                    thisJob.add(oppId);
                } else {
                    remainder.add(oppId);
                }
            }
            opportunityIds = thisJob;
            chainedRemainder = remainder;
            // Apex tests can't chain queueables - tests assert on chainedRemainder instead
            if (!Test.isRunningTest()) {
                System.enqueueJob(new AsanaTaskQueueable(remainder, taskMode));
            }
        }

        List<Opportunity> opps = [
            SELECT Id, Name, Asana_Task_GID__c,
                   Colson_Number__c, Maturity_Date__c, Outstanding_Amount__c,
                   StageName, Opportunity_Owner_Name__c, Close_Date__c,
                   TEA_Loan_Fund__c, Participation_Loan1__c, Lead_Participant__c,
                   Lead_Participant__r.Name, Participation_Type__c, Paid_off_Date__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
        ];

        List<Opportunity> toUpdateInSF = new List<Opportunity>();

        for (Opportunity opp : opps) {
            try {
                if (taskMode == Mode.CREATE_TASK) {
                    String gid = AsanaTaskService.createTask(opp);
                    if (String.isNotBlank(gid)) {
                        toUpdateInSF.add(new Opportunity(
                            Id = opp.Id,
                            Asana_Task_GID__c = gid
                        ));
                    }
                } else {
                    AsanaTaskService.updateTask(opp);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Asana sync failed for Opp ' + opp.Id + ' (' + taskMode + '): ' + e.getMessage());
            }
        }

        if (!toUpdateInSF.isEmpty()) {
            // Use database.update with allOrNone=false to avoid one failure killing the batch
            Database.update(toUpdateInSF, false);
        }
    }
}
