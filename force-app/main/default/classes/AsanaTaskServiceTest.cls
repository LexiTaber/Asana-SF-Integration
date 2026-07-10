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
        public AsanaMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }
}
