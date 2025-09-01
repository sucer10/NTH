/**@class DynamicAgent
 * @author Ayushi patel
 * @created 2025-07-15
 * @description
 * - Construct class to get the details of object to agent
 * - Construct class to save suggestions which is provided by agentforce
 */
 public without sharing class DynamicAgent {
    private static Map<String, String> prefixToObjectMap = null;
    @InvocableMethod(label='GetRecordInfo' description='Returns field values for a record when provided with its ID')
    /**
     * @description Fetch the object details based on recordIds
     * @param recordIds List of record IDs
     * @return List of response wrappers
     */
    public static List<ResponseWrapper> getRecordInfo(List<String> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) {
            throw new AuraHandledException('recordId cannot be null or empty');
        }

        if (prefixToObjectMap == null) {
            initializePrefixCache();
        }

        String recordId = recordIds[0];
        if (recordId == null || recordId.length() < 3) {
            throw new AuraHandledException('Invalid record ID format');
        }

        String objPrefix = recordId.substring(0, 3);
        String objectApiName = prefixToObjectMap.get(objPrefix);
        Schema.DescribeSObjectResult describe = Schema.getGlobalDescribe()
            .get(objectApiName)
            .getDescribe();

        String objectLabel = describe.getLabel();
        if (objectApiName == null) {
            throw new AuraHandledException('Unable to determine object API name from recordId');
        }

        // Query the record
        String query = buildDynamicQuery(objectApiName);
        List<SObject> records = Database.query(query + ' WHERE Id = :recordId LIMIT 1');
        if (records.isEmpty()) {
            throw new AuraHandledException('No record found with ID: ' + recordId);
        }

        SObject record = records[0];

        // Get Name field or fallback to first string field
        String recordName = '';
        Map<String, Schema.SObjectField> fields = Schema.getGlobalDescribe()
            .get(objectApiName)
            .getDescribe()
            .fields.getMap();

        if (fields.containsKey('Name') && record.get('Name') != null) {
            recordName = String.valueOf(record.get('Name'));
        } else {
            for (String fieldApi : fields.keySet()) {
                Schema.DescribeFieldResult fieldDescribe = fields.get(fieldApi).getDescribe();
                if (fieldDescribe.getType() == Schema.DisplayType.String && record.get(fieldApi) != null) {
                    recordName = String.valueOf(record.get(fieldApi));
                    break;
                }
            }
        }

        ResponseWrapper response = new ResponseWrapper();
        response.objectApiName = objectApiName;
        response.objectLabel = objectLabel;
        response.recordId = recordId;
        response.recordName = recordName;
        response.fieldValues = record;

        return new List<ResponseWrapper> { response };
            }

    private static void initializePrefixCache() {
        prefixToObjectMap = new Map<String, String>();
        for (Schema.SObjectType objType : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult objDescribe = objType.getDescribe();
            String currentPrefix = objDescribe.getKeyPrefix();
            if (currentPrefix != null) {
                prefixToObjectMap.put(currentPrefix, objDescribe.getName());
            }
        }
    }

    private static String buildDynamicQuery(String objectApiName) {
        Map<String, Schema.SObjectField> fields =
            Schema.getGlobalDescribe().get(objectApiName).getDescribe().fields.getMap();

        List<String> fieldNames = new List<String>(fields.keySet());
        return 'SELECT ' + String.join(fieldNames, ', ') + ' FROM ' + objectApiName;
    }

    // Saves field suggestions for one or more records received from the AI agent on the UI.
    //This method supports both single-record and bulk updates, depending on the input.

    @AuraEnabled
    public static SaveResultWrapper saveMultipleRecordFields(Map<String, Map<String, Object>> recordFieldValues) {
        SaveResultWrapper result = new SaveResultWrapper();
        result.fieldErrors = new Map<String, Map<String, String>>();
        result.hasErrors = false;

        if (recordFieldValues == null || recordFieldValues.isEmpty()) {
            throw new AuraHandledException('No records provided for update.');
        }

        // Check if we're dealing with a large number of records
        if (recordFieldValues.size() > 100) {
            throw new AuraHandledException('Too many records provided for update. Maximum allowed is 100 records.');
        }

        Map<String, SObject> recordsToUpdate = new Map<String, SObject>();
        Map<String, List<String>> updatedFieldsPerRecord = new Map<String, List<String>>();
        Map<String, String> objectTypePerRecord = new Map<String, String>();

        // Group field errors by recordId
        for (String recordId : recordFieldValues.keySet()) {
            Map<String, Object> fields = recordFieldValues.get(recordId);
            if (String.isBlank(recordId) || fields == null || fields.isEmpty()){
                continue;
            }

            Id recordIdObj = (Id) recordId;
            String objectApiName = recordIdObj.getSObjectType().getDescribe().getName();
            objectTypePerRecord.put(recordId, objectApiName);
            SObject record = (SObject) Type.forName('Schema.' + objectApiName).newInstance();
            record.put('Id', recordId);

            Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe().get(objectApiName).getDescribe().fields.getMap();
            List<String> updatedFields = new List<String>();
            Map<String, String> fieldErrors = new Map<String, String>();

            for (String fieldApi : fields.keySet()) {
                try {
                    if (!fieldMap.containsKey(fieldApi)){
                        continue;
                    }

                    Object value = fields.get(fieldApi);
                    if (value == null || String.valueOf(value).trim() == ''){
                        continue;
                    }
                    Schema.DisplayType fieldType = fieldMap.get(fieldApi).getDescribe().getType();
                    Object convertedValue = convertValueByType(value, fieldType);

                    if ((fieldType == Schema.DisplayType.String || fieldType == Schema.DisplayType.TextArea) && convertedValue != null) {
                        Integer maxLength = fieldMap.get(fieldApi).getDescribe().getLength();
                        if (String.valueOf(convertedValue).length() > maxLength) {
                            fieldErrors.put(fieldApi, 'Input Value is too long (max ' + maxLength + ' characters)');
                            continue;
                        }
                    }

                    if ((fieldType == Schema.DisplayType.Currency || fieldType == Schema.DisplayType.Double) && convertedValue != null) {
                        String strVal = String.valueOf(convertedValue).trim();
                        Schema.DescribeFieldResult d = fieldMap.get(fieldApi).getDescribe();

                        try {
                            Decimal dVal = Decimal.valueOf(strVal); // Will throw if invalid

                            Integer digitsBefore = strVal.contains('.') ? strVal.split('\\.')[0].replace('-', '').length() : strVal.replace('-', '').length();
                            Integer digitsAfter = strVal.contains('.') ? strVal.split('\\.')[1].length() : 0;

                            if (digitsBefore + digitsAfter > d.getPrecision()) {
                                fieldErrors.put(fieldApi, 'Value exceeds : maximum ' + d.getPrecision() + ' digits allowed including decimals');

                                continue;
                            }
                        } catch (Exception e) {
                            fieldErrors.put(fieldApi, 'Invalid number format.');
                            continue;
                        }
                    }
                    if (fieldType == Schema.DisplayType.Email && convertedValue != null) {
                        if (!Pattern.matches('^[\\w.%+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$', String.valueOf(convertedValue))) {
                            fieldErrors.put(fieldApi, 'Invalid email format.');
                            continue;
                        }
                    }

                    if (fieldType == Schema.DisplayType.Phone && convertedValue != null) {
                        String phoneDigits = String.valueOf(convertedValue).replaceAll('[^\\d]', '');

                        if (!Pattern.matches('^[\\d\\-\\+()\\s]+$', String.valueOf(convertedValue))) {
                            fieldErrors.put(fieldApi, 'Invalid phone number format.');
                            continue;
                        }
                        if (phoneDigits.length() > 10 || phoneDigits.length() < 10) {
                            fieldErrors.put(fieldApi, 'Phone number must be exactly 10 digits');
                            continue;
                        }
                    }

                    if (fieldType == Schema.DisplayType.Percent && convertedValue != null) {
                        Decimal percentValue;
                        try {
                            percentValue = Decimal.valueOf(String.valueOf(convertedValue));
                        } catch (Exception e) {
                            fieldErrors.put(fieldApi, 'Invalid percent value.');
                            continue;
                        }
                        if (percentValue < 0 || percentValue > 100) {
                            fieldErrors.put(fieldApi, 'Percent must be between 0 and 100');
                            continue;
                        }
                    }
                   if (fieldApi != null &&
                        (fieldApi.toLowerCase().contains('website') || fieldType == Schema.DisplayType.Url)) {

                        String urlStr = convertedValue == null ? '' : String.valueOf(convertedValue).trim();

                        // Securely get object describe
                        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
                        if (!globalDescribe.containsKey(objectApiName)) {
                            continue; // Invalid object name, skip
                        }
                        Schema.DescribeSObjectResult objDescribe = globalDescribe.get(objectApiName).getDescribe();

                        // Securely get field describe
                        Map<String, Schema.SObjectField> fieldsMap = objDescribe.fields.getMap();
                        if (!fieldsMap.containsKey(fieldApi)) {
                            continue; // Invalid field name, skip
                        }
                        Integer maxUrlLength = fieldsMap.get(fieldApi).getDescribe().getLength();

                        // Check blank or too long
                        if (String.isBlank(urlStr) || urlStr.length() > maxUrlLength) {
                            fieldErrors.put(fieldApi, 'URL is too long. Max length: ' + maxUrlLength);
                            continue;
                        }

                        // Allow multi-subdomain URLs like Salesforce Lightning domains
                        String regex = '^(https?://)?([\\w.-]+\\.)+[a-zA-Z]{2,}(:[0-9]+)?(/.*)?$';
                        if (!Pattern.matches(regex, urlStr)) {
                            fieldErrors.put(fieldApi, 'Invalid URL format.');
                            continue;
                        }
                    }

                    record.put(fieldApi, convertedValue);
                    updatedFields.add(fieldApi);

                } catch (Exception e) {
                    fieldErrors.put(fieldApi, 'Invalid value: ' + e.getMessage());
                }
            }

            if (!fieldErrors.isEmpty()) {
                result.fieldErrors.put(recordId, fieldErrors);
                //throw new AuraHandledException(JSON.serialize(fieldErrors));
            }

            if (!updatedFields.isEmpty()) {
                recordsToUpdate.put(recordId, record);
                updatedFieldsPerRecord.put(recordId, updatedFields);
            }
        }

        // Bulk DML with error mapping
        if (!recordsToUpdate.isEmpty()) {
            try {
                update recordsToUpdate.values();
            } catch (DmlException dmlEx) {
                for (Integer i = 0; i < dmlEx.getNumDml(); i++) {
                    String msg = dmlEx.getDmlMessage(i);
                    Id dmlRecordId = (Id) dmlEx.getDmlId(i);
                    String recId = String.valueOf(dmlRecordId);
                    String fieldMatch = 'Unknown';
                    String fieldType = 'UNKNOWN';
                    String finalMsg = msg;

                    // Try to extract field from [FieldName]
                    Matcher m = Pattern.compile('\\[([a-zA-Z0-9_]+)\\]').matcher(msg);
                    if (m.find()) {
                        fieldMatch = m.group(1);
                    }

                    // Handle duplicate errors specially
                    if (msg != null && msg.containsIgnoreCase('duplicate value')) {
                        List<String> fields = new List<String>();
                        for (String part : msg.split(',')) {
                            part = part.trim();
                            Integer idx = part.indexOf(' duplicates value');
                            if (idx > 0) {
                                String apiName = part.substring(0, idx).trim();
                                String label = apiName.replaceAll('__c', '').replaceAll('_', ' ').trim();
                                fields.add(label);
                            }
                        }

                        finalMsg = fields.isEmpty()
                            ? 'Duplicate value error. Some fields must be unique.'
                            : 'The field' + (fields.size() > 1 ? 's ' : ' ') +
                                String.join(fields, ' and ') +
                                ' must be unique. Duplicate values were found.';

                        fieldMatch = 'Unknown'; // To force top-level toast
                    } else {
                        // Try to get field type info if available
                        if (objectTypePerRecord.containsKey(recId)) {
                            Map<String, Schema.SObjectField> fMap = Schema.getGlobalDescribe()
                                .get(objectTypePerRecord.get(recId)).getDescribe().fields.getMap();
                            if (fMap.containsKey(fieldMatch)) {
                                fieldType = fMap.get(fieldMatch).getDescribe().getType().name();
                            }
                        }

                        Object val = recordFieldValues.get(recId).get(fieldMatch);
                        // finalMsg = 'Invalid "' + String.valueOf(val) + '" for ' + fieldType + ': ' + msg;
                        finalMsg = msg;
                    }

                    // Populate error map
                    if (!result.fieldErrors.containsKey(recId)) {
                        result.fieldErrors.put(recId, new Map<String, String>());
                    }
                    result.fieldErrors.get(recId).put(fieldMatch, finalMsg);
                }
            }
        }

        // Remove updated fields from payloads only if record had no errors
        Map<Id, List<String>> cleanUpdatedMap = new Map<Id, List<String>>();
        for (String recordId : updatedFieldsPerRecord.keySet()) {
            if (!result.fieldErrors.containsKey(recordId)) {
                cleanUpdatedMap.put((Id) recordId, updatedFieldsPerRecord.get(recordId));
            }
        }

        if (!cleanUpdatedMap.isEmpty()) {
            Set<String> objectNames = new Set<String>(objectTypePerRecord.values());
            for (String obj : objectNames) {
                List<Object_Tracker__c> trackers = [
                    SELECT Id FROM Object_Tracker__c
                    WHERE Name = :obj
                    ORDER BY CreatedDate DESC LIMIT 1
                ];
                if (!trackers.isEmpty()) {
                    removeUpdatedFieldsFromPayloadBatch(trackers[0].Id, cleanUpdatedMap);
                    // Update user validation counts after successful updates
                    updateUserValidationCounts(trackers[0].Id, cleanUpdatedMap);
                }
            }
        }

        result.hasErrors = !result.fieldErrors.isEmpty();
        return result;
    }

    /**
     * @description Update user validation counts in Object_Tracker__c.User_Record_Summary__c
     * after successful record updates. This method counts records that had missing fields
     * and were successfully updated, checking if they still have missing fields after the update.
     * @param trackerId The Object_Tracker__c record ID
     * @param updatedFieldsByRecordId Map of record IDs to list of updated fields
     */
    public static void updateUserValidationCounts(Id trackerId, Map<Id, List<String>> updatedFieldsByRecordId) {
        if (trackerId == null || updatedFieldsByRecordId == null || updatedFieldsByRecordId.isEmpty()) {
            return;
        }

        try {
            // Get the Object_Tracker__c record with current User_Record_Summary__c
            List<Object_Tracker__c> trackers = [
                SELECT Id, User_Record_Summary__c 
                FROM Object_Tracker__c 
                WHERE Id = :trackerId 
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];

            if (trackers.isEmpty() || String.isBlank(trackers[0].User_Record_Summary__c)) {
                return;
            }

            Object_Tracker__c tracker = trackers[0];
            
            // Parse the current user validation JSON
            Map<String, Object> userValidationMap;
            try {
                userValidationMap = (Map<String, Object>) JSON.deserializeUntyped(tracker.User_Record_Summary__c);
            } catch (Exception e) {
                System.debug('Error parsing User_Record_Summary__c JSON: ' + e.getMessage());
                return;
            }

            // Get owner information for the updated records
            Set<Id> recordIds = updatedFieldsByRecordId.keySet();
            Map<Id, Id> recordToOwnerMap = getRecordOwners(recordIds);

            // Count how many records were completely resolved by checking payload
            Map<Id, Integer> userToResolvedRecordsCount = getRecordsResolvedAfterUpdate(trackerId, updatedFieldsByRecordId, recordToOwnerMap);

            // Update the user validation counts
            Boolean hasChanges = false;
            for (Id userId : userToResolvedRecordsCount.keySet()) {
                String userIdStr = String.valueOf(userId);
                if (userValidationMap.containsKey(userIdStr)) {
                    String currentValue = String.valueOf(userValidationMap.get(userIdStr));
                    if (currentValue.contains('/')) {
                        String[] parts = currentValue.split('/');
                        if (parts.size() == 2) {
                            try {
                                Integer currentMissing = Integer.valueOf(parts[0]);
                                Integer totalRecords = Integer.valueOf(parts[1]);
                                Integer resolvedRecords = userToResolvedRecordsCount.get(userId);
                                
                                // Decrease missing count by the number of records that were completely resolved
                                Integer newMissing = Math.max(0, currentMissing - resolvedRecords);
                                
                                String newValue = newMissing + '/' + totalRecords;
                                userValidationMap.put(userIdStr, newValue);
                                hasChanges = true;
                                
                                System.debug('Updated user validation for ' + userIdStr + ': ' + currentValue + ' -> ' + newValue + ' (Resolved ' + resolvedRecords + ' records completely)');
                            } catch (Exception e) {
                                System.debug('Error updating count for user ' + userIdStr + ': ' + e.getMessage());
                            }
                        }
                    }
                }
            }

            // Update the Object_Tracker__c record if there were changes
            if (hasChanges) {
                tracker.User_Record_Summary__c = JSON.serialize(userValidationMap);
                update tracker;
                System.debug('Updated Object_Tracker__c User_Record_Summary__c: ' + tracker.User_Record_Summary__c);
            }

        } catch (Exception e) {
            System.debug('Error in updateUserValidationCounts: ' + e.getMessage());
            // Don't throw exception to avoid breaking the main flow
        }
    }

    /**
     * @description Count how many records were completely resolved (no longer in payload) per user
     * by checking the current payload after updates have been processed
     * @param trackerId The Object_Tracker__c record ID
     * @param updatedFieldsByRecordId Map of record IDs to list of updated fields
     * @param recordToOwnerMap Map of record ID to owner ID
     * @return Map of user ID to count of completely resolved records
     */
    private static Map<Id, Integer> getRecordsResolvedAfterUpdate(
        Id trackerId, 
        Map<Id, List<String>> updatedFieldsByRecordId, 
        Map<Id, Id> recordToOwnerMap
    ) {
        Map<Id, Integer> userToResolvedRecordsCount = new Map<Id, Integer>();
        
        try {
            // Get owner IDs for the updated records
            Set<Id> ownerIds = new Set<Id>(recordToOwnerMap.values());
            
            // Query Owner_based_Line_Items__c to check current payload state
            List<Owner_based_Line_Items__c> items = [
                SELECT Id, OwnerRecordId__c, Payload__c
                FROM Owner_based_Line_Items__c
                WHERE OwnerRecordId__c IN :ownerIds
                AND Object_Line_Tracker__r.Object_Tracker__c = :trackerId
                WITH SECURITY_ENFORCED
            ];

            // Group all payloads by owner to avoid double counting
            Map<Id, List<Owner_based_Line_Items__c>> ownerToPayloads = new Map<Id, List<Owner_based_Line_Items__c>>();
            for (Owner_based_Line_Items__c item : items) {
                Id ownerId = item.OwnerRecordId__c;
                if (!ownerToPayloads.containsKey(ownerId)) {
                    ownerToPayloads.put(ownerId, new List<Owner_based_Line_Items__c>());
                }
                ownerToPayloads.get(ownerId).add(item);
            }

            // Process each owner only once, checking all their payloads
            for (Id ownerId : ownerToPayloads.keySet()) {
                List<Owner_based_Line_Items__c> ownerPayloads = ownerToPayloads.get(ownerId);
                Integer resolvedCount = 0;
                List<String> updatedRecordsForOwner = new List<String>();
                List<String> resolvedRecordsForOwner = new List<String>();
                List<String> stillMissingRecordsForOwner = new List<String>();

                System.debug('=== DEBUGGING OWNER ' + ownerId + ' (' + ownerPayloads.size() + ' payload items) ===');

                // Check each record that was updated for this owner
                for (Id recordId : updatedFieldsByRecordId.keySet()) {
                    if (recordToOwnerMap.get(recordId) == ownerId) {
                        String recordIdStr = String.valueOf(recordId);
                        updatedRecordsForOwner.add(recordIdStr);
                        List<String> updatedFields = updatedFieldsByRecordId.get(recordId);
                        
                        // Check if this record is still in ANY of the owner's payloads
                        Boolean recordStillInAnyPayload = false;
                        String foundInPayloadId = '';
                        Integer payloadLength = 0;
                        
                        System.debug('🔍 Checking record ' + recordIdStr + ' across ' + ownerPayloads.size() + ' payload items...');
                        
                        for (Owner_based_Line_Items__c item : ownerPayloads) {
                            System.debug('   Checking payload item ' + item.Id + ' (length: ' + (item.Payload__c != null ? item.Payload__c.length() : 0) + ')');
                            
                            if (String.isNotBlank(item.Payload__c) && item.Payload__c != '{}' && item.Payload__c != '[]') {
                                if (item.Payload__c.contains('"' + recordIdStr + '":')) {
                                    recordStillInAnyPayload = true;
                                    foundInPayloadId = item.Id;
                                    payloadLength = item.Payload__c.length();
                                    
                                    System.debug('   ✋ FOUND: Record ' + recordIdStr + ' exists in payload item ' + item.Id + ' (length: ' + payloadLength + ')');
                                    
                                    // Extract what fields are still missing
                                    Integer startPos = item.Payload__c.indexOf('"' + recordIdStr + '":');
                                    Integer arrayStart = item.Payload__c.indexOf('[', startPos);
                                    Integer arrayEnd = item.Payload__c.indexOf(']', arrayStart);
                                    if (arrayStart != -1 && arrayEnd != -1 && arrayEnd > arrayStart) {
                                        String fieldsArray = item.Payload__c.substring(arrayStart + 1, arrayEnd);
                                        System.debug('   Still missing fields for ' + recordIdStr + ': ' + fieldsArray);
                                    }
                                    break; // Found in one payload, no need to check others
                                } else {
                                    System.debug('   ✅ NOT FOUND: Record ' + recordIdStr + ' not in payload item ' + item.Id);
                                }
                            } else {
                                System.debug('   ⭕ EMPTY: Payload item ' + item.Id + ' is empty or null');
                            }
                        }
                        
                        if (!recordStillInAnyPayload) {
                            // Record was completely removed from ALL payloads (all missing fields resolved)
                            resolvedCount++;
                            resolvedRecordsForOwner.add(recordIdStr);
                            System.debug('✅ Record ' + recordIdStr + ' was COMPLETELY RESOLVED for owner ' + ownerId + ' (Updated fields: ' + updatedFields + ')');
                            System.debug('   📊 RESOLUTION CONFIRMED: Record not found in any of the ' + ownerPayloads.size() + ' payload items');
                        } else {
                            stillMissingRecordsForOwner.add(recordIdStr);
                            System.debug('⚠️  Record ' + recordIdStr + ' STILL HAS MISSING FIELDS for owner ' + ownerId + ' (Updated fields: ' + updatedFields + ')');
                            System.debug('   📍 STILL EXISTS: Found in payload item ' + foundInPayloadId + ' (length: ' + payloadLength + ')');
                        }
                    }
                }

                System.debug('SUMMARY FOR OWNER ' + ownerId + ':');
                System.debug('- Total updated records: ' + updatedRecordsForOwner.size() + ' → ' + updatedRecordsForOwner);
                System.debug('- Completely resolved: ' + resolvedRecordsForOwner.size() + ' → ' + resolvedRecordsForOwner);
                System.debug('- Still have missing fields: ' + stillMissingRecordsForOwner.size() + ' → ' + stillMissingRecordsForOwner);
                System.debug('=== END DEBUGGING OWNER ' + ownerId + ' ===');

                if (resolvedCount > 0) {
                    userToResolvedRecordsCount.put(ownerId, resolvedCount);
                    System.debug('🎯 Owner ' + ownerId + ' had ' + resolvedCount + ' records completely resolved - COUNT WILL DECREASE BY ' + resolvedCount);
                }
            }

        } catch (Exception e) {
            System.debug('Error in getRecordsResolvedAfterUpdate: ' + e.getMessage());
        }

        return userToResolvedRecordsCount;
    }

    /**
     * @description Get owner IDs for a set of record IDs
     * @param recordIds Set of record IDs
     * @return Map of record ID to owner ID
     */
    private static Map<Id, Id> getRecordOwners(Set<Id> recordIds) {
        Map<Id, Id> recordToOwnerMap = new Map<Id, Id>();
        
        if (recordIds.isEmpty()) {
            return recordToOwnerMap;
        }

        // Group records by object type for efficient querying
        Map<String, Set<Id>> objectTypeToRecordIds = new Map<String, Set<Id>>();
        for (Id recordId : recordIds) {
            String objectType = recordId.getSObjectType().getDescribe().getName();
            if (!objectTypeToRecordIds.containsKey(objectType)) {
                objectTypeToRecordIds.put(objectType, new Set<Id>());
            }
            objectTypeToRecordIds.get(objectType).add(recordId);
        }

        // Query each object type separately
        for (String objectType : objectTypeToRecordIds.keySet()) {
            try {
                Set<Id> ids = objectTypeToRecordIds.get(objectType);
                String soql = 'SELECT Id, OwnerId FROM ' + String.escapeSingleQuotes(objectType) + ' WHERE Id IN :ids WITH SECURITY_ENFORCED';
                List<SObject> records = Database.query(soql);
                
                for (SObject record : records) {
                    recordToOwnerMap.put((Id)record.get('Id'), (Id)record.get('OwnerId'));
                }
            } catch (Exception e) {
                System.debug('Error querying owners for object type ' + objectType + ': ' + e.getMessage());
            }
        }

        return recordToOwnerMap;
    }

    /**
* Batch update: Remove updated fields from Owner_based_Line_Items__c.Payload__c for all updated records/fields.
* Called after successful record update(s) from UI.
*/
    public static void removeUpdatedFieldsFromPayloadBatch(
        Id trackerId,
        Map<Id, List<String>> updatedFieldsByRecordId
    ) {
        if (trackerId == null || updatedFieldsByRecordId == null || updatedFieldsByRecordId.isEmpty()){
            return;
        }

        // If dealing with a large number of records, use batch processing
        if (updatedFieldsByRecordId.size() > 50) {
            processLargePayloadUpdateBatch(trackerId, updatedFieldsByRecordId);
            return;
        }

        // Group recordIds by ownerId for efficient SOQL
        Set<Id> recordIds = new Set<Id>(updatedFieldsByRecordId.keySet());

        // Group recordIds by object type
        Map<String, Set<Id>> objectTypeToRecordIds = new Map<String, Set<Id>>();
        for (Id recId : recordIds) {
            String objApi = recId.getSObjectType().getDescribe().getName();
            if (!objectTypeToRecordIds.containsKey(objApi)){
                objectTypeToRecordIds.put(objApi, new Set<Id>());
            }
            objectTypeToRecordIds.get(objApi).add(recId);
        }

        // Query records to get OwnerId for a single object type to reduce heap usage
        Map<Id, SObject> recs = new Map<Id, SObject>();
        if (!objectTypeToRecordIds.isEmpty()) {
            String objApi = objectTypeToRecordIds.keySet().iterator().next();
            Set<Id> ids = objectTypeToRecordIds.get(objApi);
            if (!ids.isEmpty()) {
                String soql = String.escapeSingleQuotes('SELECT Id, OwnerId FROM ' + objApi + ' WHERE Id IN :ids');
                recs.putAll(new Map<Id, SObject>(Database.query(soql)));
            }
        }

        // Map ownerId to recordIds
        Map<Id, List<Id>> ownerToRecordIds = new Map<Id, List<Id>>();
        for (Id recId : recs.keySet()) {
            Id ownerId = (Id) recs.get(recId).get('OwnerId');
            if (!ownerToRecordIds.containsKey(ownerId)){
                ownerToRecordIds.put(ownerId, new List<Id>());
            }
            ownerToRecordIds.get(ownerId).add(recId);
        }

        // Query all Owner_based_Line_Items__c for these owners/tracker
        List<Owner_based_Line_Items__c> items = [
            SELECT Id, OwnerRecordId__c, Payload__c
            FROM Owner_based_Line_Items__c
            WHERE OwnerRecordId__c IN :ownerToRecordIds.keySet()
            AND Object_Line_Tracker__r.Object_Tracker__c = :trackerId
            WITH SECURITY_ENFORCED
        ];

        List<Owner_based_Line_Items__c> toUpdate = new List<Owner_based_Line_Items__c>();

        // Process each item once to avoid multiple deserializations
        for (Owner_based_Line_Items__c item : items) {
            if (String.isBlank(item.Payload__c)){
                continue;
            }

            // Check payload size - use string operations for large payloads instead of skipping
            Boolean isLargePayload = item.Payload__c.length() > 25000;
            if (isLargePayload) {
                System.debug('Processing large payload with string operations: ' + item.Id + ' size: ' + item.Payload__c.length());
            }

            // Process payload; prefer small-payload Map-based path, fall back to string ops for larger payloads
            String payloadStr = item.Payload__c;
            Boolean changed = false;

            try {

                         // Try Map-based approach first for small payloads only
             if (!isLargePayload && item.Payload__c.length() <= 12000) {
                try {
                    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(payloadStr);
                    if (payload != null) {
                        Integer beforeCount = payload.size();
                        List<Id> recList = ownerToRecordIds.containsKey(item.OwnerRecordId__c) ? ownerToRecordIds.get(item.OwnerRecordId__c) : new List<Id>();
                        for (Id recId : recList) {
                            String recKey = (String)recId;
                            if (payload.containsKey(recKey)) {
                                List<Object> missingFieldsObj = (List<Object>) payload.get(recKey);
                                List<String> missingFields = new List<String>();
                                if (missingFieldsObj != null) {
                                    for (Object o : missingFieldsObj) {
                                        missingFields.add(String.valueOf(o));
                                    }
                                }
                                List<String> upd = updatedFieldsByRecordId.get(recId);
                                if (upd != null) {
                                    for (String field : upd) {
                                        for (Integer i = missingFields.size() - 1; i >= 0; i--) {
                                            if (missingFields[i] == field) {
                                                missingFields.remove(i);
                                            }
                                        }
                                    }
                                }
                                if (missingFields.isEmpty()) {
                                    payload.remove(recKey);
                                } else {
                                    List<Object> newMissingFieldsObj = new List<Object>();
                                    for (String s : missingFields) {
                                        newMissingFieldsObj.add(s);
                                    }
                                    payload.put(recKey, newMissingFieldsObj);
                                }
                                changed = true;
                            }
                        }
                        if (changed) {
                            Integer afterCount = payload.size();
                            Integer removedRecords = beforeCount - afterCount;
                            item.Payload__c = payload.isEmpty() ? null : JSON.serialize(payload);
                            payloadStr = item.Payload__c == null ? '{}' : item.Payload__c;
                            toUpdate.add(item);
                            

                            
                            System.debug('Owner ' + String.valueOf(item.OwnerRecordId__c) + ' Item ' + item.Id + ' (map) before=' + beforeCount + ' after=' + afterCount + ' removed=' + removedRecords);
                            // Avoid processing the same item again via string path which can cause duplicate DML IDs
                            continue;
                        }
                    }
                } catch (Exception ex) {
                    changed = false; // fallback to string path below
                }
            }

            List<Id> ownerRecIds = ownerToRecordIds.containsKey(item.OwnerRecordId__c) ? ownerToRecordIds.get(item.OwnerRecordId__c) : new List<Id>();
            Integer removedRecordsStr = 0;
            Integer beforeCountStr = 0;
            if (String.isNotBlank(payloadStr)) {
                Integer idxScan = 0;
                String marker = '\":[\"';
                while (true) {
                    Integer pos = payloadStr.indexOf(marker, idxScan);
                    if (pos == -1) break;
                    beforeCountStr++;
                    idxScan = pos + marker.length();
                }
            }
            for (Id recId : ownerRecIds) {
                if (changed) { break; }
                String recIdStr = (String)recId;
                                if (payloadStr.contains('"' + recIdStr + '"')) {
                    // Find the record entry in the JSON string using Apex methods
                    String searchKey = '"' + recIdStr + '":';
                    Integer startIndex = payloadStr.indexOf(searchKey);

                    if (startIndex != -1) {
                        // Find the opening bracket after the key
                        Integer bracketStart = payloadStr.indexOf('[', startIndex);
                        if (bracketStart != -1) {
                            // Find the closing bracket
                            Integer bracketEnd = payloadStr.indexOf(']', bracketStart);
                            if (bracketEnd != -1) {
                                // Extract the fields string
                                String fieldsStr = payloadStr.substring(bracketStart + 1, bracketEnd);
                                List<String> missingFields = new List<String>();

                                // Parse fields from the string
                                if (String.isNotBlank(fieldsStr)) {
                                    String[] fieldParts = fieldsStr.split(',');
                                    for (String field : fieldParts) {
                                        field = field.trim().replaceAll('"', '');
                                        if (String.isNotBlank(field)) {
                                            missingFields.add(field);
                                        }
                                    }
                                }

                                // Remove updated fields
                                for (String field : updatedFieldsByRecordId.get(recId)) {
                                    // Remove all occurrences of the field
                                    for (Integer i = missingFields.size() - 1; i >= 0; i--) {
                                        if (missingFields[i] == field) {
                                            missingFields.remove(i);
                                        }
                                    }
                                }

                                // Reconstruct the JSON string
                                if (missingFields.isEmpty()) {
                                    // Remove entire record entry
                                    String beforeRecord = payloadStr.substring(0, startIndex);
                                    String afterRecord = payloadStr.substring(bracketEnd + 1);

                                    // Remove trailing comma if present
                                    if (beforeRecord.endsWith(',')) {
                                        beforeRecord = beforeRecord.substring(0, beforeRecord.length() - 1);
                                    }
                                    if (afterRecord.startsWith(',')) {
                                        afterRecord = afterRecord.substring(1);
                                    }

                                    payloadStr = beforeRecord + afterRecord;
                                    removedRecordsStr++;
                                } else {
                                    // Update the fields array
                                    String newFieldsStr = '"' + String.join(missingFields, '","') + '"';
                                    String beforeBracket = payloadStr.substring(0, bracketStart + 1);
                                    String afterBracket = payloadStr.substring(bracketEnd);
                                    payloadStr = beforeBracket + newFieldsStr + afterBracket;
                                }
                                changed = true;
                            }
                        }
                    }
                }
            }

                        // Clean up the JSON string
            if (changed) {
                // Remove trailing commas and clean up using Apex methods
                payloadStr = payloadStr.replace(',}', '}');
                payloadStr = payloadStr.replace(',]', ']');
                payloadStr = payloadStr.replace('{,}', '{}');

                if (payloadStr.trim() == '{}' || payloadStr.trim() == '' || payloadStr.trim() == '[]') {
                    item.Payload__c = null;
                } else {
                    item.Payload__c = payloadStr;
                }
                toUpdate.add(item);
                Integer afterCountStr = 0;
                if (String.isNotBlank(item.Payload__c)) {
                    Integer idxScan2 = 0;
                    String marker2 = '\":[\"';
                    while (true) {
                        Integer pos2 = item.Payload__c.indexOf(marker2, idxScan2);
                        if (pos2 == -1) break;
                        afterCountStr++;
                        idxScan2 = pos2 + marker2.length();
                    }
                }
                

                
                System.debug('Owner ' + String.valueOf(item.OwnerRecordId__c) + ' Item ' + item.Id + ' (string) before=' + beforeCountStr + ' after=' + afterCountStr + ' removed=' + removedRecordsStr);
            }
            } catch (Exception e) {
                System.debug('Error processing payload for item ' + item.Id + ': ' + e.getMessage());
                // Skip this item if there's an error
                continue;
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    /**
     * Process large payload updates in smaller batches to avoid heap size issues
     */
    private static void processLargePayloadUpdateBatch(
        Id trackerId,
        Map<Id, List<String>> updatedFieldsByRecordId
    ) {
        // Process in chunks of 25 records at a time (reduced for better memory management)
        Integer batchSize = 25;
        List<Id> recordIds = new List<Id>(updatedFieldsByRecordId.keySet());

        for (Integer i = 0; i < recordIds.size(); i += batchSize) {
            Integer endIndex = Math.min(i + batchSize, recordIds.size());

            Map<Id, List<String>> batchUpdatedFields = new Map<Id, List<String>>();
            for (Integer j = i; j < endIndex; j++) {
                Id recordId = recordIds[j];
                batchUpdatedFields.put(recordId, updatedFieldsByRecordId.get(recordId));
            }

            // Process this batch
            removeUpdatedFieldsFromPayloadBatch(trackerId, batchUpdatedFields);

            // Clear variables to free up heap
            batchUpdatedFields.clear();

            // Force garbage collection by clearing the list
            recordIds.clear();
            recordIds = new List<Id>(updatedFieldsByRecordId.keySet());
        }
    }

    public static Object convertValueByType(Object value, Schema.DisplayType fieldType) {
        if (value == null) {
            return null;
        }

        try {
            switch on fieldType {
                when CURRENCY, DOUBLE, PERCENT {
                    if (value instanceof String) {
                        String clean = ((String)value).replace(',', '');
                        return String.isBlank(clean) ? null : Decimal.valueOf(clean);
                    }
                    return value;
                }
                when INTEGER {
                    if (value instanceof String) {
                        String clean = ((String)value).replace(',', '');
                        return String.isBlank(clean) ? null : Integer.valueOf(clean);
                    }
                    return value;
                }
                when LONG {
                    if (value instanceof String) {
                        String clean = ((String)value).replace(',', '');
                        return String.isBlank(clean) ? null : Long.valueOf(clean);
                    }
                    return value;
                }
                when BOOLEAN {
                    if (value instanceof String) {
                        return Boolean.valueOf((String)value);
                    }
                    return value;
                }
                when DATE {
                    if (value instanceof String) {
                        return String.isBlank((String)value) ? null : Date.valueOf((String)value);
                    }
                    return value;
                }
              when DATETIME {
    if (value instanceof String) {
        String dtStr = (String) value;
        if (String.isBlank(dtStr)) {
            return null;
        }

        if (dtStr.contains('T')) {
            String[] parts = dtStr.split('T');
            if (parts.size() == 2) {
                String datePart = parts[0];
                String timePart = parts[1];
                Boolean isUTC = false;

                // Detect UTC indicator 'Z'
                if (timePart.endsWith('Z')) {
                    timePart = timePart.substring(0, timePart.length() - 1);
                    isUTC = true;
                }

                // Remove milliseconds if present
                if (timePart.contains('.')) {
                    timePart = timePart.split('\\.')[0];
                }

                DateTime parsed = DateTime.valueOf(datePart + ' ' + timePart);

                // Convert from UTC to user's timezone if 'Z' was present
                if (isUTC) {
                    Integer offsetSeconds = Math.mod(UserInfo.getTimeZone().getOffset(parsed), 86400000) / 1000;
                    parsed = parsed.addSeconds(offsetSeconds);
                }

                return parsed;
            }
        }

        // Fallback if it's already in a valid DateTime format
        return DateTime.valueOf(dtStr);
    }
    return value;
}



                when TIME {
                    if (value instanceof String) {
                        String timeStr = ((String)value).trim().toLowerCase();

                        if (String.isBlank(timeStr)){
                            return null;
                        }

                        // Handle AM/PM formats like "12:00 am"
                        Boolean isPM = timeStr.contains('pm');
                        Boolean isAM = timeStr.contains('am');

                        timeStr = timeStr.replaceAll('[^0-9:]', '');

                        List<String> parts = timeStr.split(':');
                        if (parts.size() >= 2) {
                            Integer hours = Integer.valueOf(parts[0]);
                            Integer minutes = Integer.valueOf(parts[1]);
                            Integer seconds = (parts.size() == 3) ? Integer.valueOf(parts[2]) : 0;

                            if (isPM && hours < 12){
                                 hours += 12;
                                }
                            if (isAM && hours == 12){
                            hours = 0;
                        }

                            return Time.newInstance(hours, minutes, seconds, 0);
                        }
                    }

                    return value;
                }


                when else {
                    return value;
                }
            }
        } catch (Exception e) {
            return value;
        }
    }
    public class ResponseWrapper {
        @InvocableVariable(label='Object API Name')
        public String objectApiName;

        @InvocableVariable(label='Object Label')
        public String objectLabel;

        @InvocableVariable(label='Record ID')
        public String recordId;

        @InvocableVariable(label='Record Name')
        public String recordName;

        @InvocableVariable(label='Field Values')
        public SObject fieldValues;

        @InvocableVariable(label='Field label')
        public String fieldLabels;
    }
    public class SaveResultWrapper {
        @AuraEnabled public Boolean hasErrors;
        @AuraEnabled public Map<String, Map<String, String>> fieldErrors;
    }
}