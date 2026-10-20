/**
 * Tests for AsanaTaskService.
 *
 * Note: this covers the service layer (payload construction, callout,
 * response handling). The handler and queueable should get their own
 * tests for full coverage of trigger logic in production deployments.
 */
@isTest
private class AsanaTaskServiceTest {

    @isTest
    static void createTask_success_returnsGid() {
        Test.setMock(HttpCalloutMock.class,
            new AsanaMock(201, '{"data":{"gid":"1234567890"}}'));

        Opportunity opp = buildOpp();

        Test.startTest();
        String gid = AsanaTaskService.createTask(opp);
        Test.stopTest();

        System.assertEquals('1234567890', gid, 'Should return the new task GID');
    }

    @isTest
    static void updateTask_success_noException() {
        Test.setMock(HttpCalloutMock.class,
            new AsanaMock(200, '{"data":{"gid":"1234567890"}}'));

        Opportunity opp = buildOpp();
        opp.Asana_Task_GID__c = '1234567890';

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();
        // No exception = pass
    }

    @isTest
    static void updateTask_missingGid_throws() {
        Opportunity opp = buildOpp(); // no Asana_Task_GID__c

        Test.startTest();
        try {
            AsanaTaskService.updateTask(opp);
            System.assert(false, 'Expected AsanaException');
        } catch (AsanaTaskService.AsanaException e) {
            System.assert(e.getMessage().contains('no Asana_Task_GID__c'));
        }
        Test.stopTest();
    }

    @isTest
    static void createTask_apiError_throws() {
        Test.setMock(HttpCalloutMock.class,
            new AsanaMock(400, '{"errors":[{"message":"bad request"}]}'));

        Opportunity opp = buildOpp();
        Boolean threw = false;

        Test.startTest();
        try {
            AsanaTaskService.createTask(opp);
        } catch (AsanaTaskService.AsanaException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Expected AsanaException on 4xx response');
    }

    private static Opportunity buildOpp() {
        Opportunity opp = new Opportunity(
            Name = 'Test Loan',
            StageName = 'Closed',
            CloseDate = Date.today(),
            Colson_Number__c = 'L-12345',
            Outstanding_Amount__c = 100000,
            Participation_Loan1__c = 'No',
            Lead_Participant__c = null
        );
        // Opportunity_Owner_Name__c and TEA_Loan_Fund__c are formula fields, not writeable in tests
        opp.put('Maturity_Date__c', Date.today().addYears(5));
        return opp;
    }

    // updateTask() first GETs the task's custom fields, then PUTs. The GET answers
    // with taskFieldGids (every synced field by default, i.e. a task still in Loan
    // Onboarding Tracker 2.0 that has also reached Loan Payoff Tracking); the PUT
    // answers with status/body and is the request lastRequestBody captures.
    private class AsanaMock implements HttpCalloutMock {
        private Integer status;
        private String body;
        public String lastRequestBody;
        public Set<String> taskFieldGids = new Set<String>(ALL_SYNCED_FIELD_GIDS);
        public AsanaMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getMethod() == 'GET') {
                List<Object> fields = new List<Object>();
                for (String gid : taskFieldGids) {
                    fields.add(new Map<String, Object>{ 'gid' => gid });
                }
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => new Map<String, Object>{ 'custom_fields' => fields }
                }));
                return res;
            }
            lastRequestBody = req.getBody();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    private class FailingGetMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('GET', req.getMethod(), 'No PUT should be attempted after the lookup fails');
            HttpResponse res = new HttpResponse();
            res.setStatusCode(404);
            res.setBody('{"errors":[{"message":"Not found"}]}');
            return res;
        }
    }

    // Custom field GIDs mirrored from AsanaTaskService for payload assertions.
    private static final String CF_PARTICIPATION_TYPE = '1218783762811670';
    private static final String CF_PAID_OFF_DATE = '1218421167420225';
    private static final String CF_SF_STAGE = '1213472337751766';
    private static final String CF_PARTICIPATION_TYPE_FORMULA = '1215987679220031';
    private static final String OPT_NFF_LEAD_NO_PARTICIPATION = '1215987679220032';
    private static final String OPT_NFF_PARTICIPANT = '1215987679220033';

    private static final Set<String> ALL_SYNCED_FIELD_GIDS = new Set<String>{
        '1213472337751772', '1213472337751784', '1213472337751908', CF_SF_STAGE,
        '1213558974165924', '1213558974165918', '1215983658524794', '1215983686119784',
        '1216018561523010', CF_PAID_OFF_DATE, CF_PARTICIPATION_TYPE, CF_PARTICIPATION_TYPE_FORMULA
    };

    private static Map<String, Object> customFieldsFromPayload(String requestBody) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
        Map<String, Object> data = (Map<String, Object>) parsed.get('data');
        return (Map<String, Object>) data.get('custom_fields');
    }

    @isTest
    static void updateTask_participationTypeSold_includedInPayload() {
        AsanaMock mock = new AsanaMock(200, '{"data":{"gid":"1234567890"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpp();
        opp.Asana_Task_GID__c = '1234567890';
        opp.Participation_Loan1__c = 'Yes';
        opp.put('Participation_Type__c', 'Sold');

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();

        Map<String, Object> customFields = customFieldsFromPayload(mock.lastRequestBody);
        System.assertEquals('Sold', customFields.get(CF_PARTICIPATION_TYPE),
            'Participation_Type__c should be sent as-is to Asana');
    }

    @isTest
    static void updateTask_participationTypeBlank_omittedFromPayload() {
        AsanaMock mock = new AsanaMock(200, '{"data":{"gid":"1234567890"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpp(); // Participation_Loan1__c = 'No', Participation_Type__c left blank
        opp.Asana_Task_GID__c = '1234567890';

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();

        Map<String, Object> customFields = customFieldsFromPayload(mock.lastRequestBody);
        System.assert(!customFields.containsKey(CF_PARTICIPATION_TYPE),
            'Blank Participation_Type__c should be omitted, not sent as null');
    }

    @isTest
    static void updateTask_paidOffDate_includedInPayload_correctDateShape() {
        AsanaMock mock = new AsanaMock(200, '{"data":{"gid":"1234567890"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpp();
        opp.Asana_Task_GID__c = '1234567890';
        opp.put('Paid_off_Date__c', Date.newInstance(2026, 9, 30));

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();

        Map<String, Object> customFields = customFieldsFromPayload(mock.lastRequestBody);
        Map<String, Object> dateValue = (Map<String, Object>) customFields.get(CF_PAID_OFF_DATE);
        System.assertEquals('2026-09-30', dateValue.get('date'),
            'Paid_off_Date__c should be sent as {"date": "YYYY-MM-DD"}, matching other date fields');
    }

    @isTest
    static void updateTask_paidOffDateBlank_omittedFromPayload() {
        AsanaMock mock = new AsanaMock(200, '{"data":{"gid":"1234567890"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpp(); // Paid_off_Date__c left blank
        opp.Asana_Task_GID__c = '1234567890';

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();

        Map<String, Object> customFields = customFieldsFromPayload(mock.lastRequestBody);
        System.assert(!customFields.containsKey(CF_PAID_OFF_DATE),
            'Blank Paid_off_Date__c should be omitted, not sent as null');
    }

    // ---------- Participation Type (formula), set directly from SF ----------

    @isTest
    static void participationTypeOption_matchesLsLogic() {
        Opportunity opp = buildOpp();

        opp.Participation_Loan1__c = 'No';
        System.assertEquals(OPT_NFF_LEAD_NO_PARTICIPATION, AsanaTaskService.participationTypeOptionGid(opp),
            'Participation Loan = No -> NFF Lead/No Participation');

        opp.Participation_Loan1__c = 'Yes';
        opp.put('Participation_Type__c', 'Sold');
        System.assertEquals(OPT_NFF_LEAD_NO_PARTICIPATION, AsanaTaskService.participationTypeOptionGid(opp),
            'Yes + Sold (NFF is lead and sold a piece) -> NFF Lead/No Participation');

        opp.put('Participation_Type__c', 'Purchased');
        System.assertEquals(OPT_NFF_PARTICIPANT, AsanaTaskService.participationTypeOptionGid(opp),
            'Yes + Purchased -> NFF Participant');

        opp.put('Participation_Type__c', null);
        System.assertEquals(null, AsanaTaskService.participationTypeOptionGid(opp),
            'Yes with no Sold/Purchased yet is undetermined - leave Asana alone');

        opp.Participation_Loan1__c = null;
        System.assertEquals(null, AsanaTaskService.participationTypeOptionGid(opp),
            'Blank Participation Loan is undetermined - leave Asana alone');
    }

    @isTest
    static void updateTask_participationSold_setsFormulaFieldToNffLead() {
        AsanaMock mock = new AsanaMock(200, '{"data":{"gid":"1234567890"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpp();
        opp.Asana_Task_GID__c = '1234567890';
        opp.Participation_Loan1__c = 'Yes';
        opp.put('Participation_Type__c', 'Sold');

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();

        Map<String, Object> customFields = customFieldsFromPayload(mock.lastRequestBody);
        System.assertEquals(OPT_NFF_LEAD_NO_PARTICIPATION, customFields.get(CF_PARTICIPATION_TYPE_FORMULA),
            'Sold loans must land as NFF Lead/No Participation without relying on the Asana Rule');
    }

    // The 10/2026 prod bug: once a task moves from Loan Onboarding Tracker 2.0 to
    // Active Loans 2.0 it no longer has Participation Type (SF) (and may not have
    // Paid Off Date), and sending either blocked the whole update.
    @isTest
    static void updateTask_taskLeftOnboardingProject_omitsFieldsTaskDoesNotHave() {
        AsanaMock mock = new AsanaMock(200, '{"data":{"gid":"1234567890"}}');
        mock.taskFieldGids.remove(CF_PARTICIPATION_TYPE);
        mock.taskFieldGids.remove(CF_PAID_OFF_DATE);
        Test.setMock(HttpCalloutMock.class, mock);

        Opportunity opp = buildOpp();
        opp.Asana_Task_GID__c = '1234567890';
        opp.StageName = 'Paid Off';
        opp.Participation_Loan1__c = 'Yes';
        opp.put('Participation_Type__c', 'Sold');
        opp.put('Paid_off_Date__c', Date.newInstance(2026, 9, 23));

        Test.startTest();
        AsanaTaskService.updateTask(opp);
        Test.stopTest();

        Map<String, Object> customFields = customFieldsFromPayload(mock.lastRequestBody);
        System.assert(!customFields.containsKey(CF_PARTICIPATION_TYPE),
            'Participation Type (SF) is not on the task, so it must not be sent');
        System.assert(!customFields.containsKey(CF_PAID_OFF_DATE),
            'Paid Off Date is not on the task, so it must not be sent');
        System.assertEquals('Paid Off', customFields.get(CF_SF_STAGE),
            'Fields the task does have must still be sent');
        System.assertEquals(OPT_NFF_LEAD_NO_PARTICIPATION, customFields.get(CF_PARTICIPATION_TYPE_FORMULA));
    }

    @isTest
    static void updateTask_taskLookupFails_throwsWithoutPut() {
        Test.setMock(HttpCalloutMock.class, new FailingGetMock());

        Opportunity opp = buildOpp();
        opp.Asana_Task_GID__c = '1234567890';
        Boolean threw = false;

        Test.startTest();
        try {
            AsanaTaskService.updateTask(opp);
        } catch (AsanaTaskService.AsanaException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A failed task lookup (e.g. deleted task) should surface as AsanaException');
    }
}
