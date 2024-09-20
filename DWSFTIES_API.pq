// This file contains your Data Connector logic
[Version = "1.0.0"]
section DWSFTIES_API;

AuthorizeUrl = "https://dwsfties-uat-api.epa.gov/api/auth/realms/sdwismod/protocol/openid-connect/token";
BaseUrl = "https://dwsfties-uat-api.epa.gov:443/api/db";

/*This function is called once by the CreatePostgRESTTable or CreateMicroserviceTable for each endpoint selected in the Navigation table*/
/*The required and optional parameters are defined in the API_ImplType, which are then passed to the API_Impl function*/
DWSFTIES_API.Feed = Value.ReplaceType(API_Impl, API_ImplType);

/**********************************************/
/*Entry point for connector*/
/*The API_NavType defines the parameters collected when the connector first opens (e.g., primacyCode, API)
/and then passes that information to to the API_NavTable function to prepare the Navigation Table*/
/**********************************************/
[DataSource.Kind="DWSFTIES_API", Publish = "DWSFTIES_API.Publish"]
shared DWSFTIES_API.Contents = Value.ReplaceType(API_NavTable, API_NavType);

/*This types defines the parameters passed from the API_NavTable function for ech endpoint in the API selected*/
API_ImplType = type function (
        url as text,         
        bigPC as text,
        requestType as text,
        optional littlePC as text
    ) 
    as any;

/*This type defines the parameters collected when the connector launches.  These values are passed to to the API_NavTable function*/
API_NavType = type function (
        primacyCode as (type text meta [
                Documentation.FieldCaption = "Enter 2-Digit primacy code (e.g., AL, GA, FL)"
        ]),
        apiRecord as (type text meta [
                Documentation.FieldCaption = "Select an API from the List",
                Documentation.AllowedValues ={
                "PostgREST", "System Administration", "Legal Entity", "Inventory", "Reporting"
            }  
        ])
    ) as table meta [
        Documentation.Name = "DWSFTIES API Navigator"
    ];

/*This function takes the parameters defined in the API_ImplType and creates a datatable for each with the data for each url*/
API_Impl = (url as text, bigPC as text, requestType as text, optional littlePC as text) => 
    let 
        Username = Extension.CurrentCredential()[Username],         //Get the username entered during the Enter Credentials step of the connector
        Password = Extension.CurrentCredential()[Password],         //Gets the password entered during the Enter Credentials step of the connector
        Token = GetToken(Username, Password, bigPC),                //Retrieves a token to be used in each call to the API
        LittlePC = littlePC,    

        /*Sets the request headers based on the API selected*/                                    
        headers = 
            if requestType = "postgrest"
                then [
                    #"accept" = "application/json",
                    #"Range-Unit" = "items",
                    #"Authorization" = "Bearer " & Token,
                    #"Accept-Profile" = "dwp_" & LittlePC
                ]
            else if requestType = "microservice"
                then [
                    #"accept" = "application/json",
                    #"Authorization" = "Bearer " & Token
                ]
            else "",
        //Url = url,
        Url = 
            if requestType = "postgrest"
                then url
                else GetUrlWithPageSize(url, bigPC, Token),
        // define possible errors
        errors.badRequest = Record.AddField(Error.Record("Bad Request", "this dataset does not exist. It's most likely a misspelled parameter. Double check the spelling of the geography and variables you're passing as parameters."), "Status", 400),
        errors.invalidAccessKey = Record.AddField(Error.Record("Invalid Access Key", "Make sure the provided access exists and is entered correctly."), "Status", 401),
        errors.insufficientPermissions = Record.AddField(Error.Record("Insufficient Permissions", "you don't have the right permissions to access this dataset."), "Status", 403),
        errors.resourceNotFound = Record.AddField(Error.Record("Page Does Not Exist", "this dataset does not exist. It's most likely a misspelling somewhere in the URL. Double check the URL and make sure it's spelled correctly."), "Status", 404),
        errors.tooManyRequests = Record.AddField(Error.Record("Too Many Requests", "you've reached your daily limit. Come back in 24 hours and try again."), "Status", 429),
        errors.backendError = Record.AddField(Error.Record("Server Error", "there is an unknown server error preventing this request from being executed. You've done nothing wrong. Just try again in a bit."), "Status", 500),
        errors.serviceUnavailable = Record.AddField(Error.Record("Service Unavailable", "the server is too busy right now and needs a short break. Don't worry, you can try again in a bit."), "Status", 503),
        // build an error table
        errors.table = Table.FromRecords({errors.badRequest, errors.invalidAccessKey, errors.insufficientPermissions, errors.resourceNotFound, errors.tooManyRequests, errors.backendError, errors.serviceUnavailable}),
        // get response
        response = Web.Contents(
            Url,
            [
                Headers = headers,
                ManualStatusHandling = {400, 401, 403, 404, 429, 500, 503}
            ]
        ),
        responseMetadata = Value.Metadata(response),
        responseCode = responseMetadata[Response.Status],
        responseHeaders = responseMetadata[Headers],
        jsonResponse = 
            if responseCode <> 200
                then error errors.table{List.PositionOf(errors.table[Status],responseCode)}
                else Json.Document(response)
    in
        jsonResponse;

/*This function produces the navigation table based on the API selected using the API specification json located at each URL*/
API_NavTable = (primacyCode as text, apiRecord as text) as any =>
    let
        littlePC = Text.Lower(primacyCode),
        bigPC = Text.Upper(primacyCode),

        /*Get specifications from API specific URL*/
        specs = 
            if apiRecord = "PostgREST"
                then Json.Document(Web.Contents("https://dwsfties-uat-api.epa.gov/api/db/rpc/get_dwsfties_spec"))
            else if apiRecord = "System Administration"
                then Json.Document(Web.Contents("https://sysadmin.dwsfties-uat-api.epa.gov/api-docs"))
            else if apiRecord = "Legal Entity"
                then Json.Document(Web.Contents("https://legalentity.dwsfties-uat-api.epa.gov/api-docs"))
            else if apiRecord = "Inventory"
                then Json.Document(Web.Contents("https://inventory.dwsfties-uat-api.epa.gov/api-docs"))
            else if apiRecord = "Reporting"
                then Json.Document(Web.Contents("https://dwsfties-uat-api.epa.gov/api/db/rpc/get_reporting_spec"))
            else "",
        //Get endpoints from spec
        allEnds = specs[paths],
        //Convert endpoints to Table
        response = Record.ToTable(allEnds),
        //Extract paths from the Table
        pathsOnly = Table.RemoveColumns(response,{"Value"}),


        /**************************************************/
        /*The purpose of the following group of steps is to create a table that feeds into Microsoft's ToNavigationTable Helper function*/
        //Rename the path column from "Name" to "Path"
        source = Table.RenameColumns(pathsOnly, {{"Name","Path"}}),
        //Add a column named Name and fill up with values from the Path column with the "/" removed
        source2 = Table.AddColumn(source, "Name", each Text.RemoveRange([Path],0,1)),
        //Remove the Path Column
        source3 = Table.RemoveColumns(source2, {"Path"}),
        //Select all rows that do not ask for parameters, such as {id}.
        source4 = Table.SelectRows(source3, each not Text.Contains([Name],"{")),
        //Based on the API selected, Add a column called Data that is made up of the resulting data for each endpoint in the table
        source5 = if apiRecord = "PostgREST"
                    then Table.AddColumn(source4, "Data", each GetPostgRESTTable([Name], bigPC, littlePC))  //This is called once per row for each PostgREST endpoint
                else if apiRecord = "Reporting"
                    then Table.AddColumn(source4, "Data", each GetPostgRESTTable([Name], bigPC, littlePC))  //This is called once per row for each endpoint Reporting endpoint
                else Table.AddColumn(source4, "Data", each GetMicroserviceTable(apiRecord, [Name], bigPC)), //This is called once per row for each endpoint Microservice endpoint
        //Reorder columns*/
        source6 = Table.ReorderColumns(source5, {"Name","Data"}),
        //Add requried columsn for the ToNavigatinoTable Function
        source7 = Table.AddColumn(source6, "ItemKind", each "Table"),
        source8 = Table.AddColumn(source7, "ItemName", each "Table"),
        source9 = Table.AddColumn(source8, "IsLeaf", each true),
        /***************************************************/

        //Pass the resulting table to the ToNavigationTable function.  This function is provided by Microsoft here: https://learn.microsoft.com/en-us/power-query/helper-functions
        navTable = Table.ToNavigationTable(source9, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable;

GetPostgRESTTable = (url as text, bigPC as text, littlePC as text) as any => 
    let
        Url = BaseUrl & "/" & url,
        Source = DWSFTIES_API.Feed(Url, bigPC, "postgrest", littlePC),   //Get the JSON Response from the API
        /*********************************/
        //The JSON response returns a list of objects.  The following transformations
        //converts this response into a Table with headers based on the properties.
        
        table =  Table.FromList(Source, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        firstRecord = table{0}[Column1],
        nameTable = Record.ToTable(firstRecord),
        nameList = nameTable[Name],
        expandedTable = Table.ExpandRecordColumn(table,"Column1",nameList,nameList)
    in
        expandedTable;  //The created table populated the Data column of the Table being created to pass to the ToNavigationTable function

GetMicroserviceTable = (apiRecord as text, url as text, bigPC as text) as any => 
    let
        MicroserviceBaseUrl = 
            if apiRecord = "System Administration"
                then "https://sysadmin.dwsfties-uat-api.epa.gov"
            else if apiRecord = "Legal Entity"
                then "https://legalentity.dwsfties-uat-api.epa.gov"
            else if apiRecord = "Inventory"
                then "https://inventory.dwsfties-uat-api.epa.gov"
            else "",
        Url = MicroserviceBaseUrl & "/" & url,
        Source = DWSFTIES_API.Feed(Url, bigPC, "microservice"),
        table = Record.ToTable(Source),
        value = table{Table.RowCount(table)-1}[Value],
        newTable = Table.FromList(value, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        firstRecord = newTable{0}[Column1],
        nameTable = Record.ToTable(firstRecord),
        nameList = nameTable[Name],
        expandedTable = Table.ExpandRecordColumn(newTable,"Column1",nameList,nameList)
    in
        expandedTable;

/*For the CreateMicroserviceTable function, this function gets the total records*/
GetUrlWithPageSize = (url as text, bigPC as text, token as text) as text=> 
    let 
        Token = token,
        /*Sets the request headers based on the API selected*/                                    
        headers = 
            [
                #"accept" = "application/json",
                #"Authorization" = "Bearer " & Token
            ],
        Url = url,
        response = Web.Contents(
            Url,
            [
                Headers = headers
            ]
        ),
        jsonResponse=Json.Document(response),
        resultSummary = 
            if Record.HasFields(jsonResponse,"resultSummary")
                then  Record.FieldValues(Record.SelectFields(jsonResponse,"resultSummary")){0}
                else null,
        totalRecords = 
            if resultSummary is null 
                then 0
                else Record.FieldValues(Record.SelectFields(resultSummary,"totalRecords")){0},
        UpdatedUrl =
            if totalRecords > 0
                then Url & "?pageSize=" & Number.ToText(totalRecords)
                else Url
    in
        UpdatedUrl;

/*This function retrieves an authentication token to use in the API calls*/
GetToken = (u as text, p as text, bigPC as text) => 
    let
        Username = u,
        Password = p,
        BigPC = bigPC,
        DefaultRequestHeaders = [
            #"Content-Type" = "application/x-www-form-urlencoded",
            #"currentPartnerId" = BigPC,
            #"Cache-Control" = "no-cache",
            #"Origin" = "https://dwsfties-uat.epa.gov"
        ],
        PostData = [
            #"scope" = "openid",
            #"grant_type" = "password",
            #"username" = Username & "~" & Password,
            #"password" = Username & "~" & Password,
            #"client_id" = "newClient",
            #"client_secret" = "xxxxxxxx"
        ],
        postData = Text.ToBinary(Uri.BuildQueryString(PostData)),
        authorization = Web.Contents(
            AuthorizeUrl,
            [
                Headers = DefaultRequestHeaders,
                Content = postData
            ]
        ),
        authorizationJson = Json.Document(authorization),
        token = Record.Field(authorizationJson,"access_token")
    in
        token;


// Data Source Authentication Description //
/*Currently, Basic Authentication is what the API supports to get a token*/
DWSFTIES_API = [
    Authentication = [
        UsernamePassword = []
    ]
];

// Data Source UI publishing description
DWSFTIES_API.Publish = [
    Beta = false,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = DWSFTIES_API.Icons,
    SourceTypeImage = DWSFTIES_API.Icons
];

//Custom icons were created for the connector using the DW-SFTIES Logo//
DWSFTIES_API.Icons = [
    Icon16 = { Extension.Contents("DWSFTIES_API16.png"), Extension.Contents("DWSFTIES_API20.png"), Extension.Contents("DWSFTIES_API24.png"), Extension.Contents("DWSFTIES_API32.png") },
    Icon32 = { Extension.Contents("DWSFTIES_API32.png"), Extension.Contents("DWSFTIES_API40.png"), Extension.Contents("DWSFTIES_API48.png"), Extension.Contents("DWSFTIES_API64.png") }
];

//Microsoft Helper function that generates the Navigation Table//  
Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table => 
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;