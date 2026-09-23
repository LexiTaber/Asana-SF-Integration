@isTest
public with sharing class Opportunity_UtilsTest {
	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-06-01

		Tests Classes:	Opportunity_Utils
		Test Run Date:	2023-06-01

		Gage Payne : Upsource Solutions : 2023-07-03 - Updated all the logic to use
		the single metadata record that points to a formula field instead of a different
		metadata record for each record type
		==========================================================================*/

	@isTest
	static void testStampingAccountFolder() {

		Id loanRecType = Schema.SObjectType.Opportunity.getRecordTypeInfosByName().get('Loan').getRecordTypeId();
		Id eventRecType = Schema.SObjectType.Opportunity.getRecordTypeInfosByName().get('Event').getRecordTypeId();

		// Metadata
		List<Automatic_Object_Folder_Sync__mdt> opp_folderSyncMDTs = [SELECT Sync_Object_Folder_Field__r.QualifiedApiName, Path_Levels_to_Remove__c 
																	FROM Automatic_Object_Folder_Sync__mdt 
																	WHERE Triggering_Object__c = 'Opportunity' 
																	];

		// Edit:DS 2023-06-13 - This is commented out because we saw that the folder field is overridden in the sFiles applet
		// fileforcem1__Sharepoint_Object_Settings__mdt opp_sFilesObjMDT = [SELECT fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName 
		// 																FROM fileforcem1__Sharepoint_Object_Settings__mdt
		// 																WHERE DeveloperName = 'Opportunity' LIMIT 1];

		// Edit:DS 2023-06-13 - This is commented out because we saw that the folder field is overridden in the sFiles applet
		// String oppField = opp_sFilesObjMDT.fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName;
		String oppField = 'Sharepoint_Folder_ID_sFiles__c';

		List<Account> accList = TestDataFactory.createDefaultAccounts(3, false);
		accList[1].SharePoint_Folder_ID_Client_sFiles__c = 'foobarfoobar';
		insert accList;

		List<Opportunity> oppList = TestDataFactory.createDefaultOpportunities(2, accList[0].Id, false);
		oppList.add(TestDataFactory.createDefaultOpportunity(accList[1].Id, false));
		oppList.add(TestDataFactory.createDefaultOpportunity(accList[2].Id, false));
		// opp 1
		oppList[0].RecordTypeId = loanRecType;
		oppList[0].StageName = 'Active';
		// opp 2
		oppList[1].RecordTypeId = eventRecType;
		oppList[1].StageName = 'Active';
		// opp 3
		oppList[2].RecordTypeId = loanRecType;
		oppList[2].StageName = 'Active';
		// opp 4
		oppList[3].RecordTypeId = loanRecType;
		oppList[3].StageName = 'Active';
		insert oppList;

		oppList[0].put(oppField, 'foofoo');
		oppList[1].put(oppField, 'foofoo');
		oppList[2].put(oppField, 'foofoo');
		oppList[3].put(oppField, 'foofoo');

		Test.startTest();
		update oppList;
		Test.stopTest();

		List<Account> stampedAccs = [SELECT Name, SharePoint_Folder_ID_Client_sFiles__c, SharePoint_Folder_ID_Funder_sFiles__c FROM Account WHERE Id IN :accList ORDER BY Name ASC];

		// RECORD TYPE BEING CHANGED AFTER INSERT MAY BE THE CAUSE OF A TEST FAILURE

		// Both Client and Funder field on Account 1 should be stamped, Account 2 should be unchanged, Account 3 should be stamped on client
		System.assertEquals('foobar', stampedAccs[0].SharePoint_Folder_ID_Client_sFiles__c);
		System.assertEquals('foobar', stampedAccs[0].SharePoint_Folder_ID_Funder_sFiles__c);
		System.assertEquals('foobarfoobar', stampedAccs[1].SharePoint_Folder_ID_Client_sFiles__c);
		System.assertEquals(true, ( stampedAccs[1].SharePoint_Folder_ID_Funder_sFiles__c == null));
		System.assertEquals('foobar', stampedAccs[2].SharePoint_Folder_ID_Client_sFiles__c);
		System.assertEquals(true, ( stampedAccs[2].SharePoint_Folder_ID_Funder_sFiles__c == null));
		// Duplicate for debugging test
		// System.assertEquals('foobar', stampedAcc.SharePoint_Folder_ID_Client_sFiles__c);
	}
}