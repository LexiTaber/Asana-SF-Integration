/**
 * Unit tests for AsanaTaskQueueable.
 *
 * These tests enqueue the queueable directly (they do NOT go through
 * OpportunityTrigger / OpportunityAsanaSyncHandler) so failures here
 * point specifically at the async execution / DML write-back logic,
 * not at the "should we sync" decision (that's covered in
 * OpportunityAsanaSyncHandlerTest).
 *
 * To keep that true, buildOpportunity() deliberately builds a record the
 * real trigger will ignore: a non-Loan record type AND a non-Closed
 * stage. Either alone is enough to stop OpportunityAsanaSyncHandler's
 * create-path condition from firing, but both are set for defense in
 * depth - notably, leaving RecordTypeId blank is NOT safe in this org:
 * a blank RecordTypeId silently resolves to the running user's default
 * Opportunity record type, which is 'Loan' (an eligible type), so the
 * real trigger would otherwise auto-fire its own CREATE_TASK job
 * alongside whatever job each test method enqueues explicitly, double
 * counting callouts.
 */
@isTest
private class AsanaTaskQueueableTest {

    private static Id ineligibleRecordTypeIdCache;
    private static Id ineligibleRecordTypeId() {
        if (ineligibleRecordTypeIdCache == null) {
            List<RecordType> rts = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Opportunity'
                AND IsActive = true
                AND DeveloperName NOT IN ('Loan', 'Loan_NYC_Recovery')
                LIMIT 1
            ];
            if (rts.isEmpty()) {
                Assert.fail('No active Opportunity RecordType other than \'Loan\'/\'Loan_NYC_Recovery\' ' +
                    'was found in this org. This class needs one to build test data the real ' +
                    'OpportunityAsanaSyncHandler trigger will ignore.');
            }
            ineligibleRecordTypeIdCache = rts[0].Id;
        }
        return ineligibleRecordTypeIdCache;
    }

    // Colson_Number__c is a text field, but Asana expects/displays it as a
    // number, so test data uses six-digit numeric strings rather than a
    // prefixed label like "COLSON-123".
    private static Integer colsonCounter = 100000;
    private static String nextColsonNumber() {
        colsonCounter++;
        return String.valueOf(colsonCounter);
    }

    private static Opportunity buildOpportunity(String name, String gid) {
        Account leadParticipant = new Account(Name = 'Test Lead Bank ' + name);
        insert leadParticipant;

        // Opportunity_Owner_Name__c and TEA_Loan_Fund__c are FORMULA fields
        // (not directly writeable via DML): Opportunity_Owner_Name__c is
        // derived from OwnerId, and TEA_Loan_Fund__c is derived from
        // Primary_Funding_Project__c ('JCRIF' -> "JCRIF", blank -> "NFF
        // Loan Fund"). We set the driving fields instead and let Salesforce
        // compute the formulas.
        Opportunity opp = new Opportunity(
            Name                       = name,
            RecordTypeId               = ineligibleRecordTypeId(),
            StageName                  = 'Underwriting',
            CloseDate                  = Date.today().addMonths(1),
            Amount                     = 100000,
            Colson_Number__c           = nextColsonNumber(),
            Maturity_Date__c           = Date.today().addYears(5),
            Outstanding_Amount__c      = 100000,
            OwnerId                    = UserInfo.getUserId(),
            Close_Date__c              = Date.today(),
            Primary_Funding_Project__c = 'JCRIF', // -> TEA_Loan_Fund__c formula resolves to "JCRIF"
            Participation_Loan1__c     = 'Yes',
            Lead_Participant__c        = leadParticipant.Id,
            Asana_Task_GID__c          = gid
        );
        insert opp;
        return opp;
    }

    @isTest
    static void testCreateMode_writesGidBackToOpportunity() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.gidToReturn = '222222222';
        Test.setMock(HttpCalloutMock.class, mock);

        // Insert WITHOUT a gid so CREATE_TASK has something to write back.
        Opportunity opp = buildOpportunity('CreateModeTest', null);

        Test.startTest();
        System.enqueueJob(new AsanaTaskQueueable(
            new List<Id>{ opp.Id },
            AsanaTaskQueueable.Mode.CREATE_TASK
        ));
        Test.stopTest(); // queueable runs synchronously here

        Opportunity refreshed = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('222222222', refreshed.Asana_Task_GID__c,
            'CREATE_TASK should write the Asana-returned gid back onto the Opportunity');
    }

    @isTest
    static void testCreateMode_doesNotWriteGidWhenCalloutFails() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.responseStatusCode = 500;
        mock.responseBody = '{"errors":[{"message":"Asana is down"}]}';
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpportunity('CreateFailTest', null);

        Test.startTest();
        System.enqueueJob(new AsanaTaskQueueable(
            new List<Id>{ opp.Id },
            AsanaTaskQueueable.Mode.CREATE_TASK
        ));
        Test.stopTest();
        // The key assertion is simply that stopTest() above completed without
        // throwing - AsanaTaskService.createTask throws AsanaException on a
        // 500, and AsanaTaskQueueable.execute must catch it internally.

        Opportunity refreshed = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, refreshed.Asana_Task_GID__c,
            'GID should remain blank when the create callout fails');
    }

    @isTest
    static void testUpdateMode_doesNotWriteAnyFieldOnOpportunity() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpportunity('UpdateModeTest', '333333333');

        Test.startTest();
        System.enqueueJob(new AsanaTaskQueueable(
            new List<Id>{ opp.Id },
            AsanaTaskQueueable.Mode.UPDATE_TASK
        ));
        Test.stopTest();

        System.assertEquals(1, mock.callCount, 'UPDATE_TASK should still make one callout to Asana');
        System.assertEquals('PUT', mock.lastRequest().getMethod());

        Opportunity refreshed = [SELECT Asana_Task_GID__c, LastModifiedDate FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('333333333', refreshed.Asana_Task_GID__c,
            'UPDATE_TASK must not perform any DML on the Opportunity (per class doc: "no DML is needed")');
    }

    @isTest
    static void testUpdateMode_calloutExceptionIsCaughtAndDoesNotPropagate() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.responseStatusCode = 404;
        mock.responseBody = '{"errors":[{"message":"Task not found"}]}';
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpportunity('UpdateFailTest', '444444444');

        Test.startTest();
        // Should not throw out of stopTest() - AsanaTaskService.updateTask
        // throws AsanaException on the 404, and execute() must swallow it.
        System.enqueueJob(new AsanaTaskQueueable(
            new List<Id>{ opp.Id },
            AsanaTaskQueueable.Mode.UPDATE_TASK
        ));
        Test.stopTest();

        System.assert(true, 'Reaching this line means the queueable absorbed the callout failure without throwing');
    }

    @isTest
    static void testCreateMode_multipleOpportunities_allReceiveGid() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.gidToReturn = '777777777';
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp1 = buildOpportunity('MultiA', null);
        Opportunity opp2 = buildOpportunity('MultiB', null);

        Test.startTest();
        System.enqueueJob(new AsanaTaskQueueable(
            new List<Id>{ opp1.Id, opp2.Id },
            AsanaTaskQueueable.Mode.CREATE_TASK
        ));
        Test.stopTest();

        System.assertEquals(2, mock.postCount(), 'One create callout should fire per Opportunity in the batch');

        List<Opportunity> refreshed = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id IN :new List<Id>{ opp1.Id, opp2.Id }];
        for (Opportunity o : refreshed) {
            System.assertEquals('777777777', o.Asana_Task_GID__c);
        }
    }

    // ================================================================
    // Partial-success write-back: Database.update(toUpdateInSF, false)
    // ================================================================
    //
    // AsanaTaskQueueable.execute() collects ALL successful create-callout
    // results into one list, then writes them all back in a single
    // Database.update(toUpdateInSF, false) call. Because allOrNone=false,
    // one record's write-back failure must NOT roll back another record's
    // successful write-back in the same batch.
    //
    // To force a deterministic, org-config-independent DML failure for
    // just one record (without needing a real validation rule), we make
    // the mock return an oversized string as the "gid" for the second
    // callout - long enough to exceed Asana_Task_GID__c's max length and
    // fail with STRING_TOO_LONG, while the first record's normal-length
    // gid succeeds.
    //
    // NOTE: if Asana_Task_GID__c is defined as a Long Text Area (very high
    // max length) in your org, this oversized value may not actually fail.
    // Increase OVERSIZED_GID_LENGTH, or swap in a failure mode that matches
    // your field's actual type/length if needed.
    private static final Integer OVERSIZED_GID_LENGTH = 1000;

    @isTest
    static void testCreateMode_partialDmlFailureDoesNotBlockOtherSuccessfulWriteBacks() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.gidSequence = new List<String>{
            '888888888',                                  // opp1: normal, valid gid
            '9'.repeat(OVERSIZED_GID_LENGTH)                // opp2: deliberately too long to persist
        };
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp1 = buildOpportunity('PartialSuccessA', null);
        Opportunity opp2 = buildOpportunity('PartialSuccessB', null);

        Test.startTest();
        System.enqueueJob(new AsanaTaskQueueable(
            new List<Id>{ opp1.Id, opp2.Id },
            AsanaTaskQueueable.Mode.CREATE_TASK
        ));
        Test.stopTest();
        // The key assertion here is simply that stopTest() completes without
        // throwing: Database.update(..., false) must not surface the
        // STRING_TOO_LONG failure as an uncaught exception.

        System.assertEquals(2, mock.postCount(),
            'Both Opportunities should get a create callout regardless of what happens at DML time afterward');

        Map<Id, Opportunity> refreshed = new Map<Id, Opportunity>([
            SELECT Asana_Task_GID__c FROM Opportunity WHERE Id IN :new List<Id>{ opp1.Id, opp2.Id }
        ]);

        System.assertEquals('888888888', refreshed.get(opp1.Id).Asana_Task_GID__c,
            'opp1\'s successful write-back must persist even though opp2\'s write-back failed in the same Database.update batch');
        System.assertEquals(null, refreshed.get(opp2.Id).Asana_Task_GID__c,
            'opp2\'s write-back should have failed (oversized value) and left its GID blank, without throwing');
    }
}