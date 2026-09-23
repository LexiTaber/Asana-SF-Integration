@isTest
public with sharing class AccountStampSFilesFolderField_QueueTest {
	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-05-31
	
		Tests Classes:	AccountStampSFilesFolderField_Queueable
		Test Run Date:	2023-06-01

		Daniel Serban : Upsource Solutions : 2023-07-26 - Updated to match code changes
		==========================================================================*/

	@isTest
	static void testOppAndCampaign() {
		// Metadata
		Automatic_Object_Folder_Sync__mdt opp_folderSyncMDT = [SELECT Object_to_Sync_Field_Lookup__r.QualifiedApiName, Field_to_Sync_Into__r.QualifiedApiName, Path_Levels_to_Remove__c 
																FROM Automatic_Object_Folder_Sync__mdt 
																WHERE Trigger_Object_Lookup__r.QualifiedApiName = 'Opportunity' LIMIT 1];

		Automatic_Object_Folder_Sync__mdt camp_folderSyncMDT = [SELECT Object_to_Sync_Field_Lookup__r.QualifiedApiName, Field_to_Sync_Into__r.QualifiedApiName, Path_Levels_to_Remove__c 
																FROM Automatic_Object_Folder_Sync__mdt 
																WHERE Trigger_Object_Lookup__r.QualifiedApiName = 'Campaign' LIMIT 1];

		// Edit:DS 2023-06-13 - This is commented out because we saw that the folder field is overridden in the sFiles applet
		// fileforcem1__Sharepoint_Object_Settings__mdt opp_sFilesObjMDT = [SELECT fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName 
		// 																FROM fileforcem1__Sharepoint_Object_Settings__mdt
		// 																WHERE DeveloperName = 'Opportunity' LIMIT 1];

		fileforcem1__Sharepoint_Object_Settings__mdt camp_sFilesObjMDT = [SELECT fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName 
																		FROM fileforcem1__Sharepoint_Object_Settings__mdt
																		WHERE DeveloperName = 'Campaign' LIMIT 1];

		// Get record type Ids
		Id oppRT = Schema.SObjectType.Opportunity.getRecordTypeInfosByName().get('Loan').getRecordTypeId();
		Id campRT = Schema.SObjectType.Campaign.getRecordTypeInfosByName().get('Single Source: Grant: Restricted (100%)').getRecordTypeId();

		// 1 opp and 1 camp
		Account acc = TestDataFactory.createDefaultAccount(true);

		Opportunity opp = TestDataFactory.createDefaultOpportunity(acc.Id, false);
		opp.RecordTypeId = oppRT;
		opp.StageName = 'Active';
		// Edit:DS 2023-06-13 - This is commented out because we saw that the folder field is overridden in the sFiles applet
		// opp.put(opp_sFilesObjMDT.fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName, 'foofoo');
		opp.put('Sharepoint_Folder_ID_sFiles__c', 'foofoo');
		insert opp;

		Campaign camp = TestDataFactory.createDefaultCampaign(false);
		camp.RecordTypeId = campRT;
		camp.put(camp_sFilesObjMDT.fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName, 'foofoo');
		camp.Funder__c = acc.Id;
		insert camp;

		Set<Id> oppSet = new Set<Id>{opp.Id};
		Set<Id> campSet = new Set<Id>{camp.Id};

		Test.startTest();
		AccountStampSFilesFolderField_Queueable.processOppAndCampaignAccounts(oppSet, campSet);
		Test.stopTest();

		Id accId = acc.Id;

		// Edit:DS 2023-07-26 - changed to 
		Account stampedAcc = [SELECT Name, SharePoint_Folder_ID_Client_sFiles__c, SharePoint_Folder_ID_Funder_sFiles__c FROM Account WHERE Id = :accId];

		// RECORD TYPE BEING CHANGED AFTER INSERT MAY BE THE CAUSE OF TEST FAILURE
		// Opportunity oppAfterInsert = [SELECT RecordTypeId FROM Opportunity WHERE Id = :opp.Id];
		// Campaign campAfterInsert = [SELECT RecordTypeId FROM Campaign WHERE Id = :camp.Id];
		// System.assertEquals(opp.RecordTypeId, oppAfterInsert.RecordTypeId);
		// System.assertEquals(camp.RecordTypeId, campAfterInsert.RecordTypeId);

		// Both Client and Funder field on Account should be stamped
		System.assertEquals('foobar', stampedAcc.SharePoint_Folder_ID_Client_sFiles__c);
		System.assertEquals('foobar', stampedAcc.SharePoint_Folder_ID_Funder_sFiles__c);
		// Duplicate for debugging test
		// System.assertEquals('foobar', stampedAcc.SharePoint_Folder_ID_Client_sFiles__c);
	}
}