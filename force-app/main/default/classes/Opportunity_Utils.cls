/*===========================================================================
	Author:			Daniel Serban, Upsource Solutions
	Created Date:	2023-05-24
	Called by:		OpportunityTrigger

	Test Run Date:	2023-06-01
	Percentage Covered at test time:	100%
	=========================================================================*/

public with sharing class Opportunity_Utils {
	// Static Boolean that tracks whether stampAccountFolderIdFieldIfNeeded() has run already 
	// (in case trigger fires twice - avoids double processing) It maintains its state throughout the transaction
	static Boolean stampAccountFolderIdField_Queueable_hasRun = false;
	
	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-05-24
		Description:	This finds any Opportunities whose Sharepoint Folder Id field
						was just set and it sets the appropriate Sharepoint Folder Id 
						field on the Account if that is null.
	
		Called by:		OpportunityTrigger
		Testing Method:	testStampingAccountFolder
		Test Run Date:	2023-06-01
		Percentage Covered at test time:	100%

		Gage Payne : Upsource Solutions : 2023-07-03 - Updated all the logic to use
		the single metadata record that points to a formula field instead of a different
		metadata record for each record type
		=========================================================================*/
	
    public static void stampAccountFolderIdFieldIfNeeded(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
		// Avoid running this again if trigger fires twice in same transaction
		if (stampAccountFolderIdField_Queueable_hasRun == false) {
			// Accounts that need checking
			Set<Id> accsToCheck = new Set<Id>();
			// Opportunities with Accounts that need checking
			List<Opportunity> oppsWithAccsToCheck = new List<Opportunity>();

			// Opportunities with Accounts whose sFiles Sharepoint folder field needs stamping
			Set<Id> oppsWithAccsToStamp = new Set<Id>();

			// Map from Account Id to a list of Account sFiles Sharepoint folder fields that need stamping
			Map<Id, List<String>> mapOfAccsToStampFields = new Map<Id, List<String>>();

			// sFiles Opp MDT rec // Edit:DS 2023-06-13 - This is commented out because we saw that the folder field is overridden in the sFiles applet
			// fileforcem1__Sharepoint_Object_Settings__mdt sFilesOppMDT = [SELECT fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName 
			// 															FROM fileforcem1__Sharepoint_Object_Settings__mdt
			// 															WHERE DeveloperName = 'Opportunity' LIMIT 1];

			// Edit:DS 2023-06-13 - This is commented out because we saw that the folder field is overridden in the sFiles applet
			// String oppFolderField = sFilesOppMDT?.fileforcem1__Sharepoint_Folder_Id_Field__r?.QualifiedApiName;

			// Field on Opp stamped by sFiles with folder id
			String oppFolderField = 'Sharepoint_Folder_ID_sFiles__c';

			// Get metadata that maps from Opp record type to sFiles folder id field on Account
			Automatic_Object_Folder_Sync__mdt folderSyncMDT = [SELECT Field_to_Sync_Into__r.QualifiedApiName, Object_to_Sync_Field_Lookup__r.QualifiedApiName
			FROM Automatic_Object_Folder_Sync__mdt 
			WHERE Trigger_Object_Lookup__r.QualifiedApiName = 'Opportunity' ];

			// If field name retrieved
			if (oppFolderField != null) {
				Set<String> accountFieldsToQuery = new Set<String>();

				// Check all updated opps
				for (Opportunity newOpp : newOpps) {
					// Get old opportunity
					Opportunity oldOpp = oldOppMap.get(newOpp.Id);

					// Check if new opp field is set and that it previously was null
					if (newOpp.get(oppFolderField) != null) {
						if (oldOpp.get(oppFolderField) == null) {
							accsToCheck.add((Id)newOpp.get(folderSyncMDT.Object_to_Sync_Field_Lookup__r.QualifiedApiName));
							oppsWithAccsToCheck.add(newOpp);
							accountFieldsToQuery.add((String)newOpp.get(folderSyncMDT.Field_to_Sync_Into__r.QualifiedApiName));
						}
					}
				}

				// Check related Accounts if any need to be checked
				if (accsToCheck.size() > 0) {
					
					// Map of Record Type Id to Record Type
					Map<Id, RecordTypeInfo> oppRecTypeMap = Schema.Opportunity.getSObjectType().getDescribe().getRecordTypeInfosById();

					String queryStr = 'SELECT Id, ' + String.join(new List<String>(accountFieldsToQuery), ', ') + ' FROM Account WHERE Id IN :accsToCheck';
					List<Account> queryResults = (List<Account>) Database.query(queryStr);

					// Map of Account records from the query result
					Map<Id, Account> accMap = new Map<Id, Account>();

					// Fill map
					for (Account acc : queryResults) {
						accMap.put(acc.Id, acc);
					}

					// There are entries in map from record type to field name and Accounts were returned in the query
					if ((accMap.size() > 0)) {
						// Go through list of Opps with Accounts to check and check the Accounts
						for (Opportunity opp : oppsWithAccsToCheck) {
							// Check if account folder field needs stamping (is null)
							// Get Account stamp field for Opp type
							String stampField = (String)opp.get(folderSyncMDT.Field_to_Sync_Into__r.QualifiedApiName);

							// If stamp field was found in map
							if (stampField != null) {
								// If folder stamp field is null on Opp's Account and needs stamping
								if (accMap.get((Id)opp.get(folderSyncMDT.Object_to_Sync_Field_Lookup__r.QualifiedApiName)).get(stampField) == null) {
									// Get list of stamp fields for opp's account
									List<String> accStampFieldList = mapOfAccsToStampFields.get(opp.AccountId);

									// If Account Id is not in map yet
									if (accStampFieldList == null) {
										accStampFieldList = new List<String>();

										// Add Account field to stamp to the list - RecordTypeId on Opp is used to map to RecordType DeveloperName which is mapped to stamp field
										accStampFieldList.add(stampField);

										// Map Account Id to stamp fields list just created
										mapOfAccsToStampFields.put(opp.AccountId, accStampFieldList);

										// Add Opp Id to set of Opps
										oppsWithAccsToStamp.add(opp.Id);
									// Account Id is already in map
									} else {
										// If stamp field is not already in list
										if (accStampFieldList.contains(stampField) == false) {
											// Add stamp field to the list
											accStampFieldList.add(stampField);
											// Update map -- may be unnecessary if array is by reference
											mapOfAccsToStampFields.put(opp.AccountId, accStampFieldList);
											// Add Opp Id to set of Opps
											oppsWithAccsToStamp.add(opp.Id);
										}
									}
								}
							}
						}

						// If there are Opps with Accounts to stamp
						if (oppsWithAccsToStamp.size() > 0) {
							// Call queueable
							AccountStampSFilesFolderField_Queueable.processOppAndCampaignAccounts(oppsWithAccsToStamp, null);
							// Update flag to indicate run
							stampAccountFolderIdField_Queueable_hasRun = true;
						}
					}
				}
			}
		}
	}
}