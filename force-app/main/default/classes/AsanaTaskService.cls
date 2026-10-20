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

    private static final String NAMED_CREDENTIAL = 'callout:Asana_API';
    private static final String PROJECT_GID = '1213427513705845';

    // Custom field GIDs. The task is created in Loan Onboarding Tracker 2.0 but
    // stays on one gid as Asana Rules add it to downstream projects (Active Loans 2.0,
    // Loan Maturities 2.0, Loan Payoff Tracking, etc.) - and is usually REMOVED from
    // Loan Onboarding Tracker 2.0 along the way. Not every field exists on every one
    // of those projects (e.g. CF_PARTICIPATION_TYPE only lives on Loan Onboarding
    // Tracker 2.0, CF_PAID_OFF_DATE only on Loan Payoff Tracking), so updateTask()
    // reads which fields the task actually has before writing - see
    // dropFieldsNotOnTask().
    private static final String CF_LOAN_NUMBER     = '1213472337751772';
    private static final String CF_MATURITY_DATE   = '1213472337751784';
    private static final String CF_OUTSTANDING_AMT = '1213472337751908';
    private static final String CF_SF_STAGE        = '1213472337751766';
    private static final String CF_OPP_OWNER_TEXT  = '1213558974165924';
    private static final String CF_CLOSE_DATE      = '1213558974165918';
    private static final String CF_LOAN_FUND       = '1215983658524794';
    private static final String CF_PARTICIPATION   = '1215983686119784';
    private static final String CF_LEAD_LENDER     = '1216018561523010';
    private static final String CF_PAID_OFF_DATE   = '1218421167420225';
    private static final String CF_PARTICIPATION_TYPE = '1218783762811670';

    // "Participation Type (formula)" - the visible enum LS actually reads. It used to
    // be computed by an Asana Rule from CF_PARTICIPATION/CF_PARTICIPATION_TYPE, but
    // that Rule only runs on tasks still in Loan Onboarding Tracker 2.0, so tasks
    // that had moved downstream never got corrected. Set directly here instead,
    // since this field is on every project the task moves through.
    private static final String CF_PARTICIPATION_TYPE_FORMULA = '1215987679220031';
    private static final String OPT_NFF_LEAD_NO_PARTICIPATION = '1215987679220032';
    private static final String OPT_NFF_PARTICIPANT           = '1215987679220033';

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
        Set<String> fieldsOnTask = getTaskCustomFieldGids(opp.Asana_Task_GID__c);
        HttpRequest req = buildRequest(
            '/tasks/' + opp.Asana_Task_GID__c,
            'PUT',
            buildPayload(opp, false, fieldsOnTask)
        );
        HttpResponse res = new Http().send(req);
        validate(res);
    }

    // Maps SF's two participation fields onto the "Participation Type (formula)"
    // enum option, per LS's logic (Ben Zimmitti, 9/15/2026). Returns null when it
    // can't be determined (Yes with no Sold/Purchased yet, or Participation Loan
    // blank) so the field is left as-is rather than guessed.
    @TestVisible
    private static String participationTypeOptionGid(Opportunity opp) {
        if (opp.Participation_Loan1__c == 'No') return OPT_NFF_LEAD_NO_PARTICIPATION;
        if (opp.Participation_Loan1__c == 'Yes') {
            if (opp.Participation_Type__c == 'Sold') return OPT_NFF_LEAD_NO_PARTICIPATION;
            if (opp.Participation_Type__c == 'Purchased') return OPT_NFF_PARTICIPANT;
        }
        return null;
    }

    // ---------- internal ----------

    // Returns the gids of the custom fields the task currently has (the union of
    // its projects' fields), or null if Asana's response doesn't list them.
    private static Set<String> getTaskCustomFieldGids(String taskGid) {
        HttpRequest req = buildRequest(
            '/tasks/' + taskGid + '?opt_fields=custom_fields.gid',
            'GET',
            null
        );
        HttpResponse res = new Http().send(req);
        validate(res);

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> data = (Map<String, Object>) parsed.get('data');
        List<Object> customFields = data == null ? null : (List<Object>) data.get('custom_fields');
        if (customFields == null) return null;

        Set<String> gids = new Set<String>();
        for (Object cf : customFields) {
            gids.add((String) ((Map<String, Object>) cf).get('gid'));
        }
        return gids;
    }

    private static HttpRequest buildRequest(String path, String method, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        if (body != null) {
            req.setBody(body);
        }
        req.setTimeout(60000);
        return req;
    }

    private static String buildPayload(Opportunity opp, Boolean isCreate) {
        return buildPayload(opp, isCreate, null);
    }

    private static String buildPayload(Opportunity opp, Boolean isCreate, Set<String> fieldsOnTask) {
        Map<String, Object> data = new Map<String, Object>();

        if (isCreate) {
            data.put('name', opp.Name);
            data.put('projects', new List<String>{ PROJECT_GID });
            String sfUrl = URL.getOrgDomainUrl().toExternalForm()
                + '/lightning/r/Opportunity/' + opp.Id + '/view';
            data.put('html_notes', '<body><a href="' + sfUrl + '">View in Salesforce</a></body>');
        }

        Map<String, Object> customFields = new Map<String, Object>();
        putIfNotNull(customFields, CF_LOAN_NUMBER,     asString(opp.Colson_Number__c));
        putIfNotNull(customFields, CF_MATURITY_DATE,   asDateValue(opp.Maturity_Date__c));
        putIfNotNull(customFields, CF_OUTSTANDING_AMT, opp.Outstanding_Amount__c);
        putIfNotNull(customFields, CF_SF_STAGE,        asString(opp.StageName));
        putIfNotNull(customFields, CF_OPP_OWNER_TEXT,  asString(opp.Opportunity_Owner_Name__c));
        putIfNotNull(customFields, CF_CLOSE_DATE,      asDateValue(opp.Close_Date__c));
        putIfNotNull(customFields, CF_LOAN_FUND,       asString(opp.TEA_Loan_Fund__c));
        putIfNotNull(customFields, CF_PARTICIPATION,   asString(opp.Participation_Loan1__c));
        putIfNotNull(customFields, CF_LEAD_LENDER,     asString(opp.getSObject('Lead_Participant__r')?.get('Name')));
        putIfNotNull(customFields, CF_PARTICIPATION_TYPE, asString(opp.Participation_Type__c));
        putIfNotNull(customFields, CF_PAID_OFF_DATE,   asDateValue(opp.Paid_off_Date__c));
        putIfNotNull(customFields, CF_PARTICIPATION_TYPE_FORMULA, participationTypeOptionGid(opp));

        if (fieldsOnTask != null) {
            dropFieldsNotOnTask(customFields, fieldsOnTask, opp);
        }

        data.put('custom_fields', customFields);

        return JSON.serialize(new Map<String, Object>{ 'data' => data }, true /* suppress nulls */);
    }

    // JSON.serialize's suppressNulls only omits null *fields* on typed objects/sObjects,
    // not null *entries* in a Map<String, Object> like custom_fields - a null value here
    // would still serialize as an explicit "key": null, which would clear whatever value
    // that field already holds in Asana. Keeping the key out of the map entirely instead.
    // Asana rejects the WHOLE update if it names a custom field the task doesn't have
    // (e.g. Participation Type (SF) once the task has left Loan Onboarding Tracker 2.0),
    // so one project-specific field would otherwise block every other field too.
    private static void dropFieldsNotOnTask(Map<String, Object> customFields, Set<String> fieldsOnTask, Opportunity opp) {
        for (String gid : new List<String>(customFields.keySet())) {
            if (!fieldsOnTask.contains(gid)) {
                customFields.remove(gid);
                System.debug(LoggingLevel.INFO, 'Asana task ' + opp.Asana_Task_GID__c + ' (Opp ' + opp.Id
                    + ') has no custom field ' + gid + ' on its current projects - skipped');
            }
        }
    }

    private static void putIfNotNull(Map<String, Object> target, String key, Object value) {
        if (value != null) {
            target.put(key, value);
        }
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
