let
    Source = DWSFTIES_API.Contents("AL", "Inventory"),
    data = Source{[Name="inventory/water-system"]}[Data]
in
    data
