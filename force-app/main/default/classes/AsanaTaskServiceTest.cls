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

    private class AsanaMock implements HttpCalloutMock {
        private Integer status;
        private String body;
        public String lastRequestBody;
        public AsanaMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            lastRequestBody = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    // Custom field GIDs mirrored from AsanaTaskService for payload assertions.
    private static final String CF_PARTICIPATION_TYPE = '1218783762811670';
    private static final String CF_PAID_OFF_DATE = '1218421167420225';

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
}
