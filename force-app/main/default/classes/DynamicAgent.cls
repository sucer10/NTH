/**
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
        if (objectApiName == null) {
            throw new AuraHandledException('Unable to determine object API name from recordId');
        }

        Schema.DescribeSObjectResult describe = Schema.getGlobalDescribe()
            .get(objectApiName)
            .getDescribe();
        String objectLabel = describe.getLabel();

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
    // This method supports both single-record and bulk updates, depending on the input.
    @AuraEnabled
    public static SaveResultWrapper saveMultipleRecordFields(Map<String, Map<String, Object>> recordFieldValues) {
        SaveResultWrapper result = new SaveResultWrapper();
        result.fieldErrors = new Map<String, Map<String, String>>();
        result.hasErrors = false;

        if (recordFieldValues == null || recordFieldValues.isEmpty()) {
            throw new AuraHandledException('No records provided for update.');
        }

        if (recordFieldValues.size() > 100) {
            throw new AuraHandledException('Too many records provided for update. Maximum allowed is 100 records.');
        }

        Map<String, SObject> recordsToUpdate = new Map<String, SObject>();
        Map<String, List<String>> updatedFieldsPerRecord = new Map<String, List<String>>();
        Map<String, String> objectTypePerRecord = new Map<String, String>();

        for (String recordId : recordFieldValues.keySet()) {
            Map<String, Object> fields = recordFieldValues.get(recordId);
            if (String.isBlank(recordId) || fields == null || fields.isEmpty()){
                continue;
            }

            Id recordIdObj = (Id) recordId;
            String objectApiName = recordIdObj.getSObjectType().getDescribe().getName();
            objectTypePerRecord.put(recordId, objectApiName);
            SObject record = recordIdObj.getSObjectType().newSObject(recordIdObj);

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
                            Decimal dVal = Decimal.valueOf(strVal);
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
                        if (!Pattern.compile('^[\\w.%+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$').matcher(String.valueOf(convertedValue)).matches()) {
                            fieldErrors.put(fieldApi, 'Invalid email format.');
                            continue;
                        }
                    }

                    if (fieldType == Schema.DisplayType.Phone && convertedValue != null) {
                        String phoneDigits = String.valueOf(convertedValue).replaceAll('[^\\d]', '');
                        if (!Pattern.compile('^[\\d\\-\\+()\\s]+$').matcher(String.valueOf(convertedValue)).matches()) {
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

                        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
                        if (!globalDescribe.containsKey(objectApiName)) {
                            continue;
                        }
                        Schema.DescribeSObjectResult objDescribe = globalDescribe.get(objectApiName).getDescribe();

                        Map<String, Schema.SObjectField> fieldsMap = objDescribe.fields.getMap();
                        if (!fieldsMap.containsKey(fieldApi)) {
                            continue;
                        }
                        Integer maxUrlLength = fieldsMap.get(fieldApi).getDescribe().getLength();

                        if (String.isBlank(urlStr) || urlStr.length() > maxUrlLength) {
                            fieldErrors.put(fieldApi, 'URL is too long. Max length: ' + maxUrlLength);
                            continue;
                        }

                        String regex = '^(https?://)?([\\w.-]+\\.)+[a-zA-Z]{2,}(:[0-9]+)?(/.*)?$';
                        if (!Pattern.compile(regex).matcher(urlStr).matches()) {
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

        if (!recordsToUpdate.isEmpty()) {
            try {
                update recordsToUpdate.values();
            } catch (DmlException dmlEx) {
                for (Integer i = 0; i < dmlEx.getNumDml(); i++) {
                    String msg = dmlEx.getDmlMessage(i);
                    Id dmlRecordId = (Id) dmlEx.getDmlId(i);
                    String recId = String.valueOf(dmlRecordId);
                    String fieldMatch = 'Unknown';
                    String finalMsg = msg;

                    Matcher m = Pattern.compile('\\[([a-zA-Z0-9_]+)\\]').matcher(msg);
                    if (m.find()) {
                        fieldMatch = m.group(1);
                    }

                    if (msg != null && msg.toLowerCase().contains('duplicate value')) {
                        List<String> fieldsDup = new List<String>();
                        for (String part : msg.split(',')) {
                            part = part.trim();
                            Integer idx = part.indexOf(' duplicates value');
                            if (idx > 0) {
                                String apiName = part.substring(0, idx).trim();
                                String label = apiName.replaceAll('__c', '').replaceAll('_', ' ').trim();
                                fieldsDup.add(label);
                            }
                        }
                        finalMsg = fieldsDup.isEmpty()
                            ? 'Duplicate value error. Some fields must be unique.'
                            : 'The field' + (fieldsDup.size() > 1 ? 's ' : ' ') + String.join(fieldsDup, ' and ') + ' must be unique. Duplicate values were found.';
                        fieldMatch = 'Unknown';
                    }

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

        Map<Id, List<String>> cleanUpdatedMap = new Map<Id, List<String>>();
        for (String recordId : updatedFieldsPerRecord.keySet()) {
            if (!result.fieldErrors.containsKey(recordId)) {
                cleanUpdatedMap.put((Id) recordId, updatedFieldsPerRecord.get(recordId));
            }
        }

        if (!cleanUpdatedMap.isEmpty()) {
            Set<String> objectNames = new Set<String>();
            for (String rid : cleanUpdatedMap.keySet()) {
                objectNames.add(((Id)rid).getSObjectType().getDescribe().getName());
            }

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

            for (String obj : objectNames) {
                String objKey = obj.toLowerCase();
                if (latestTrackersByName.containsKey(objKey)) {
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
                        updateUserValidationCounts(trackerId, objectSpecificUpdates);
                    }
                }
            }
        }

        result.hasErrors = !result.fieldErrors.isEmpty();
        return result;
    }

    public static void updateUserValidationCounts(Id trackerId, Map<Id, List<String>> updatedFieldsByRecordId) {
        if (trackerId == null || updatedFieldsByRecordId == null || updatedFieldsByRecordId.isEmpty()) {
            return;
        }

        try {
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
            Map<String, Object> userValidationMap;
            try {
                userValidationMap = (Map<String, Object>) JSON.deserializeUntyped(tracker.User_Record_Summary__c);
            } catch (Exception e) {
                System.debug('Error parsing User_Record_Summary__c JSON: ' + e.getMessage());
                return;
            }

            Set<Id> recordIds = updatedFieldsByRecordId.keySet();
            Map<Id, Id> recordToOwnerMap = getRecordOwners(recordIds);
            Map<Id, Integer> userToResolvedRecordsCount = getResolvedRecordsCount(trackerId, updatedFieldsByRecordId, recordToOwnerMap);

            Boolean hasChanges = false;
            for (Id userId : userToResolvedRecordsCount.keySet()) {
                String userIdStr = String.valueOf(userId);
                if (userValidationMap.containsKey(userIdStr)) {
                    String currentValue = String.valueOf(userValidationMap.get(userIdStr));
                    if (currentValue.contains('/')) {
                        List<String> parts = currentValue.split('/');
                        if (parts.size() == 2) {
                            try {
                                Integer currentMissing = Integer.valueOf(parts[0]);
                                Integer totalRecords = Integer.valueOf(parts[1]);
                                Integer resolvedRecords = userToResolvedRecordsCount.get(userId);
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
        }
    }

    private static Map<Id, Integer> getResolvedRecordsCount(
        Id trackerId, 
        Map<Id, List<String>> updatedFieldsByRecordId, 
        Map<Id, Id> recordToOwnerMap
    ) {
        Map<Id, Integer> userToResolvedRecordsCount = new Map<Id, Integer>();
        try {
            // Derive owner ids from payload rows to avoid mismatches with record OwnerId
            Set<Id> ownerIds = new Set<Id>();
            ownerIds.addAll(recordToOwnerMap.values());
            List<Owner_based_Line_Items__c> items = [
                SELECT Id, OwnerRecordId__c, Payload__c
                FROM Owner_based_Line_Items__c
                WHERE OwnerRecordId__c IN :ownerIds
                AND Object_Line_Tracker__r.Object_Tracker__c = :trackerId
                WITH SECURITY_ENFORCED
            ];

            Map<Id, List<Owner_based_Line_Items__c>> ownerToPayloads = new Map<Id, List<Owner_based_Line_Items__c>>();
            for (Owner_based_Line_Items__c item : items) {
                Id ownerId = item.OwnerRecordId__c;
                if (!ownerToPayloads.containsKey(ownerId)) {
                    ownerToPayloads.put(ownerId, new List<Owner_based_Line_Items__c>());
                }
                ownerToPayloads.get(ownerId).add(item);
            }

            for (Id ownerId : ownerToPayloads.keySet()) {
                List<Owner_based_Line_Items__c> ownerPayloads = ownerToPayloads.get(ownerId);
                Integer resolvedCount = 0;

                for (Id recordId : updatedFieldsByRecordId.keySet()) {
                    String recordIdStr = String.valueOf(recordId);
                    // Whitespace-tolerant presence check: "<Id>" : [
                    Pattern presencePattern = Pattern.compile('"' + recordIdStr + '"\\s*:\\s*\\[');
                    Boolean recordStillInAnyPayload = false;
                    for (Owner_based_Line_Items__c item : ownerPayloads) {
                        if (String.isNotBlank(item.Payload__c) && item.Payload__c != '{}' && item.Payload__c != '[]') {
                            if (presencePattern.matcher(item.Payload__c).find()) {
                                recordStillInAnyPayload = true;
                                break;
                            }
                        }
                    }
                    if (!recordStillInAnyPayload) {
                        resolvedCount++;
                    }
                }
                if (resolvedCount > 0) {
                    userToResolvedRecordsCount.put(ownerId, resolvedCount);
                }
            }
        } catch (Exception e) {
            System.debug('Error in getResolvedRecordsCount: ' + e.getMessage());
        }
        return userToResolvedRecordsCount;
    }

    private static Map<Id, Id> getRecordOwners(Set<Id> recordIds) {
        Map<Id, Id> recordToOwnerMap = new Map<Id, Id>();
        if (recordIds.isEmpty()) {
            return recordToOwnerMap;
        }
        Map<String, Set<Id>> objectTypeToRecordIds = new Map<String, Set<Id>>();
        for (Id recordId : recordIds) {
            String objectType = recordId.getSObjectType().getDescribe().getName();
            if (!objectTypeToRecordIds.containsKey(objectType)) {
                objectTypeToRecordIds.put(objectType, new Set<Id>());
            }
            objectTypeToRecordIds.get(objectType).add(recordId);
        }
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
     * Remove updated fields from Owner_based_Line_Items__c.Payload__c for all updated records/fields.
     */
    public static void removeUpdatedFieldsFromPayloadBatch(
        Id trackerId,
        Map<Id, List<String>> updatedFieldsByRecordId
    ) {
        if (trackerId == null || updatedFieldsByRecordId == null || updatedFieldsByRecordId.isEmpty()){
            return;
        }

        Set<Id> recordIds = new Set<Id>(updatedFieldsByRecordId.keySet());
        Map<String, Set<Id>> objectTypeToRecordIds = new Map<String, Set<Id>>();
        for (Id recId : recordIds) {
            String objApi = recId.getSObjectType().getDescribe().getName();
            if (!objectTypeToRecordIds.containsKey(objApi)){
                objectTypeToRecordIds.put(objApi, new Set<Id>());
            }
            objectTypeToRecordIds.get(objApi).add(recId);
        }

        Map<Id, SObject> recs = new Map<Id, SObject>();
        for (String objApi : objectTypeToRecordIds.keySet()) {
            Set<Id> ids = objectTypeToRecordIds.get(objApi);
            if (!ids.isEmpty()) {
                String soql = 'SELECT Id, OwnerId FROM ' + String.escapeSingleQuotes(objApi) + ' WHERE Id IN :ids';
                recs.putAll(new Map<Id, SObject>(Database.query(soql)));
            }
        }

        Map<Id, List<Id>> ownerToRecordIds = new Map<Id, List<Id>>();
        for (Id recId : recs.keySet()) {
            Id ownerId = (Id) recs.get(recId).get('OwnerId');
            if (!ownerToRecordIds.containsKey(ownerId)){
                ownerToRecordIds.put(ownerId, new List<Id>());
            }
            ownerToRecordIds.get(ownerId).add(recId);
        }

        List<Owner_based_Line_Items__c> items = [
            SELECT Id, OwnerRecordId__c, Payload__c
            FROM Owner_based_Line_Items__c
            WHERE OwnerRecordId__c IN :ownerToRecordIds.keySet()
            AND Object_Line_Tracker__r.Object_Tracker__c = :trackerId
            WITH SECURITY_ENFORCED
        ];

        List<Owner_based_Line_Items__c> toUpdate = new List<Owner_based_Line_Items__c>();

        for (Owner_based_Line_Items__c item : items) {
            if (String.isBlank(item.Payload__c)){
                continue;
            }

            Boolean isLargePayload = item.Payload__c.length() > 25000;
            String payloadStr = item.Payload__c;
            Boolean changed = false;

            try {
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
                                                if (missingFields[i].equalsIgnoreCase(field)) {
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
                                continue;
                            }
                        }
                    } catch (Exception ex) {
                        changed = false;
                    }
                }

                List<Id> ownerRecIds = ownerToRecordIds.containsKey(item.OwnerRecordId__c) ? ownerToRecordIds.get(item.OwnerRecordId__c) : new List<Id>();
                Integer beforeCountStr = 0;
                if (String.isNotBlank(payloadStr)) {
                    Matcher keyMatcherBefore = Pattern.compile('\"[a-zA-Z0-9]{15,18}\"\\s*:\\s*\\[').matcher(payloadStr);
                    while (keyMatcherBefore.find()) {
                        beforeCountStr++;
                    }
                }

                Boolean anyChange = false;
                for (Id recId : ownerRecIds) {
                    String recIdStr = (String)recId;
                    Matcher m = Pattern.compile('"' + recIdStr + '"\\s*:\\s*\\[').matcher(payloadStr);
                    if (!m.find()) {
                        continue;
                    }
                    Integer startIndex = m.start();
                    Integer bracketStart = m.end() - 1;
                    Integer bracketEnd = payloadStr.indexOf(']', bracketStart);
                    if (bracketEnd == -1) {
                        continue;
                    }

                    String fieldsStr = payloadStr.substring(bracketStart + 1, bracketEnd);
                    List<String> missingFields = new List<String>();
                    if (String.isNotBlank(fieldsStr)) {
                        List<String> fieldParts = fieldsStr.split(',');
                        for (String field : fieldParts) {
                            field = field.trim().replaceAll('"', '');
                            if (String.isNotBlank(field)) {
                                missingFields.add(field);
                            }
                        }
                    }

                    List<String> toRemove = updatedFieldsByRecordId.get(recId);
                    if (toRemove != null && !toRemove.isEmpty()) {
                        for (Integer i = missingFields.size() - 1; i >= 0; i--) {
                            if (toRemove.contains(missingFields[i])) {
                                missingFields.remove(i);
                            }
                        }
                    }

                    if (missingFields.isEmpty()) {
                        Integer entryStart = startIndex;
                        while (entryStart > 0) {
                            String ch = payloadStr.substring(entryStart - 1, entryStart);
                            if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
                                entryStart = entryStart - 1;
                            } else {
                                break;
                            }
                        }
                        if (entryStart > 0 && payloadStr.substring(entryStart - 1, entryStart) == ',') {
                            entryStart = entryStart - 1;
                            while (entryStart > 0) {
                                String ch2 = payloadStr.substring(entryStart - 1, entryStart);
                                if (ch2 == ' ' || ch2 == '\n' || ch2 == '\r' || ch2 == '\t') {
                                    entryStart = entryStart - 1;
                                } else {
                                    break;
                                }
                            }
                        }
                        Integer entryEnd = bracketEnd + 1;
                        while (entryEnd < payloadStr.length()) {
                            String chf = payloadStr.substring(entryEnd, entryEnd + 1);
                            if (chf == ' ' || chf == '\n' || chf == '\r' || chf == '\t') {
                                entryEnd = entryEnd + 1;
                            } else {
                                break;
                            }
                        }
                        if (entryEnd < payloadStr.length() && payloadStr.substring(entryEnd, entryEnd + 1) == ',') {
                            entryEnd = entryEnd + 1;
                        }

                        String beforeRecord = payloadStr.substring(0, entryStart);
                        String afterRecord = payloadStr.substring(Math.min(entryEnd, payloadStr.length()));
                        payloadStr = beforeRecord + afterRecord;
                        anyChange = true;
                    } else {
                        String newFieldsStr = '"' + String.join(missingFields, '","') + '"';
                        String beforeBracket = payloadStr.substring(0, bracketStart + 1);
                        String afterBracket = payloadStr.substring(bracketEnd);
                        payloadStr = beforeBracket + newFieldsStr + afterBracket;
                        anyChange = true;
                    }
                }

                if (anyChange) {
                    payloadStr = payloadStr.replace(',}', '}');
                    payloadStr = payloadStr.replace(',]', ']');
                    payloadStr = payloadStr.replace('{,}', '{}');
                    payloadStr = payloadStr.replace('{ }', '{}').replace('[ ]', '[]');

                    String trimmed = payloadStr.trim();
                    if (trimmed == '{}' || trimmed == '' || trimmed == '[]') {
                        item.Payload__c = null;
                    } else {
                        item.Payload__c = payloadStr;
                    }
                    toUpdate.add(item);
                }
            } catch (Exception e) {
                System.debug('Error processing payload for item ' + item.Id + ': ' + e.getMessage());
                continue;
            }
        }
        if (!toUpdate.isEmpty()) {
            if (Schema.sObjectType.Owner_based_Line_Items__c.isUpdateable()) {
                update toUpdate;
            } else {
                throw new AuraHandledException('You do not have permission to update records of type Owner_based_Line_Items__c.');
            }
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
                            List<String> parts = dtStr.split('T');
                            if (parts.size() == 2) {
                                String datePart = parts[0];
                                String timePart = parts[1];
                                Boolean isUTC = false;
                                if (timePart.endsWith('Z')) {
                                    timePart = timePart.substring(0, timePart.length() - 1);
                                    isUTC = true;
                                }
                                if (timePart.contains('.')) {
                                    timePart = timePart.split('\\.')[0];
                                }
                                DateTime parsed = DateTime.valueOf(datePart + ' ' + timePart);
                                if (isUTC) {
                                    Integer offsetSeconds = Math.mod(UserInfo.getTimeZone().getOffset(parsed), 86400000) / 1000;
                                    parsed = parsed.addSeconds(offsetSeconds);
                                }
                                return parsed;
                            }
                        }
                        return DateTime.valueOf(dtStr);
                    }
                    return value;
                }
                when TIME {
                    if (value instanceof String) {
                        List<String> parts = ((String)value).split(':');
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
    }
    public class SaveResultWrapper {
        @AuraEnabled public Boolean hasErrors;
        @AuraEnabled public Map<String, Map<String, String>> fieldErrors;
    }
}

