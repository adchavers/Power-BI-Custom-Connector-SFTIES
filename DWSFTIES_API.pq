// This file contains your Data Connector logic
[Version = "1.0.0"]
section DWSFTIES_API;

AuthorizeUrl = "https://dwsfties-uat-api.epa.gov/api/auth/realms/sdwismod/protocol/openid-connect/token";
BaseUrl = "https://dwsfties-uat-api.epa.gov:443/api/db";

DWSFTIES_API.Feed = Value.ReplaceType(API_Impl, API_ImplType);

[DataSource.Kind="DWSFTIES_API", Publish = "DWSFTIES_API.Publish"]
shared DWSFTIES_API.Contents = Value.ReplaceType(API_NavTable, API_NavType);

API_ImplType = type function (
        url as text,
        bigPC as text,
        headerStyle as text,
        optional littlePC as text
    ) 
    as any;

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

API_Impl = (url as text, bigPC as text, headerStyle as text, optional littlePC as text) => 
    let 
        Username = Extension.CurrentCredential()[Username],
        Password = Extension.CurrentCredential()[Password],
        Token = GetToken(Username, Password, bigPC), 
        LittlePC = littlePC,
        headers = 
            if headerStyle = "postgrest"
                then [
                    #"accept" = "application/json",
                    #"Range-Unit" = "items",
                    #"Authorization" = "Bearer " & Token,
                    #"Accept-Profile" = "dwp_" & LittlePC
                ]
            else if headerStyle = "microservice"
                then [
                    #"accept" = "application/json",
                    #"Authorization" = "Bearer " & Token
                ]
            else "",
        Url = url,
        response = GetAllPagesByNextLink(url, headers)
        // response = Web.Contents(
        //     Url,
        //     [
        //         Headers = headers
        //     ]
        // ),
    in
        response;

API_NavTable = (primacyCode as text, apiRecord as text) as any =>
    let
        littlePC = Text.Lower(primacyCode),
        bigPC = Text.Upper(primacyCode),
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
        allEnds = specs[paths],
        response = Record.ToTable(allEnds),
        pathsOnly = Table.RemoveColumns(response,{"Value"}),
        source = Table.RenameColumns(pathsOnly, {{"Name","Path"}}),
        source2 = Table.AddColumn(source, "Name", each Text.RemoveRange([Path],0,1)),
        source3 = Table.RemoveColumns(source2, {"Path"}),
        source4 = Table.SelectRows(source3, each not Text.Contains([Name],"{")),
        source5 = if apiRecord = "PostgREST"
                    then Table.AddColumn(source4, "Data", each GetPostgRESTTable([Name], bigPC, littlePC))
                else if apiRecord = "Reporting"
                    then Table.AddColumn(source4, "Data", each GetPostgRESTTable([Name], bigPC, littlePC))
                else Table.AddColumn(source4, "Data", each GetMicroserviceTable(apiRecord, [Name], bigPC)),
        source6 = Table.ReorderColumns(source5, {"Name","Data"}),
        source7 = Table.AddColumn(source6, "ItemKind", each "Table"),
        source8 = Table.AddColumn(source7, "ItemName", each "Table"),
        source9 = Table.AddColumn(source8, "IsLeaf", each true),
        navTable = Table.ToNavigationTable(source9, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable;

GetPostgRESTTable = (url as text, bigPC as text, littlePC as text) as any => 
    let
        Url = BaseUrl & "/" & url,
        Source = DWSFTIES_API.Feed(Url, bigPC, "postgrest", littlePC)
        // table =  Table.FromList(Source, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        // firstRecord = table{0}[Column1],
        // nameTable = Record.ToTable(firstRecord),
        // nameList = nameTable[Name],
        // expandedTable = Table.ExpandRecordColumn(table,"Column1",nameList,nameList)
    in 
        // expandedTable;
        Source;

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
        Source = DWSFTIES_API.Feed(Url, bigPC, "microservice")
        // table = Record.ToTable(Source),
        // value = table{Table.RowCount(table)-1}[Value],
        // newTable = Table.FromList(value, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        // firstRecord = newTable{0}[Column1],
        // nameTable = Record.ToTable(firstRecord),
        // nameList = nameTable[Name],
        // expandedTable = Table.ExpandRecordColumn(newTable,"Column1",nameList,nameList)
    in
        // expandedTable;
        Source;

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


// Data Source Kind description
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

DWSFTIES_API.Icons = [
    Icon16 = { Extension.Contents("DWSFTIES_API16.png"), Extension.Contents("DWSFTIES_API20.png"), Extension.Contents("DWSFTIES_API24.png"), Extension.Contents("DWSFTIES_API32.png") },
    Icon32 = { Extension.Contents("DWSFTIES_API32.png"), Extension.Contents("DWSFTIES_API40.png"), Extension.Contents("DWSFTIES_API48.png"), Extension.Contents("DWSFTIES_API64.png") }
];

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

// The getNextPage function takes a single argument and is expected to return a nullable table
Table.GenerateByPage = (getNextPage as function) as table =>
    let        
        listOfPages = List.Generate(
            () => getNextPage(null),            // get the first page of data
            (lastPage) => lastPage <> null,     // stop when the function returns null
            (lastPage) => getNextPage(lastPage) // pass the previous page to the next function call
        ),
        // concatenate the pages together
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        // if we didn't get back any pages of data, return an empty table
        // otherwise set the table type based on the columns of the first page
        if (firstRow = null) then
            Table.FromRows({})
    // check for empty first table
        else if (Table.IsEmpty(firstRow[Column1])) then
            firstRow[Column1]
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );

// Read all pages of data.
// After every page, we check the "NextLink" record on the metadata of the previous request.
// Table.GenerateByPage will keep asking for more pages until we return null.
GetAllPagesByNextLink = (url as text, headers as any) as table =>
    Table.GenerateByPage((previous) => 
        let
            // if previous is null, then this is our first page of data
            nextLink = if (previous = null) then url else Value.Metadata(previous)[NextLink]?,
            // if NextLink was set to null by the previous call, we know we have no more data
            page = if (nextLink <> null) then GetPage(nextLink, headers) else null
        in
            page
    );


GetPage = (url as text, headers as any) as any =>
    let
        response = Web.Contents(url, [ Headers = headers ]),     
        body = Json.Document(response),
        nextLink = GetNextLink(body),
        table = Record.ToTable(body),
        value = table{Table.RowCount(table)-1}[Value],
        newTable = Table.FromList(value, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        firstRecord = newTable{0}[Column1],
        nameTable = Record.ToTable(firstRecord),
        nameList = nameTable[Name],
        data = Table.ExpandRecordColumn(newTable,"Column1",nameList,nameList)
    in
        data meta [NextLink = nextLink];

// In this implementation, 'response' will be the parsed body of the response after the call to Json.Document.
// Look for the '@odata.nextLink' field and simply return null if it doesn't exist.
GetNextLink = (response) as nullable text => Record.FieldOrDefault(response, "@odata.nextLink");