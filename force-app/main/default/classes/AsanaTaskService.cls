/**
 * Asana API client for the Loan Onboarding Tracker integration.
 *
 * Encapsulates:
 *   - The Named Credential reference
 *   - Project GID and custom field GIDs (from API discovery)
 *   - JSON payload construction
 *   - Response parsing
 *
 * Field GIDs are constants. If they change in Asana, update here.
 * Consider migrating to Custom Metadata if mappings start changing often.
 */
public with sharing class AsanaTaskService {

    private static final String NAMED_CREDENTIAL = 'callout:Asana';
    private static final String PROJECT_GID = '1213427513705845';

    // Custom field GIDs (Loan Onboarding Tracker 2.0)
    private static final String CF_LOAN_NUMBER     = '1213472337751772';
    private static final String CF_MATURITY_DATE   = '1213472337751784';
    private static final String CF_OUTSTANDING_AMT = '1213472337751908';
    private static final String CF_SF_STAGE        = '1213472337751766';
    private static final String CF_OPP_OWNER_TEXT  = '1213558974165924';
    private static final String CF_CLOSE_DATE      = '1213558974165918';
    private static final String CF_LOAN_FUND       = '1215983658524794';
    private static final String CF_PARTICIPATION   = '1215983686119784';
    private static final String CF_LEAD_LENDER     = '1216018561523010';

    public class AsanaException extends Exception {}

    public static String createTask(Opportunity opp) {
        HttpRequest req = buildRequest('/tasks', 'POST', buildPayload(opp, true));
        HttpResponse res = new Http().send(req);
        validate(res);
        return parseGid(res.getBody());
    }

    public static void updateTask(Opportunity opp) {
        if (String.isBlank(opp.Asana_Task_GID__c)) {
            throw new AsanaException('Cannot update: no Asana_Task_GID__c on Opp ' + opp.Id);
        }
        HttpRequest req = buildRequest(
            '/tasks/' + opp.Asana_Task_GID__c,
            'PUT',
            buildPayload(opp, false)
        );
        HttpResponse res = new Http().send(req);
        validate(res);
    }

    // ---------- internal ----------

    private static HttpRequest buildRequest(String path, String method, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(body);
        req.setTimeout(60000);
        return req;
    }

    private static String buildPayload(Opportunity opp, Boolean isCreate) {
        Map<String, Object> data = new Map<String, Object>();

        if (isCreate) {
            data.put('name', opp.Name);
            data.put('projects', new List<String>{ PROJECT_GID });
            String sfUrl = URL.getOrgDomainUrl().toExternalForm()
                + '/lightning/r/Opportunity/' + opp.Id + '/view';
            data.put('html_notes', '<body><a href="' + sfUrl + '">View in Salesforce</a></body>');
        }

        Map<String, Object> customFields = new Map<String, Object>();
        customFields.put(CF_LOAN_NUMBER,     asString(opp.Colson_Number__c));
        customFields.put(CF_MATURITY_DATE,   asDateValue(opp.Maturity_Date__c));
        customFields.put(CF_OUTSTANDING_AMT, opp.Outstanding_Amount__c);
        customFields.put(CF_SF_STAGE,        asString(opp.StageName));
        customFields.put(CF_OPP_OWNER_TEXT,  asString(opp.Opportunity_Owner_Name__c));
        customFields.put(CF_CLOSE_DATE,      asDateValue(opp.Close_Date__c));
        customFields.put(CF_LOAN_FUND,       asString(opp.TEA_Loan_Fund__c));
        customFields.put(CF_PARTICIPATION,   asString(opp.Participation_Loan1__c));
        customFields.put(CF_LEAD_LENDER,     asString(opp.getSObject('Lead_Participant__r')?.get('Name')));

        data.put('custom_fields', customFields);

        return JSON.serialize(new Map<String, Object>{ 'data' => data }, true /* suppress nulls */);
    }

    private static String asString(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    private static Map<String, Object> asDateValue(Date d) {
        // Asana date custom fields require {"date": "YYYY-MM-DD"}, not a plain string
        return d == null ? null : new Map<String, Object>{ 'date' => String.valueOf(d) };
    }

    private static void validate(HttpResponse res) {
        Integer s = res.getStatusCode();
        if (s < 200 || s >= 300) {
            throw new AsanaException('Asana API ' + s + ': ' + res.getBody());
        }
    }

    private static String parseGid(String body) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        Map<String, Object> data = (Map<String, Object>) parsed.get('data');
        return data == null ? null : (String) data.get('gid');
    }
}
