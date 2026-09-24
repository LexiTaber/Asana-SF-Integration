/**
 * Tests for the Asana-sync paths of OpportunityTrigger / OpportunityAsanaSyncHandler.
 *
 * Scope: ONLY the "2026 - Asana task create/update on loan close" branches
 * added to OpportunityTrigger. The pre-existing Action Plan / SharePoint
 * folder logic in that trigger is intentionally NOT covered here.
 *
 * These are integration-style tests: they perform real DML on Opportunity
 * so the actual trigger fires, which calls OpportunityAsanaSyncHandler,
 * which enqueues AsanaTaskQueueable, which calls AsanaTaskService, which
 * makes an HTTP callout - mocked here via AsanaCalloutMock so we can
 * inspect exactly what would have been sent to Asana.
 *
 * IMPORTANT - "update path" preconditions:
 *   For the update-path tests (existing GID + tracked field change), the
 *   Opportunity is inserted with StageName = 'Closed' and Asana_Task_GID__c
 *   already populated in the SAME insert. Walking through the handler
 *   logic, that combination causes NEITHER the create branch (GID isn't
 *   blank) NOR the update branch (oldMap is null on insert) to fire - so
 *   it's a clean, callout-free way to represent "an Opportunity that
 *   already has an Asana task", without depending on a prior create
 *   callout actually having run first (that flow is already verified by
 *   the create-path tests below).
 *
 * WHY THIS WORKS, AND WHY IT'S FRAGILE:
 *   This "insert already-Closed + already-has-a-GID" trick is only silent
 *   (i.e. produces zero Asana callouts during @TestSetup, so @TestSetup
 *   doesn't need Test.setMock at all) because of two SPECIFIC conditions
 *   in OpportunityAsanaSyncHandler.handleAfter() today:
 *     1. The CREATE branch requires String.isBlank(opp.Asana_Task_GID__c).
 *        Since the baseline records are inserted WITH a GID already set,
 *        this condition is false, so CREATE never fires for them.
 *     2. The UPDATE branch requires oldOpp != null (i.e. Trigger.oldMap
 *        must have an entry). On insert, oldMap is null, so oldOpp is
 *        always null and the UPDATE branch never fires either - even
 *        though the record already has both a Closed stage and a GID.
 *   In other words, this test data relies on the handler's insert-time
 *   behavior being "neither branch fires when a GID is already present on
 *   insert." That is CURRENT behavior, not a guaranteed contract. If the
 *   handler is ever changed (e.g. to also sync on insert when a GID is
 *   already populated, to catch data-migration scenarios), this baseline
 *   strategy would silently break: @TestSetup would suddenly attempt real
 *   Asana callouts with no mock registered, since Test.setMock() cannot be
 *   configured inside @TestSetup. Anyone modifying the CREATE/UPDATE
 *   branch conditions in the handler should search for oppByLabel() usages
 *   below and re-verify this assumption still holds.
 *
 */
@isTest
private class OpportunityAsanaSyncHandlerTest {

    private static final String NON_CLOSED_STAGE = 'Underwriting';
    private static final String ANOTHER_NON_CLOSED_STAGE = 'Closing';

    // ----------------------------------------------------------------
    // Shared setup helpers
    // ----------------------------------------------------------------

    private static Id eligibleRecordTypeId() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Opportunity' AND DeveloperName = 'Loan'
            LIMIT 1
        ];
        if (rts.isEmpty()) {
            Assert.fail('No Opportunity RecordType with DeveloperName \'Loan\' found in this org. ' +
                'Update this helper (or seed the record type) before running these tests.');
        }
        return rts[0].Id;
    }

    private static Id secondEligibleRecordTypeId() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Opportunity' AND DeveloperName = 'Loan_NYC_Recovery'
            LIMIT 1
        ];
        if (rts.isEmpty()) {
            Assert.fail('No Opportunity RecordType with DeveloperName \'Loan_NYC_Recovery\' found in this org.');
        }
        return rts[0].Id;
    }

    // Used for the "ineligible record type" tests. A real, active,
    // non-Loan record type is deliberately used here instead of a null
    // RecordTypeId. Leaving RecordTypeId null causes Salesforce to
    // silently resolve it to the running user's DEFAULT Opportunity
    // record type - which in this org is 'Loan' itself - defeating the
    // point of the test and creating an unrelated INVALID_CROSS_REFERENCE_KEY
    // failure depending on which other fields are set. An explicit,
    // real, non-Loan record type Id exercises
    // OpportunityAsanaSyncHandler's !recordTypeIds.contains(opp.RecordTypeId)
    // filter the way it's actually hit in production (a real Opportunity
    // record type that just isn't one of the two Loan types), and avoids
    // default-record-type resolution entirely.
    private static Id ineligibleRecordTypeId() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Opportunity'
            AND IsActive = true
            AND DeveloperName NOT IN ('Loan', 'Loan_NYC_Recovery')
            LIMIT 1
        ];
        if (rts.isEmpty()) {
            Assert.fail('No active Opportunity RecordType other than \'Loan\'/\'Loan_NYC_Recovery\' ' +
                'was found in this org. These "ineligible record type" tests need at least one other ' +
                'active Opportunity record type to use as a negative case.');
        }
        return rts[0].Id;
    }

    // Used for the "owner changed" tracked-field test. Opportunity_Owner_Name__c
    // is a formula field driven by OwnerId, so actually changing it requires a
    // second real, active User to reassign the record to. Adjust this query if
    // your org needs a specific profile/permission set for the owner of a Loan
    // Opportunity.
    private static Id secondActiveUserId() {
        List<User> users = [
            SELECT Id FROM User
            WHERE IsActive = true AND Id != :UserInfo.getUserId()
            LIMIT 1
        ];
        if (users.isEmpty()) {
            Assert.fail('This org needs at least one other active User besides the running user ' +
                'to test an Opportunity Owner change (Opportunity_Owner_Name__c is a formula off OwnerId).');
        }
        return users[0].Id;
    }

    // Colson_Number__c is a text field, but Asana expects/displays it as a
    // number, so test data uses six-digit numeric strings rather than a
    // prefixed label like "COLSON-123".
    private static Integer colsonCounter = 100000;
    private static String nextColsonNumber() {
        colsonCounter++;
        return String.valueOf(colsonCounter);
    }

    // Builds (but does not insert) an Opportunity with every field the
    // Asana integration reads, so create-path payload assertions have
    // real values to check against.
    //
    // Opportunity_Owner_Name__c and TEA_Loan_Fund__c are FORMULA fields and
    // cannot be assigned directly via DML:
    //   - Opportunity_Owner_Name__c is derived from OwnerId
    //   - TEA_Loan_Fund__c is derived from Primary_Funding_Project__c
    //     ('JCRIF' -> "JCRIF", blank -> "NFF Loan Fund")
    // We set the driving fields here and read the computed formula values
    // back from the database (via SOQL) wherever we need to assert on them.
    private static Opportunity buildBaselineOpp(String name, Id recordTypeId, String stage, String gid) {
        Account leadParticipant = new Account(Name = 'Lead Bank ' + name);
        insert leadParticipant;

        return new Opportunity(
            Name                       = name,
            RecordTypeId               = recordTypeId,
            StageName                  = stage,
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
    }

    // ----------------------------------------------------------------
    // @TestSetup: baseline "before" records for the update-pathway tests.
    // See the class-level comment above for why this exists.
    // ----------------------------------------------------------------

    // NOTE ON THIS METHOD'S DATA SHAPE:
    // Every "already Closed + already has a GID" record below is inserted
    // in a single DML statement, in one @TestSetup call, with NO
    // Test.setMock() in effect. That only produces zero Asana callouts
    // because of the two handler conditions spelled out in the class-level
    // comment above (blank-GID check gates CREATE; oldOpp != null gates
    // UPDATE, and oldOpp is always null on insert). Every "update path"
    // test method below that calls oppByLabel() on one of these records is
    // implicitly relying on that behavior to have produced a clean,
    // callout-free starting point - it is not verifying that behavior
    // itself, just building on top of it. See the class-level comment for
    // the full explanation and the risk if the handler's conditions change.
    @TestSetup
    static void setupUpdatePathData() {
        List<Opportunity> baseline = new List<Opportunity>{
            // Not-yet-Closed, eligible record type, no GID yet. Individual
            // tests update these to 'Closed' (or to another non-Closed
            // stage) to exercise the trigger's UPDATE-context Asana logic.
            buildBaselineOpp('RTPositiveUpdate', eligibleRecordTypeId(), NON_CLOSED_STAGE, null),
            buildBaselineOpp('CreatePathUpdate', eligibleRecordTypeId(), NON_CLOSED_STAGE, null),
            buildBaselineOpp('SingleTaskUpdate', eligibleRecordTypeId(), NON_CLOSED_STAGE, null),
            buildBaselineOpp('NotClosedUpdate', eligibleRecordTypeId(), NON_CLOSED_STAGE, null),

            // Not-yet-Closed, ineligible (null) record type, no GID.
            buildBaselineOpp('RTNegativeUpdate', ineligibleRecordTypeId(), NON_CLOSED_STAGE, null),

            // Already Closed AND already carrying a GID - represents "an
            // Opportunity that already has an Asana task", without needing
            // a prior create callout to actually have run first (that flow
            // is verified separately by the create-path tests below).
            //
            // As noted above, this combination (Closed + non-blank GID, set
            // in the SAME insert) is specifically chosen so that neither the
            // CREATE branch (blocked by the non-blank GID) nor the UPDATE
            // branch (blocked by oldOpp being null on insert) fires during
            // this @TestSetup call. That is what makes it safe to insert
            // these records here without a mock registered.
            buildBaselineOpp('TrackedFieldChange', eligibleRecordTypeId(), 'Closed', '600000001'),
            buildBaselineOpp('UnrelatedFieldChange', eligibleRecordTypeId(), 'Closed', '600000002'),
            buildBaselineOpp('NoAdditionalTask', eligibleRecordTypeId(), 'Closed', '600000003'),
            buildBaselineOpp('GidUnchanged', eligibleRecordTypeId(), 'Closed', '600000004'),

            // Added for testNoOpSave_noTrackedFieldsChanged_doesNotTriggerUpdateTask().
            // Same "Closed + GID already set on insert" shape as the four
            // records above, for the same reason (clean, callout-free
            // starting point representing an already-synced Opportunity).
            buildBaselineOpp('NoOpSaveTest', eligibleRecordTypeId(), 'Closed', '600000005'),

            // Added for testMixedBatch_createAndUpdatePaths_processedTogether().
            // This one is DELIBERATELY the "not-yet-Closed, no GID" shape
            // (like RTPositiveUpdate etc. above), NOT the "Closed + GID"
            // shape - it is the record that will play the CREATE-path role
            // in the mixed-batch test, so it must still look un-synced.
            buildBaselineOpp('MixedBatchCreate', eligibleRecordTypeId(), NON_CLOSED_STAGE, null),

            // The other half of the mixed-batch test: this one uses the
            // "Closed + GID already set" shape so it plays the UPDATE-path
            // role (an already-synced Opportunity that will get a tracked
            // field changed in the same transaction as MixedBatchCreate).
            buildBaselineOpp('MixedBatchUpdate', eligibleRecordTypeId(), 'Closed', '600000006')
        };
        insert baseline;
    }

    // Fetches one of the @TestSetup baseline records by its friendly label.
    // Uses a LIKE match rather than an exact Name match: a Flow in this org
    // overwrites Opportunity Name on insert (appending the Colson number
    // onto whatever we set), so the record's Name no longer equals the
    // label exactly - but the original label text is still present as a
    // substring, since the flow only appends rather than replacing it.
    //
    // Relies on none of the 11 baseline labels being a substring of another
    // (verified: RTPositiveUpdate, CreatePathUpdate, SingleTaskUpdate,
    // NotClosedUpdate, RTNegativeUpdate, TrackedFieldChange,
    // UnrelatedFieldChange, NoAdditionalTask, GidUnchanged, NoOpSaveTest,
    // MixedBatchCreate, MixedBatchUpdate - none collide). If you add a new
    // baseline label, double check it isn't a substring of, or doesn't
    // contain, an existing one.
    //
    // Any test that calls this method for one of the "Closed + GID
    // already set" baseline records (see the @TestSetup comments above) is
    // implicitly depending on that record having produced zero Asana
    // callouts at insert time - i.e. on the handler's current CREATE/UPDATE
    // branch conditions. This method itself doesn't verify that; it just
    // trusts it and re-queries the record's current state.
    private static Opportunity oppByLabel(String label) {
        String pattern = '%' + label + '%';
        return [
            SELECT Id, Name, StageName, RecordTypeId, Asana_Task_GID__c, Colson_Number__c,
                   Maturity_Date__c, Outstanding_Amount__c, OwnerId, Close_Date__c,
                   Primary_Funding_Project__c, Participation_Loan1__c, Lead_Participant__c,
                   Description
            FROM Opportunity
            WHERE Name LIKE :pattern
            LIMIT 1
        ];
    }

    // ================================================================
    // RECORD TYPE FILTER
    // ================================================================

    @isTest
    static void testInsert_eligibleRecordType_closedStage_createsTask() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildBaselineOpp('RTPositiveInsert', eligibleRecordTypeId(), 'Closed', null);

        Test.startTest();
        insert opp;
        Test.stopTest();

        System.assertEquals(1, mock.postCount(),
            'Inserting a Closed-stage Opportunity on an eligible record type should create exactly one Asana task');
    }

    @isTest
    static void testUpdate_eligibleRecordType_becomesClosedStage_createsTask() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        // Baseline (not-yet-Closed) record created in @TestSetup, so this
        // method's only Opportunity DML is the update below.
        Opportunity opp = oppByLabel('RTPositiveUpdate');

        Test.startTest();
        opp.StageName = 'Closed';
        update opp;
        Test.stopTest();

        System.assertEquals(1, mock.postCount(),
            'Updating an eligible-record-type Opportunity to Closed should create exactly one Asana task');
    }

    @isTest
    static void testInsert_ineligibleRecordType_closedStage_noTaskCreated() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        // A real, active, non-Loan record type - not in ELIGIBLE_RECORD_TYPES.
        // (Deliberately not a null RecordTypeId - see ineligibleRecordTypeId()
        // for why that's unreliable in this org.)
        Opportunity opp = buildBaselineOpp('RTNegativeInsert', ineligibleRecordTypeId(), 'Closed', null);

        Test.startTest();
        insert opp;
        Test.stopTest();

        System.assertEquals(0, mock.callCount, 'An ineligible record type must never trigger an Asana callout, even at Closed stage');

        Opportunity refreshed = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, refreshed.Asana_Task_GID__c);
    }

    @isTest
    static void testUpdate_ineligibleRecordType_becomesClosedStage_noTaskCreated() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('RTNegativeUpdate');

        Test.startTest();
        opp.StageName = 'Closed';
        update opp;
        Test.stopTest();

        System.assertEquals(0, mock.callCount, 'An ineligible record type must never trigger an Asana callout, even when moving to Closed');
    }

    // ================================================================
    // CREATE PATH (stage transitions to Closed, no existing GID)
    // ================================================================

    @isTest
    static void testInsert_closedStage_noExistingGid_taskCreated_allFieldsMatchAsana() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.gidToReturn = '888800001';
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildBaselineOpp('CreatePathInsert', eligibleRecordTypeId(), 'Closed', null);

        Test.startTest();
        insert opp;
        Test.stopTest();

        Opportunity refreshed = [
            SELECT Asana_Task_GID__c, Name, Colson_Number__c, Maturity_Date__c, Outstanding_Amount__c,
                   StageName, Opportunity_Owner_Name__c, Close_Date__c, TEA_Loan_Fund__c,
                   Participation_Loan1__c, Lead_Participant__r.Name
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals('888800001', refreshed.Asana_Task_GID__c, 'Task should be created and GID written back');

        assertPayloadMatchesOpportunity(mock.lastPost(), refreshed);
    }

    @isTest
    static void testUpdate_becomesClosedStage_noExistingGid_taskCreated_allFieldsMatchAsana() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.gidToReturn = '888800002';
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('CreatePathUpdate');

        Test.startTest();
        opp.StageName = 'Closed';
        update opp;
        Test.stopTest();

        Opportunity refreshed = [
            SELECT Asana_Task_GID__c, Name, Colson_Number__c, Maturity_Date__c, Outstanding_Amount__c,
                   StageName, Opportunity_Owner_Name__c, Close_Date__c, TEA_Loan_Fund__c,
                   Participation_Loan1__c, Lead_Participant__r.Name
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals('888800002', refreshed.Asana_Task_GID__c, 'Task should be created and GID written back');

        assertPayloadMatchesOpportunity(mock.lastPost(), refreshed);
    }

    // Shared assertion: every custom field in the outbound create payload
    // matches the corresponding field on the (post-update) Opportunity.
    private static void assertPayloadMatchesOpportunity(HttpRequest createReq, Opportunity opp) {
        System.assertNotEquals(null, createReq, 'Expected a captured create (POST) request');

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(createReq.getBody());
        Map<String, Object> data = (Map<String, Object>) body.get('data');
        Map<String, Object> cf = (Map<String, Object>) data.get('custom_fields');

        System.assertEquals(opp.Name, data.get('name'));
        System.assertEquals(opp.Colson_Number__c, cf.get('1213472337751772'));
        System.assertEquals(String.valueOf(opp.Maturity_Date__c), ((Map<String, Object>) cf.get('1213472337751784')).get('date'));
        System.assertEquals(opp.Outstanding_Amount__c, cf.get('1213472337751908'));
        System.assertEquals(opp.StageName, cf.get('1213472337751766'));
        System.assertEquals(opp.Opportunity_Owner_Name__c, cf.get('1213558974165924'));
        System.assertEquals(String.valueOf(opp.Close_Date__c), ((Map<String, Object>) cf.get('1213558974165918')).get('date'));
        System.assertEquals(opp.TEA_Loan_Fund__c, cf.get('1215983658524794'));
        System.assertEquals(opp.Participation_Loan1__c, cf.get('1215983686119784'));
        System.assertEquals(opp.Lead_Participant__r.Name, cf.get('1216018561523010'));
    }

    @isTest
    static void testInsert_closedStage_noExistingGid_onlySingleTaskCreated() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildBaselineOpp('SingleTaskInsert', eligibleRecordTypeId(), 'Closed', null);

        Test.startTest();
        insert opp;
        Test.stopTest();

        System.assertEquals(1, mock.callCount, 'Exactly one Asana callout total (one task) should result from this insert');
        System.assertEquals(1, mock.postCount());
        System.assertEquals(0, mock.putCount());
    }

    @isTest
    static void testUpdate_becomesClosedStage_noExistingGid_onlySingleTaskCreated() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('SingleTaskUpdate');

        Test.startTest();
        opp.StageName = 'Closed';
        update opp;
        Test.stopTest();

        System.assertEquals(1, mock.callCount, 'Exactly one Asana callout total (one task) should result from this update');
        System.assertEquals(1, mock.postCount());
        System.assertEquals(0, mock.putCount());
    }

    @isTest
    static void testInsert_eligibleRecordType_notClosedStage_noTaskCreated() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildBaselineOpp('NotClosedInsert', eligibleRecordTypeId(), NON_CLOSED_STAGE, null);

        Test.startTest();
        insert opp;
        Test.stopTest();

        System.assertEquals(0, mock.callCount, 'No task should be created for an eligible record type that is not at Closed stage');
    }

    @isTest
    static void testUpdate_eligibleRecordType_toNonClosedStage_noTaskCreated() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('NotClosedUpdate');

        Test.startTest();
        opp.StageName = ANOTHER_NON_CLOSED_STAGE; // still not Closed
        update opp;
        Test.stopTest();

        System.assertEquals(0, mock.callCount,
            'No task should be created when an eligible-record-type Opportunity is updated between two non-Closed stages');
    }

    // ================================================================
    // UPDATE PATH (existing GID + tracked field change)
    // ================================================================

    @isTest
    static void testTrackedFieldChange_updatesAsanaTaskWithNewValues() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('TrackedFieldChange'); // already Closed w/ GID 600000001, from @TestSetup

        // Change every tracked field at once and confirm the resulting
        // PUT payload reflects every single new value. (Each tracked
        // field can't practically be isolated in its own Test.startTest/
        // stopTest pair - only one pair is allowed per test method - so
        // this test demonstrates the update fires and carries the new
        // value for each of the SYNCED_FIELDS in OpportunityAsanaSyncHandler.)
        //
        // Opportunity_Owner_Name__c and TEA_Loan_Fund__c are formulas, so we
        // change their DRIVING fields (OwnerId, Primary_Funding_Project__c)
        // and re-query the computed results after the update to know what
        // Asana should have received - rather than guessing the formula output.
        Account newLead = new Account(Name = 'New Lead Bank');
        insert newLead;
        Id newOwnerId = secondActiveUserId();

        Test.startTest();
        opp.Name = 'Renamed Opportunity';
        opp.Colson_Number__c = nextColsonNumber();
        opp.Maturity_Date__c = Date.today().addYears(7);
        opp.Outstanding_Amount__c = 250000;
        opp.OwnerId = newOwnerId;
        opp.Close_Date__c = Date.today().addDays(3);
        opp.Primary_Funding_Project__c = null; // -> TEA_Loan_Fund__c formula resolves to "NFF Loan Fund"
        opp.Participation_Loan1__c = 'No';
        opp.Lead_Participant__c = newLead.Id;
        // Note: StageName is also a tracked field, but changing it away
        // from 'Closed' is exercised separately in the create/negative
        // path tests above; left unchanged here to isolate this scenario
        // to "still Closed, other tracked fields changed".
        update opp;

        Opportunity postUpdate = [
            SELECT Opportunity_Owner_Name__c, TEA_Loan_Fund__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        Test.stopTest();

        System.assertEquals(0, mock.postCount(), 'A tracked-field change on an already-synced Opp should never create a second task');
        System.assertEquals(1, mock.putCount(), 'A tracked-field change should trigger exactly one UPDATE_TASK callout');

        HttpRequest putReq = mock.lastPut();
        System.assertEquals('callout:Asana_API/tasks/600000001', putReq.getEndpoint());

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(putReq.getBody());
        Map<String, Object> cf = (Map<String, Object>) ((Map<String, Object>) body.get('data')).get('custom_fields');

        System.assertEquals(opp.Colson_Number__c, cf.get('1213472337751772'));
        System.assertEquals(String.valueOf(Date.today().addYears(7)), ((Map<String, Object>) cf.get('1213472337751784')).get('date'));
        System.assertEquals(250000, (Decimal) cf.get('1213472337751908'));
        System.assertEquals(postUpdate.Opportunity_Owner_Name__c, cf.get('1213558974165924'));
        System.assertEquals(String.valueOf(Date.today().addDays(3)), ((Map<String, Object>) cf.get('1213558974165918')).get('date'));
        System.assertEquals(postUpdate.TEA_Loan_Fund__c, cf.get('1215983658524794'));
        System.assertEquals('No', cf.get('1215983686119784'));
        System.assertEquals('New Lead Bank', cf.get('1216018561523010'));
    }

    @isTest
    static void testUnrelatedFieldChange_doesNotTriggerUpdateTask() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('UnrelatedFieldChange');

        Test.startTest();
        // Description is not in OpportunityAsanaSyncHandler.SYNCED_FIELDS.
        opp.Description = 'Just an internal note, not synced to Asana';
        update opp;
        Test.stopTest();

        System.assertEquals(0, mock.callCount,
            'Changing a field outside SYNCED_FIELDS must not enqueue AsanaTaskQueueable.Mode.UPDATE_TASK');
    }

    @isTest
    static void testTrackedFieldChange_doesNotCreateAdditionalTask() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('NoAdditionalTask');

        Test.startTest();
        opp.Outstanding_Amount__c = 999999;
        update opp;
        Test.stopTest();

        System.assertEquals(0, mock.postCount(), 'A tracked-field change must never result in a CREATE_TASK (POST) callout');
        System.assertEquals(1, mock.putCount(), 'It should result in exactly one UPDATE_TASK (PUT) callout');
    }

    @isTest
    static void testTrackedFieldChange_doesNotChangeGidField() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = oppByLabel('GidUnchanged');

        Test.startTest();
        opp.Outstanding_Amount__c = 12345;
        update opp;
        Test.stopTest();

        Opportunity refreshed = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('600000004', refreshed.Asana_Task_GID__c,
            'AsanaTaskQueueable.Mode.UPDATE_TASK performs no DML, so the GID field must be unchanged after an update-path sync');
    }

    // ================================================================
    // NO-OP SAVE (re-saving an already-synced Opportunity with NO
    // actual field changes must not trigger an Asana update)
    // ================================================================
    //
    // WHY THIS TEST EXISTS:
    // OpportunityAsanaSyncHandler.anyTrackedFieldChanged() detects changes
    // with `newOpp.get(f) != oldOpp.get(f)` on Object-typed values. Apex
    // has a known gotcha where two boxed Decimals that are numerically
    // equal but have different internal scale (e.g. 100000 vs 100000.00)
    // can compare as NOT equal with `!=`. Outstanding_Amount__c is exactly
    // this kind of field (a currency/number value), so it's the field most
    // at risk of a false "changed" detection on a record that was simply
    // re-saved without any real change - which would cause the integration
    // to send spurious, unnecessary PUT callouts to Asana every time the
    // Opportunity is touched (e.g. by an unrelated Flow re-saving the
    // record, or a user opening and saving the record with no edits).
    //
    // This test performs a genuine no-op `update` - no field on the
    // in-memory Opportunity is modified at all before the DML - on a
    // baseline record that is already Closed and already has a GID (so it
    // sits squarely in "update path" territory, meaning SYNCED_FIELDS
    // comparison logic definitely runs). If anyTrackedFieldChanged()
    // (or the Decimal/Date/String fields it compares) is ever affected by
    // a scale/format mismatch between Trigger.new and Trigger.old, this
    // test should catch it as an unexpected callout.
    @isTest
    static void testNoOpSave_noTrackedFieldsChanged_doesNotTriggerUpdateTask() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        Test.setMock(HttpCalloutMock.class, mock);

        // Already Closed w/ GID 600000005, from @TestSetup. Deliberately
        // NOT modifying any field on this Opportunity before the update -
        // that's the whole point of a "no-op save."
        Opportunity opp = oppByLabel('NoOpSaveTest');

        Test.startTest();
        // A literal re-save with zero field changes. If SYNCED_FIELDS
        // comparison logic is sound, Trigger.new and Trigger.old will be
        // treated as identical for every tracked field and no callout
        // should be enqueued.
        update opp;
        Test.stopTest();

        System.assertEquals(0, mock.callCount,
            'Re-saving an Opportunity with no actual field changes must not enqueue any Asana callout ' +
            '(guards against false-positive change detection, e.g. Apex\'s boxed-Decimal scale-comparison ' +
            'gotcha on fields like Outstanding_Amount__c)');
    }

    // ================================================================
    // MIXED BATCH (a single trigger invocation containing BOTH a
    // create-path record and an update-path record at once)
    // ================================================================
    //
    // WHY THIS TEST EXISTS:
    // Every other test in this class drives exactly one Opportunity
    // through DML per test method, so each one only ever exercises
    // OpportunityAsanaSyncHandler's toCreate list OR its toUpdate list,
    // never both in the same handleAfter() invocation. In production,
    // though, a single bulk DML (e.g. a data load, a batch job, or simply
    // a multi-row edit) can easily contain some Opportunities that are
    // newly transitioning to Closed (CREATE_TASK candidates) alongside
    // others that are already-synced Opportunities with a tracked field
    // change (UPDATE_TASK candidates) - all within the SAME
    // Trigger.new / Trigger.oldMap pair.
    //
    // This test builds exactly that scenario in one `update` statement:
    //   - MixedBatchCreate: not-yet-Closed, no GID -> becomes Closed here,
    //     so it should land in toCreate and get a CREATE_TASK callout.
    //   - MixedBatchUpdate: already Closed with a GID -> gets a tracked
    //     field (Outstanding_Amount__c) changed here, so it should land in
    //     toUpdate and get an UPDATE_TASK callout.
    // It confirms the handler correctly partitions a mixed list into the
    // right buckets and enqueues both AsanaTaskQueueable jobs (one
    // CREATE_TASK, one UPDATE_TASK) from a single trigger execution,
    // without either record leaking into the other's code path.
    @isTest
    static void testMixedBatch_createAndUpdatePaths_processedTogether() {
        AsanaCalloutMockTest mock = new AsanaCalloutMockTest();
        mock.gidToReturn = '888800099'; // returned for the CREATE_TASK (POST) callout
        Test.setMock(HttpCalloutMock.class, mock);

        // Not-yet-Closed, no GID - about to become the CREATE-path record.
        Opportunity createCandidate = oppByLabel('MixedBatchCreate');
        // Already Closed w/ GID 600000006 - about to become the
        // UPDATE-path record via a tracked field change.
        Opportunity updateCandidate = oppByLabel('MixedBatchUpdate');

        Test.startTest();
        createCandidate.StageName = 'Closed'; // stage transition -> CREATE_TASK
        updateCandidate.Outstanding_Amount__c = 555555; // tracked field change -> UPDATE_TASK
        // Both records updated in ONE DML statement, so both flow through
        // the SAME Trigger.new / Trigger.oldMap and the SAME
        // OpportunityAsanaSyncHandler.handleAfter() invocation.
        update new List<Opportunity>{ createCandidate, updateCandidate };
        Test.stopTest();

        System.assertEquals(1, mock.postCount(),
            'Exactly one CREATE_TASK (POST) callout should result from the create-path record in this mixed batch');
        System.assertEquals(1, mock.putCount(),
            'Exactly one UPDATE_TASK (PUT) callout should result from the update-path record in the same mixed batch');

        // Confirm the CREATE-path record actually got its GID written back.
        Opportunity refreshedCreate = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id = :createCandidate.Id];
        System.assertEquals('888800099', refreshedCreate.Asana_Task_GID__c,
            'The create-path record in the mixed batch should have its new Asana GID written back');

        // Confirm the UPDATE-path record's PUT hit the correct existing
        // task GID's endpoint (i.e. it didn't get mixed up with the
        // create-path record's brand-new task).
        HttpRequest putReq = mock.lastPut();
        System.assertEquals('callout:Asana_API/tasks/600000006', putReq.getEndpoint(),
            'The update-path record\'s PUT should target its own pre-existing GID (600000006), not the ' +
            'other record\'s newly created one');

        // The update-path record's own GID must remain untouched (per
        // AsanaTaskQueueable's UPDATE_TASK mode doing no DML).
        Opportunity refreshedUpdate = [SELECT Asana_Task_GID__c FROM Opportunity WHERE Id = :updateCandidate.Id];
        System.assertEquals('600000006', refreshedUpdate.Asana_Task_GID__c,
            'The update-path record\'s GID must be unchanged after an UPDATE_TASK sync');
    }
}