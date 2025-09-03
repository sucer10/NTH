/**
 * @class DynamicAgent
 * @author Ayushi patel
 * @created 2025-07-15
 * @description
 * - Construct class to fetch the details of objects dynamically to the agent
 * - Handle save the suggestions which is provide by agent
 */
public without sharing class WithoutAgentForceCntr {
 @AuraEnabled
 /**@description Saves field suggestions for one or more records received from the AI agent on the UI.
    *This method supports both single-record and bulk updates, depending on the input
    *@param recordFieldValues
    *@return SaveResultWrapper
    */
public static SaveResultWrapper saveMultipleRecordFields(Map<String, Map<String, Object>> recordFieldValues) {
        SaveResultWrapper result = new SaveResultWrapper();
        result.fieldErrors = new Map<String, Map<String, String>>();
        result.hasErrors = false;

        if (recordFieldValues == null || recordFieldValues.isEmpty()) {
            throw new AuraHandledException('No records provided for update.');
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
                            fieldErrors.put(fieldApi, 'Too long (max ' + maxLength + ' characters)');
                            continue;
                        }
                    }

                  if ((fieldType == Schema.DisplayType.Currency || fieldType == Schema.DisplayType.Double) && convertedValue != null) {
                    String strVal = String.valueOf(convertedValue).trim();

                    if (!Pattern.matches('^-?\\d*(\\.\\d+)?$', strVal)) {
                        fieldErrors.put(fieldApi, 'Enter Valid Number');
                        continue;
                    }

                    Schema.DescribeFieldResult d = fieldMap.get(fieldApi).getDescribe();

                    try {


                    Integer digitsBefore = strVal.contains('.') ? strVal.split('\\.')[0].replace('-', '').length() : strVal.replace('-', '').length();
                    Integer digitsAfter = strVal.contains('.') ? strVal.split('\\.')[1].length() : 0;

                    if (digitsBefore + digitsAfter > d.getPrecision()) {
                        fieldErrors.put(fieldApi, 'Value exceeds allowed precision: maximum ' + d.getPrecision() + ' digits allowed including decimals');

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
                        if (phoneDigits.length() > 10) {
                            fieldErrors.put(fieldApi, 'Phone number must be exactly 10 digits');
                            continue;
                        }
                        if (!Pattern.matches('^[\\d\\-\\+()\\s]+$', String.valueOf(convertedValue))) {
                            fieldErrors.put(fieldApi, 'Invalid phone number format.');
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

                    // Get max length dynamically from Salesforce schema
                    Schema.DescribeSObjectResult objDescribe = Schema.getGlobalDescribe()
                        .get(objectApiName)
                        .getDescribe();
                    Integer maxUrlLength = objDescribe.fields.getMap()
                        .get(fieldApi)
                        .getDescribe()
                        .getLength();

                    // Check blank or too long
                    if (String.isBlank(urlStr) || urlStr.length() > maxUrlLength) {
                        fieldErrors.put(fieldApi, 'URL is too long . Max length: ' + maxUrlLength);
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
}catch (DmlException dmlEx) {
    for (Integer i = 0; i < dmlEx.getNumDml(); i++) {
        String msg = dmlEx.getDmlMessage(i);
        Id dmlRecordId = (Id) dmlEx.getDmlId(i);
        String recId = String.valueOf(dmlRecordId);
        String fieldMatch = 'Unknown';
        String fieldType = 'UNKNOWN';
        String finalMsg = msg;

        // Try to extract [FieldName]
        Matcher m = Pattern.compile('\\[([a-zA-Z0-9_]+)\\]').matcher(msg);
        if (m.find()) {
            fieldMatch = m.group(1);
        }

        // Handle duplicate value errors explicitly
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
                : 'This value already exist';

            fieldMatch = 'Unknown'; // To trigger top-level error
        } else if (fieldMatch != 'Unknown') {
            // Only try to get field type when field name is known
            if (objectTypePerRecord.containsKey(recId)) {
                Map<String, Schema.SObjectField> fMap = Schema.getGlobalDescribe()
                    .get(objectTypePerRecord.get(recId)).getDescribe().fields.getMap();
                if (fMap.containsKey(fieldMatch)) {
                    fieldType = fMap.get(fieldMatch).getDescribe().getType().name();
                }
            }
        }

        // Never try to infer field by value in this catch block.
        // If no match, assign to 'Unknown'

        // Populate error map
        if (!result.fieldErrors.containsKey(recId)) {
            result.fieldErrors.put(recId, new Map<String, String>());
        }
        result.fieldErrors.get(recId).put(fieldMatch, finalMsg);
    }
}

}

if (!result.fieldErrors.isEmpty()) {
    throw new AuraHandledException(JSON.serialize(result.fieldErrors));
}

        // Remove updated fields from payloads only if record had no errors
        Map<Id, List<String>> cleanUpdatedMap = new Map<Id, List<String>>();
        for (String recordId : updatedFieldsPerRecord.keySet()) {
            if (!result.fieldErrors.containsKey(recordId)) {
                cleanUpdatedMap.put((Id) recordId, updatedFieldsPerRecord.get(recordId));
            }
        }

         if (!cleanUpdatedMap.isEmpty()) {
        // Step 1: Collect all object names
        Set<String> objectNames = new Set<String>(objectTypePerRecord.values());

        // Step 2: Bulk query to get latest Object_Tracker__c per object name
        Map<String, Object_Tracker__c> latestTrackersByName = new Map<String, Object_Tracker__c>();
        for (Object_Tracker__c tracker : [
            SELECT Id, Name
            FROM Object_Tracker__c
            WHERE Name IN :objectNames
            WITH SECURITY_ENFORCED
            ORDER BY CreatedDate DESC
        ]) {
            String nameKey = tracker.Name.toLowerCase();
            if (!latestTrackersByName.containsKey(nameKey)) {
                latestTrackersByName.put(nameKey, tracker);
            }
        }

        // Step 3: Use map instead of querying inside loop
        for (String obj : objectNames) {
            String objKey = obj.toLowerCase();
            if (latestTrackersByName.containsKey(objKey)) {
                // Filter records for this specific object type
                Map<Id, List<String>> objectSpecificUpdates = new Map<Id, List<String>>();
                for (Id recordId : cleanUpdatedMap.keySet()) {
                    String recordObjectType = recordId.getSObjectType().getDescribe().getName();
                    if (recordObjectType == obj) {
                        objectSpecificUpdates.put(recordId, cleanUpdatedMap.get(recordId));
                    }
                }
                
                if (!objectSpecificUpdates.isEmpty()) {
                    Id trackerId = latestTrackersByName.get(objKey).Id;
                    removeUpdatedFieldsFromPayloadBatch(trackerId, objectSpecificUpdates);
                    // Update user validation counts after successful updates
                    updateUserValidationCounts(trackerId, objectSpecificUpdates);
                }
            }
        }
    }

        result.hasErrors = !result.fieldErrors.isEmpty();
        return result;
    }

    /**
     * @description Update user validation counts in Object_Tracker__c.User_Record_Summary__c
     * after successful record updates. Counts records that were completely removed from payload.
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
                SELECT Id, Name, User_Record_Summary__c 
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

            // Count records that were completely resolved (removed from payload) per user
            Map<Id, Integer> userToResolvedRecordsCount = getResolvedRecordsCount(trackerId, updatedFieldsByRecordId, recordToOwnerMap);

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
                if (Schema.sObjectType.Object_Tracker__c.isUpdateable()) {
                    update tracker;
                } else {
                    throw new AuraHandledException('You do not have permission to update Object_Tracker__c records.');
                }
            }

        } catch (Exception e) {
            System.debug('Error in updateUserValidationCounts: ' + e.getMessage());
            // Don't throw exception to avoid breaking the main flow
        }
    }

    /**
     * @description Count how many records were completely resolved (removed from payload) per user
     * @param trackerId The Object_Tracker__c record ID
     * @param updatedFieldsByRecordId Map of record IDs to list of updated fields
     * @param recordToOwnerMap Map of record ID to owner ID
     * @return Map of user ID to count of completely resolved records
     */
    private static Map<Id, Integer> getResolvedRecordsCount(
        Id trackerId, 
        Map<Id, List<String>> updatedFieldsByRecordId, 
        Map<Id, Id> recordToOwnerMap
    ) {
        Map<Id, Integer> userToResolvedRecordsCount = new Map<Id, Integer>();
        
        try {
            // Get owner IDs for the updated records
            Set<Id> ownerIds = new Set<Id>(recordToOwnerMap.values());
            
            // Query Owner_based_Line_Items__c to check current payload state after updates
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

                // Check each record that was updated for this owner
                for (Id recordId : updatedFieldsByRecordId.keySet()) {
                    if (recordToOwnerMap.get(recordId) == ownerId) {
                        String recordIdStr = String.valueOf(recordId);
                        
                        // Check if this record is still in ANY of the owner's payloads
                        Boolean recordStillInAnyPayload = false;
                        
                        for (Owner_based_Line_Items__c item : ownerPayloads) {
                            if (String.isNotBlank(item.Payload__c) && item.Payload__c != '{}' && item.Payload__c != '[]') {
                                if (item.Payload__c.contains('"' + recordIdStr + '":')) {
                                    recordStillInAnyPayload = true;
                                    break; // Found in one payload, no need to check others
                                }
                            }
                        }
                        
                        if (!recordStillInAnyPayload) {
                            // Record was completely removed from ALL payloads (all missing fields resolved)
                            resolvedCount++;
                            System.debug('✅ Record ' + recordIdStr + ' completely resolved for owner ' + ownerId);
                        } else {
                            System.debug('⚠️ Record ' + recordIdStr + ' still has missing fields for owner ' + ownerId);
                        }
                    }
                }

                if (resolvedCount > 0) {
                    userToResolvedRecordsCount.put(ownerId, resolvedCount);
                    System.debug('🎯 Owner ' + ownerId + ' had ' + resolvedCount + ' records completely resolved - COUNT WILL DECREASE BY ' + resolvedCount);
                }
            }

        } catch (Exception e) {
            System.debug('Error in getResolvedRecordsCount: ' + e.getMessage());
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

    /**@description Batch update: Remove updated fields from Owner_based_Line_Items__c.Payload__c for all updated records/fields.
     * Called after successful record update(s) from UI.
     */
   public static void removeUpdatedFieldsFromPayloadBatch(
        Id trackerId,
        Map<Id, List<String>> updatedFieldsByRecordId
    ) {
        if (trackerId == null || updatedFieldsByRecordId == null || updatedFieldsByRecordId.isEmpty()){
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

        Map<Id, SObject> recs = new Map<Id, SObject>();

            if (!objectTypeToRecordIds.isEmpty()) {
                String objApi = objectTypeToRecordIds.keySet().iterator().next(); // Get the only object type
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

                // String-based processing for large payloads
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
    // Check if the user has update access to this object
            if (Schema.sObjectType.Owner_based_Line_Items__c.isUpdateable()) {
                update toUpdate;
            } else {
                throw New AuraHandledException('You do not have permission to update records of type Owner_based_Line_Items__c.');
            }
        }
    }

    /**@description convertValueByType method to check dataType
     * @param value: value to be converted
     * @param fieldType: dataType of the value
     * @return Object: converted value
     */

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
                    String[] parts = ((String)value).split(':');
                    if (parts.size() == 3) {
                        return Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), Integer.valueOf(parts[2]), 0);
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
    /**@description SaveResultWrapper
     */
        public class SaveResultWrapper {
            @AuraEnabled public Boolean hasErrors;
            @AuraEnabled public Map<String, Map<String, String>> fieldErrors;
    }
}