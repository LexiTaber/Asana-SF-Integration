// One-time backfill: push recently-closed Loan Opportunities into the
// Loan Onboarding Tracker 2.0 Asana project via AsanaTaskQueueable directly
// (bypassing OpportunityAsanaSyncHandler's trigger-context eligibility gate,
// since this list is pre-confirmed Closed / no existing Asana_Task_GID__c).
//
// Source: "Report for Data Upload - Active Opps - 7.9.26.csv" (145 records)
//
// Run this whole block in one Execute Anonymous window. It enqueues 3
// Queueable jobs (chunks of ~50) to stay well under the 100-callout-per-
// transaction limit -- each job gets its own fresh governor limits.

List<Id> oppIds = new List<Id>{
    '0060d00001qkHk2', '0060d00001qkYpW', '0060d00001r9pS4', '0060d00001r9pSY', '0060d00001r9tt0', '0060d00001rYuU3', '0060d00001saX9J', '0060d00001sal8G', '0060d00001salvI', '0060d00001san1C',
    '0060d00001uPz13', '0060d00001vDrWB', '0060d00001w6Q6E', '0060d00001wLJhV', '0060d00001woZcW', '0060d00001woaHA', '0060d00001wuvBs', '0060d00001xH5CM', '0060d00001xlfe0', '0060d00001xpbAv',
    '0060d00001xwKhP', '0060d00001yHwac', '0060d00001yXaEu', '0060d00001yYzHc', '0060d00001yZUlI', '0060d00001zHbYF', '0060d00001zHzsi', '0060d00001zI2F9', '0060d00001zg4EX', '0060d00001zhFJp',
    '0060d00001zqL5e', '0060d00001zqL67', '0060d00001zqL80', '0060d00001zqLBe', '0060d00001zrTMx', '0060d000020Hjld', '0060d000020Hrwf', '0060d000020Ia6s', '0060d000020IacF', '0065000000RZ5SH',
    '0065000000XSVCz', '0065000000d4YiW', '0065000000e5Qdu', '0065000000fI1Nk', '0065000000fI1QF', '0065000000fI342', '0065000000iAZ1V', '0066Q000020e1Um', '0066Q000020e4wK', '0066Q000020e5PE',
    '0066Q000020e8BV', '0066Q000020e8Ko', '0066Q000020eEWF', '0066Q000020gwLv', '0066Q000020h1fk', '0066Q0000225yvz', '0066Q00002263Hv', '0066Q000022PKGi', '0066Q000022QVKF', '0066Q000022QWaA',
    '0066Q000022tH1J', '0066Q000022uJ6s', '0066Q000023owPv', '0066Q000023qFtX', '0066Q000024Zjr8', '0066Q000024blCp', '0066Q000024zD7n', '0066Q000024zOMx', '0066Q0000250wDo', '0066Q0000268NOI',
    '0066Q000026A70v', '0066Q000026BlCT', '0066Q000026Bxe6', '0066Q000027rjM9', '0066Q000028JPJy', '0066Q0000299hhf', '0066Q000029AD5e', '0066Q000029Aaos', '0066Q000029BGcM', '0066Q00002A1vsC',
    '0066Q00002A39Np', '0066Q00002AjF7P', '0066Q00002BTG8T', '0066Q00002BVlOV', '0066Q00002BVlTk', '0066Q00002CUVNd', '0066Q00002CWH5C', '0066Q00002CWdtI', '0067y00000PiBHZ', '0067y00000PiKns',
    '0067y00000Q2jRw', '0067y00000SBvCZ', '0067y00000SFQYM', '0067y00000Tlfzt', '0067y00000UZhtj', '0067y00000UaB3h', '0067y00000VQZ8M', '0067y00000VjNOR', '0067y00000VpVCn', '0067y00000WdO1h',
    '0067y00000XQIJH', '0067y00000Yrv4f', '0067y00000Z01Sz', '0067y00000ZI4iY', '0067y00000ZggQ8', '0067y00000cI06w', '0067y00000dWdEH', '0067y00000dsNpC', '0067y00000eDMYP', '0067y00000fbdxG',
    '0067y00000gMt2U', '0067y00000hXl2V', '0067y00000op3bm', '0067y00000pFbUw', '0067y00000pb3ET', '0067y00000s6kkE', '0067y00000tzRy6', '0067y00000w7A1H', '0067y00000wY0FW', '0067y00000wzKoQ',
    '0067y00000xIYZ7', '0067y000010VFNH', '0067y000012VVtw', '0067y000013dp28', '0067y0000143qk3', '0067y000016P467', '0067y000016Tdrg', '0067y000017JCgu', '0067y000017PFLu', '0067y00001BBhxF',
    '0067y00001C1iZ6', '0067y00001DTpol', '0067y00001FJq9s', '0067y00001FUcjT', '0067y00001Fq9hB', '0067y00001L6Vnh', '0067y00001Ldthb', '0067y00001OvJ61', '0067y00001R5EVK', '0067y00001SELFL',
    '0067y00001SUHVu', '0067y00001Sg6eg', '0067y00001WaSEA', '0067y00001YrsRE', '0067y00001s9EvO'
};

System.debug('Backfill target count: ' + oppIds.size());

Integer chunkSize = 50;
Integer jobsEnqueued = 0;
for (Integer i = 0; i < oppIds.size(); i += chunkSize) {
    List<Id> chunk = new List<Id>();
    for (Integer j = i; j < Math.min(i + chunkSize, oppIds.size()); j++) {
        chunk.add(oppIds[j]);
    }
    System.enqueueJob(new AsanaTaskQueueable(chunk, AsanaTaskQueueable.Mode.CREATE_TASK));
    jobsEnqueued++;
}

System.debug('Enqueued ' + jobsEnqueued + ' AsanaTaskQueueable jobs.');

// ---------------------------------------------------------------------
// AFTER the jobs finish (check Setup > Apex Jobs, or query AsyncApexJob
// for Status = 'Completed' on 3 rows), run this separately to see what
// actually got a GID back vs. what silently failed:
//
// SELECT Id, Name, Asana_Task_GID__c
// FROM Opportunity
// WHERE Id IN :oppIds AND Asana_Task_GID__c = null
//
// Any rows returned = failed callouts (rate limit, timeout, bad payload,
// etc. -- AsanaTaskQueueable only logs these to System.debug, nothing
// persists). Re-run the same enqueue logic above with just the failed
// IDs to retry -- it's idempotent since AsanaTaskService.createTask only
// runs for the IDs you pass in.
// ---------------------------------------------------------------------
