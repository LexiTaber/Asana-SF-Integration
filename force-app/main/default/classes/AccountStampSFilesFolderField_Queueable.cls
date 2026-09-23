/*===========================================================================
	Author:			Daniel Serban, Upsource Solutions
	Created Date:	2023-05-26
	Description:	This takes Opportunity and Campaign Ids, uses the sFiles API to get their 
					associated folder paths in Sharepoint, and sets the Id of the Sharepoint 
					folder for their respective Accounts

	Test Run Date:	2023-06-01
	Percentage Covered at test time:	97%
	=========================================================================*/

public with sharing class AccountStampSFilesFolderField_Queueable implements Queueable, Database.AllowsCallouts {
	// Opportunities whose Accounts need their sFiles Sharepoint folder field stamped
	private Set<Id> oppsWithAccsToProcess;
	// Campaigns whose Accounts need their sFiles Sharepoint folder field stamped
	private Set<Id> campsWithAccsToProcess;

	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-05-26
		Description:	This can be called by other code and handles instantiating and enqueueing the class
	
		Called by:		Opportunity_Utils.stampAccountFolderIdFieldIfNeeded
		Testing Method:	testOppAndCampaign
		Test Run Date:	2023-06-01
		Percentage Covered at test time:	97%
		=========================================================================*/
	
	public static Id processOppAndCampaignAccounts(Set<Id> SetOfOppsWithAccsToProcess, Set<Id> SetOfCampsWithAccsToProcess) {
		AccountStampSFilesFolderField_Queueable queueable = new AccountStampSFilesFolderField_Queueable(SetOfOppsWithAccsToProcess, SetOfCampsWithAccsToProcess);
		return System.enqueueJob(queueable);
	}

	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-05-26
		Description:	Constructor that takes a set of Opportunity Ids and Campaign Ids as args
	
		Called by:		processOppAndCampaignAccounts
		Testing Method:	testOppAndCampaign
		Test Run Date:	2023-06-01
		Percentage Covered at test time:	97%
		=========================================================================*/
	
	public AccountStampSFilesFolderField_Queueable(Set<Id> SetOfOppsWithAccsToProcess, Set<Id> SetOfCampsWithAccsToProcess) {
		// Set variables
		oppsWithAccsToProcess = SetOfOppsWithAccsToProcess;
		campsWithAccsToProcess = SetOfCampsWithAccsToProcess;
	}
	
	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-05-26
		Description:	This takes Opportunity and Campaign Ids and stamps the appropriate 
						Account folder Id from Sharepoint onto the related Account object.
						It processes a max of 25 Opportunities and 25 Campaigns per run. 
						Remaining Objects will cause another job to be enqueued/chained after this one
	
		Testing Method:	testOppAndCampaign
		Test Run Date:	2023-06-01
		Percentage Covered at test time:	97%
		=========================================================================*/
	
    public void execute(QueueableContext context) {
		// Size of Opportunity set passed in
		Integer oppSetSize = (oppsWithAccsToProcess == null ? 0 : oppsWithAccsToProcess.size());
		// Stores number of Opps to process in this queued job (max of 25)
		// The number is 25 or the size of the list, whichever is less.
		Integer numOpps = (oppSetSize >= 25 ? 25 : oppSetSize);
		// Size of Campaign set passed in
		Integer campaignSetSize = (campsWithAccsToProcess == null ? 0 : campsWithAccsToProcess.size());
		// Stores number of Campaigns to process in this queued job (max of 25)
		// The number is 25 or the size of the list, whichever is less.
		Integer numCampaigns = (campaignSetSize >= 25 ? 25 : campaignSetSize);

		// Map of Account Id to Account object that will be updated
		Map<Id, Account> IdToAccMap = new Map<Id, Account>();

		// sFiles Client API
		// get auth info from the Settings MDT
		fileforcem1__SharePoint_Settings__mdt orgSettings = [SELECT fileforcem1__Named_Credential__c,fileforcem1__Document_Library_Id__c,fileforcem1__Site_Id__c 
															FROM fileforcem1__SharePoint_Settings__mdt 
															WHERE Developername = 'Default' limit 1];

		fileforcem1.ClientApi apiClient = new fileforcem1.ClientApi();
		apiClient.namedCredentialName = orgSettings.fileforcem1__Named_Credential__c;

		// Process Opportunities
		if (oppSetSize > 0) {
			processSObjectRecords('Opportunity', oppsWithAccsToProcess, numOpps, IdToAccMap, apiClient);
		}

		// Process Campaigns
		if (campaignSetSize > 0) {
			processSObjectRecords('Campaign', campsWithAccsToProcess, numCampaigns, IdToAccMap, apiClient);
		}

		// Update the Accounts
		if (IdToAccMap.size() > 0) {
			update IdToAccMap.values();
		}

		// Determine if Opps or Campaigns were supposed to be processed and what the new sizes of the sets are
		// numOpps and numCampaigns are how many of those were supposed to be processed and removed from the sets this job
		// The condition is to make sure the set is not null, which is checked for at the top when numOpps and numCampaigns are set
		Integer newOppSetSize = (numOpps > 0 ? oppsWithAccsToProcess.size() : oppSetSize);
		Integer newCampaignSetSize = (numCampaigns > 0 ? campsWithAccsToProcess.size() : campaignSetSize);

		// Check if there is still more to process
		if ((newOppSetSize > 0) || (newCampaignSetSize > 0)) {
			// This protects against infinite job enqueueing by making sure the set sizes go down every time
			if ((newOppSetSize < oppSetSize) || (newCampaignSetSize < campaignSetSize)) {
				// enqueue another job to process what's left
				processOppAndCampaignAccounts(oppsWithAccsToProcess, campsWithAccsToProcess);
			// Something is wrong and the error should be reported
			} else {
				System.debug('ERROR: AccountStampSFilesFolderField_Queueable is not decreasing the sizes of the input Id sets and is trying to enqueue infinitely. Something is not being processed correctly.');
			}
		}
    }

	/*===========================================================================
		Author:			Daniel Serban, Upsource Solutions
		Created Date:	2023-05-31
		Description:	Generic code that handles sFiles callouts and Account field 
						stamping for Opportunities and Campaigns
	
		Called by:		execute
		Testing Method:	testOppAndCampaign
		Test Run Date:	2023-06-01
		Percentage Covered at test time:	97%
		=========================================================================*/
	
	private void processSObjectRecords(String objectType, Set<Id> objWithAccsToProcess, Integer numObj, Map<Id, Account> IdToAccMap, fileforcem1.ClientApi apiClient) {
		// Convert set to list
		List<Id> tempList = new List<Id>(objWithAccsToProcess);

		// List of obj being worked with in this specific job
		List<Id> objWorkingList = new List<Id>();

		// Remove 25 or less
		for (Integer i = 0; i < numObj; i++) {
			// Always gets the first element because we remove it from the list immediately after
			Id objId = tempList[0];
			objWorkingList.add(objId);
			// Remove from tempList (first element)
			tempList.remove(0);
			// Remove from main set
			objWithAccsToProcess.remove(objId);
		}

		// Query metadata for Obj rec type to Account field
		Automatic_Object_Folder_Sync__mdt folderSyncMDT = [SELECT Object_to_Sync_Field_Lookup__r.QualifiedApiName, Field_to_Sync_Into__r.QualifiedApiName, Path_Levels_to_Remove__c 
																	FROM Automatic_Object_Folder_Sync__mdt 
																	WHERE Trigger_Object_Lookup__r.QualifiedApiName = :objectType LIMIT 1];

		// Query metadata for sFiles obj field
		fileforcem1__Sharepoint_Object_Settings__mdt sFilesObjMDT = [SELECT fileforcem1__Sharepoint_Folder_Id_Field__r.QualifiedApiName 
																		FROM fileforcem1__Sharepoint_Object_Settings__mdt
																		WHERE DeveloperName = :objectType LIMIT 1];

		// Field on obj stamped by sFiles with folder id
		String objFolderField;

		if (objectType == 'Opportunity') {
			// Edit:DS 2023-06-13 - This has to be hard-coded because we saw that the folder field is overridden in the sFiles applet
			objFolderField = 'Sharepoint_Folder_ID_sFiles__c';	
		} else if (objectType == 'Campaign') {
			objFolderField = sFilesObjMDT?.fileforcem1__Sharepoint_Folder_Id_Field__r?.QualifiedApiName;	
		}

		// Map of Record Type Id to Record Type
		Map<Id, RecordTypeInfo> objRecTypeMap;
		
		if (objectType == 'Opportunity') {
			objRecTypeMap = Schema.Opportunity.getSObjectType().getDescribe().getRecordTypeInfosById();	
		} else if (objectType == 'Campaign') {
			objRecTypeMap = Schema.Campaign.getSObjectType().getDescribe().getRecordTypeInfosById();	
		}
																
		// Maps have entries and field to query was retrieved
		if ((objRecTypeMap != null) && (objFolderField != null)) {
			// Query the objects in the working list
			String objQueryStr = '';
			List<SObject> objList = new List<SObject>();

			if (objectType == 'Opportunity') {
				objQueryStr = 'SELECT Id, AccountId, RecordTypeId, ' + objFolderField + ', ' + folderSyncMDT.Field_to_Sync_Into__r.QualifiedApiName + ', Site_ID_sFiles__c, Document_Library_Id_Sfiles__c FROM Opportunity WHERE Id IN :objWorkingList';
				objList = Database.query(objQueryStr);
			} else if (objectType == 'Campaign') {
				objQueryStr = 'SELECT Id, Funder__c, RecordTypeId, ' + objFolderField + ', ' + folderSyncMDT.Field_to_Sync_Into__r.QualifiedApiName + ', Site_ID_Sfiles__c, Document_Library_Id_Sfiles__c FROM Campaign WHERE Id IN :objWorkingList';
				objList = Database.query(objQueryStr);
			}

			// Loop through the working list and callout with sFiles to get Account folder Id
			for (SObject obj : objList) {
				// Set parameters for sFiles client API
				if (objectType == 'Opportunity') {
					apiClient.sharepointSiteId = (String) obj.get('Site_ID_sFiles__c');
					apiClient.documentLibraryId = (String) obj.get('Document_Library_Id_Sfiles__c');
				} else if (objectType == 'Campaign') {
					apiClient.sharepointSiteId = (String) obj.get('Site_ID_Sfiles__c');
					apiClient.documentLibraryId = (String) obj.get('Document_Library_Id_Sfiles__c');
				}

				// Get obj folder Id
				String objFolderId = (String) obj.get(objFolderField);

				// This is to make sure exceptions from sFiles callouts are handled
				try {
					// Make callout to sFiles API to get path
					String urlPath;
					
					// This is checking to make sure this is not being run inside a test class
					// The callout to sFiles and SharePoint cannot be made in a test, so a fake result is assigned if this is running in a test
					// The sFiles callout must remain inline with the if condition because it cannot be covered in a test
					if (!Test.isRunningTest()) { urlPath = apiClient.getItemById(objFolderId)?.Url; } 
					else { 
						// Fake callout result for tests
						urlPath = '/sFilesTest/Test/T/Test%20Acc/Opps/my%20opp/asdf/asdf/asdf/asdf/asdf'; 
					}

					if (urlPath != null) {
						String path = EncodingUtil.urlDecode(urlPath, 'UTF-8');										
						// Isolate Account folder
						List<String> pathFolders = path.split('/');
						String accPath = '';
						// Zero unless target folder to stamp is nested as a sub-account, not the main account
						Integer additionalLevelsToInclude = (Integer) folderSyncMDT.Path_Levels_to_Remove__c;
						// Make sure not null - replace null with zero
						additionalLevelsToInclude = (additionalLevelsToInclude == null ? 0 : additionalLevelsToInclude);
						
						// Reconstruct path to Account
						for (Integer i = 0; i < (1 + additionalLevelsToInclude); i++) {
							// Skips the first three folders from the UrlPath - also index 0 is ''
							accPath += ('/' + pathFolders[4 + i]);
						}
												
						// Get Id of Account folder
						String accFolderId;

						// This is checking to make sure this is not being run inside a test class
						// The callout to sFiles and SharePoint cannot be made in a test, so a fake result is assigned if this is running in a test
						// The sFiles callout must remain inline with the if condition because it cannot be covered in a test
						if (!Test.isRunningTest()) { accFolderId = apiClient.getItemByPath(accPath)?.Id; } 
						else { 
							// Fake callout result for tests
							accFolderId = 'foobar'; 
						}

						if (accFolderId != null) {
							Id objAccountId;
							
							if (objectType == 'Opportunity') {
								objAccountId = (Id) obj.get('AccountId');
							} else if (objectType == 'Campaign') {
								objAccountId = (Id) obj.get('Funder__c');
							}
							
							if (objAccountId != null) {
								Account accToStamp = IdToAccMap.get(objAccountId);

								// If Account Id was not already in map, create a new Account object with that same Id
								if (accToStamp == null) {
									accToStamp = new Account(Id=objAccountId);
								}

								// Get Account field to stamp
								String fieldToStamp = (String)obj.get(folderSyncMDT.Field_to_Sync_Into__r?.QualifiedApiName);

								if (fieldToStamp != null) {
									// Stamp Id on Account field
									accToStamp.put(fieldToStamp, accFolderId);

									// Assign it back to the map
									IdToAccMap.put(objAccountId, accToStamp);
								}
							}
						}
					}
				} catch (Exception e) {
					System.debug('ERROR: AccountStampSFilesFolderField_Queueable: ' + objectType + ' ' + ((String) obj.get('Name')) + ' was not processed correctly. (Id: ' + ((Id) obj.get('Id')) + ') ErrorMsg: ' + e.getMessage());
				}
			}
		}
	}
}