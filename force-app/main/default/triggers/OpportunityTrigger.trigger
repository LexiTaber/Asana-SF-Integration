trigger OpportunityTrigger on Opportunity (after insert, after undelete, before delete, after update) {
  set<ID>     cIds  = new set<ID>();
  List<String>   apIds  = new List<String>();
  List<ActionPlan__c>  deletePermantently_apIds= new List<ActionPlan__c>();
  // Edit:DS 2023-05-24 - Organized trigger a little better
  if (Trigger.isBefore) {
    if ( Trigger.isDelete ){
      //Delete related action plans
      for( Opportunity o : trigger.old ){
        cIds.add( o.Id );
      }

      /* GET Action Plans to delete from recycle bin */
      deletePermantently_apIds = [ select Id, Name , LastModifiedDate from ActionPlan__c where Opportunity__c in : cIds and isDeleted = true ALL ROWS ];

      if ( deletePermantently_apIds.size() >0 ){
        Database.emptyRecycleBin(deletePermantently_apIds);
      }

      List<ActionPlan__c> apList =  [ select Id from ActionPlan__c where Opportunity__c in : cIds ];
      for( ActionPlan__c ap : [ select Id from ActionPlan__c where Opportunity__c in : cIds ] ){
        apIds.add( ap.Id );
      }
      if ( apIds.size() >0 ){
        ActionPlansBatchDelete aPBatch = new ActionPlansBatchDelete(apIds, Userinfo.getUserId());
        Database.ExecuteBatch( aPBatch );
      }
    }
  } else if (Trigger.isAfter) {
    if ( Trigger.isUndelete ){
      //Undelete related action plans
      for( Opportunity o : trigger.new ){
        cIds.add( o.Id );
      }
      list <ActionPlan__c> aPs = [ select Id from ActionPlan__c where Opportunity__c in : cIds ALL ROWS ];

      try{
        if(ActionPlanObjectTriggerTest.isTest){
          //throw dmlException
          insert new Contact();
        }
        //undelete aPs;
        Database.undelete( aPs,false);
      } catch ( Dmlexception e ){
        for (Opportunity o: trigger.new){
          o.addError('You can not undelete an action plan whose related object is deleted.');
        }
      }
    } else if (Trigger.isUpdate) {
      // Edit:DS 2023-05-24 - If Opportunity's Account Sharepoint folder field is not set, it gets set
      Opportunity_Utils.stampAccountFolderIdFieldIfNeeded(Trigger.new, Trigger.oldMap);

      // 2026 - Asana task create/update on loan close
      OpportunityAsanaSyncHandler.handleAfter(Trigger.new, Trigger.oldMap);
    } else if (Trigger.isInsert) {
      // 2026 - Asana task create when Opp inserted already at Closed
      OpportunityAsanaSyncHandler.handleAfter(Trigger.new, null);
    }
  }
}
