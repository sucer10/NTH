@IsTest(seeAllData=false)
private class DynamicAgentTest {
    @testSetup
    static void setupData() {
        Account testAccount = new Account(Name = 'Acme Test');
        insert testAccount;

        Contact testContact = new Contact(
            FirstName = 'Test',
            LastName = 'User',
            Email = 'test.user@example.com',
            Phone = '(415) 555-0123',
            AccountId = testAccount.Id
        );
        insert testContact;
    }

    @IsTest
    static void testGetRecordInfo_validAccount() {
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        List<String> recordIds = new List<String>{ String.valueOf(acc.Id) };

        Test.startTest();
        List<DynamicAgent.ResponseWrapper> response = DynamicAgent.getRecordInfo(recordIds);
        Test.stopTest();

        System.assertEquals(1, response.size(), 'Should return exactly one response');
        System.assertEquals('Account', response[0].objectApiName, 'Object API name should be Account');
        System.assertEquals(String.valueOf(acc.Id), response[0].recordId, 'Record Id should echo input');
        System.assertEquals(acc.Name, response[0].recordName, 'Record Name should be Account.Name');
        System.assertNotEquals(null, response[0].fieldValues, 'Field values should be populated');
    }

    @IsTest
    static void testGetRecordInfo_invalidInputs() {
        // Null list
        try {
            Test.startTest();
            DynamicAgent.getRecordInfo(null);
            Test.stopTest();
            System.assert(false, 'Expected exception for null input');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('cannot be null'), 'Should complain about null/empty');
        }

        // Empty list
        try {
            Test.startTest();
            DynamicAgent.getRecordInfo(new List<String>());
            Test.stopTest();
            System.assert(false, 'Expected exception for empty list');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('cannot be null'), 'Should complain about null/empty');
        }

        // Invalid Id format (length < 3)
        try {
            Test.startTest();
            DynamicAgent.getRecordInfo(new List<String>{ '0Z' });
            Test.stopTest();
            System.assert(false, 'Expected exception for invalid Id format');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Invalid record ID'), 'Should complain about invalid format');
        }
    }

    @IsTest
    static void testSaveMultipleRecordFields_validationOnly_noDmlAttempt() {
        Contact con = [SELECT Id, Email, Phone FROM Contact LIMIT 1];

        // Intentionally provide invalid values so that no updated fields are accepted and DML is skipped
        Map<String, Object> fieldsForContact = new Map<String, Object>{
            'NonExistent__c' => 'ignored',
            'Email' => 'not-an-email',
            'Phone' => '12345' // invalid, needs exactly 10 digits
        };

        Map<String, Map<String, Object>> payload = new Map<String, Map<String, Object>>{
            String.valueOf(con.Id) => fieldsForContact
        };

        Test.startTest();
        DynamicAgent.SaveResultWrapper result = DynamicAgent.saveMultipleRecordFields(payload);
        Test.stopTest();

        System.assertEquals(true, result.hasErrors, 'Result should indicate errors');
        System.assert(result.fieldErrors.containsKey(String.valueOf(con.Id)), 'Contact Id should be present in field errors');
        Map<String, String> errs = result.fieldErrors.get(String.valueOf(con.Id));
        System.assert(errs.containsKey('Email'), 'Email should have validation error');
        System.assert(errs.containsKey('Phone'), 'Phone should have validation error');

        // Ensure no DML update occurred due to all fields erroring out
        Contact after = [SELECT Id, Email, Phone FROM Contact WHERE Id = :con.Id];
        System.assertEquals(con.Email, after.Email, 'Email should remain unchanged');
        System.assertEquals(con.Phone, after.Phone, 'Phone should remain unchanged');
    }

    @IsTest
    static void testSaveMultipleRecordFields_ignoredFields_only() {
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        // Provide only unknown/blank values so nothing is updated and no errors
        Map<String, Object> fieldsForAccount = new Map<String, Object>{
            'NonExistent__c' => 'ignored',
            'Name' => '' // blank is skipped
        };
        Map<String, Map<String, Object>> payload = new Map<String, Map<String, Object>>{
            String.valueOf(acc.Id) => fieldsForAccount
        };

        Test.startTest();
        DynamicAgent.SaveResultWrapper result = DynamicAgent.saveMultipleRecordFields(payload);
        Test.stopTest();

        System.assertEquals(false, result.hasErrors, 'Should not have errors when nothing valid is provided');
        System.assertEquals(true, result.fieldErrors.isEmpty(), 'Field errors map should be empty');

        // Confirm Account unchanged
        Account after = [SELECT Id, Name FROM Account WHERE Id = :acc.Id];
        System.assertEquals(acc.Name, after.Name, 'Name should remain unchanged');
    }

    @IsTest
    static void testConvertValueByType_various() {
        // Currency/Decimal
        Object decVal = DynamicAgent.convertValueByType('1,234.50', Schema.DisplayType.Currency);
        System.assertEquals(Decimal.valueOf('1234.50'), (Decimal)decVal, 'Currency string should convert to Decimal');

        // Integer
        Object intVal = DynamicAgent.convertValueByType('1,234', Schema.DisplayType.Integer);
        System.assertEquals(1234, (Integer)intVal, 'Integer string with commas should convert');

        // Boolean
        Object boolVal = DynamicAgent.convertValueByType('true', Schema.DisplayType.Boolean);
        System.assertEquals(true, (Boolean)boolVal, 'Boolean string should convert');

        // Date
        Object dateVal = DynamicAgent.convertValueByType('2020-01-02', Schema.DisplayType.Date);
        System.assertEquals(Date.newInstance(2020, 1, 2), (Date)dateVal, 'Date string should convert');

        // Time
        Object timeVal = DynamicAgent.convertValueByType('10:20:30', Schema.DisplayType.Time);
        System.assertEquals(Time.newInstance(10, 20, 30, 0), (Time)timeVal, 'Time string should convert');

        // Datetime - format without Z to avoid TZ math in assertions
        Object dtVal = DynamicAgent.convertValueByType('2020-01-02 03:04:05', Schema.DisplayType.DateTime);
        System.assertNotEquals(null, dtVal, 'Datetime string should convert');
        System.assertEquals(DateTime.valueOf('2020-01-02 03:04:05'), (DateTime)dtVal, 'Datetime should match exact value');
    }

    @IsTest
    static void testGetRecordOwners_basic() {
        Account acc = [SELECT Id, OwnerId FROM Account LIMIT 1];
        Set<Id> recordIds = new Set<Id>{ acc.Id };

        Map<Id, Id> result = DynamicAgent.getRecordOwners(recordIds);
        System.assertEquals(1, result.size(), 'Should return one mapping');
        System.assertEquals(acc.OwnerId, result.get(acc.Id), 'Owner should match');
    }

    @IsTest
    static void testHelpers_earlyReturns() {
        Test.startTest();
        DynamicAgent.updateUserValidationCounts(null, new Map<Id, List<String>>());
        DynamicAgent.removeUpdatedFieldsFromPayloadBatch(null, null);
        Test.stopTest();

        System.assert(true, 'Early return helpers executed without errors');
    }
}