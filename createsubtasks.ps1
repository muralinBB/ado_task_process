param([string]$parentid,
    [string]$productType)

if ( $parentid -eq "" -or $parentid -eq $null )
{
    write-host "Parent bug id must be provided as one of the arguments"
    write-host "Usage: ./createsubtasks.ps1 [bug id] [product type]"
    exit;
}
if ( $productType -eq "" -or $productType -eq $null )
{
    write-host "Learn product type should be one of the following values: API,Microservices,Mobile,Original,Ultra"
    exit;
}

$task_types = @(
    "Replication",
    "RCA",
    "Code fix",
    "Unit test",
    "BDD",
    "PR review",
    "Branch testing",
    "DoD",
    "PMV",
    "Backport"
)

$valid_productTypes = @(
    "API",
    "Microservices",
    "Mobile",
    "Original",
    "Ultra"
)

if( [System.Array]::IndexOf($valid_productTypes,$productType) -eq -1 )
{
    write-host "Error: Learn product type should be one of the following values: API,Microservices,Mobile,Original,Ultra"
    exit;
}

# Personal Access Token
$PAT = ""; # enter personal access token here.

if($PAT -eq "" -or $PAT -eq $null )
{
    write-host "Please create your personal access token for ADO and copy it into the script"
    exit;
}
$base64Token = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":" + $PAT));


# create http headers
function Create-Headers()
{
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Basic "+ $base64Token)
    $headers.Add("User-Agent", "Learn Task Creator")
    $headers.Add("Accept", "application/json")
    return $headers;
}

# Gets the ado work item with all its relations
function Get-WorkItem($id)
{
    $headers = Create-Headers

    $url = 'https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/workitems/{0}?api-version=6.0&$expand=relations' -f $id
    $response = Invoke-RestMethod $url -Method 'GET' -Headers $headers -StatusCodeVariable 'statusCode'
    Write-Host "Status:$statusCode"
    if( $statusCode -ne 200 )
    {
        Write-Host "Could not login using the personal access token provided. Please check the token or recreate it"
        exit;
    }
    return $response.id,$response.fields."System.Title",$response.url,$response.fields."System.AreaPath",$response.fields."System.AssignedTo".displayName
}

function Get-WorkItem-ByWiql($title)
{
    $id = ""
    $headers = Create-Headers
    $headers.Add("Content-Type", "application/json")

    $url = "https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/wiql?api-version=6.0"
    $title = $title.Replace("'","''").Replace('"','""');
    $body = "
    {
        `"query`": `"Select [System.Id] From WorkItems where [System.WorkItemType] = 'Task' and [System.State] <> 'Cancelled' and [System.Title] = '$title'`"
    }
    "
    #write-host $body
    $response = Invoke-RestMethod $url -Method 'POST' -Headers $headers -Body $body
    if($response)
    {
        if( $response.workItems.Length -gt 0)
        {
            $id = $response.workItems[0].id;
        }
    }
    return $id
}

# updates the task details.
function Update-SubTasks($workItemId,$areaPath,$userId)
{
    $headers = Create-Headers
    $headers.Add("Content-Type", "application/json-patch+json")
    $body = "
    [
        {
            `"op`": `"add`",
            `"path`": `"/fields/System.AreaPath`",
            `"from`": null,
            `"value`": `"$areaPath`"
        },
        {
            `"op`": `"add`",
            `"path`": `"/fields/System.AssignedTo`",
            `"from`": null,
            `"value`": `"$userId`"
        }
    ]
    "
    $url = 'https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/workitems/{0}?api-version=7.2-preview.3' -f $workItemId
    #Write-Host "Id:$workItemId, Url for patch: $url, $body"
    $response = Invoke-RestMethod $url -Method 'PATCH' -Headers $headers -Body $body
}

#creates all tasks under a bug, the tasks are prefixed with the types from the array.
function Create-SubTasks($title,$url,$areaPath,$userId)
{
    $headers = Create-Headers
    $headers.Add("Content-Type", "application/json-patch+json")
    $areaPath = $areaPath.Replace('\','\\');
 
    foreach($item in $task_types)
    {
        write-host "Creating task for $item, checking if the task already exists."
        $new_title = '{0} - {1}' -f $item, $title
        $child = Get-WorkItem-ByWiql $new_title
        if( $child -and $child -ne "" )
        {
            Write-Host "Child task $child already exists, updating area path and assigned to"
            Update-SubTasks $child $areaPath $userId
        }
        else
        {
            Write-Host "Creating a new task for $new_title"
            $body = "
            [
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/System.Title`",
                    `"from`": null,
                    `"value`": `"$new_title`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/Custom.LearnProductType`",
                    `"from`": null,
                    `"value`": `"$productType`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/System.Description`",
                    `"from`": null,
                    `"value`": `"$new_title`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/System.State`",
                    `"from`": null,
                    `"value`": `"Ready to Start`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/System.AreaPath`",
                    `"from`": null,
                    `"value`": `"$areaPath`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/System.AssignedTo`",
                    `"from`": null,
                    `"value`": `"$userId`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/Microsoft.VSTS.Scheduling.OriginalEstimate`",
                    `"from`": null,
                    `"value`": `"1`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/Microsoft.VSTS.Scheduling.RemainingWork`",
                    `"from`": null,
                    `"value`": `"1`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/fields/System.Tags`",
                    `"from`": null,
                    `"value`": `"$item`"
                },
                {
                    `"op`": `"add`",
                    `"path`": `"/relations/-`",
                    `"value`": {
                    `"rel`": `"System.LinkTypes.Hierarchy-Reverse`",
                    `"url`": `"$url`"
                    }
                }
            ]
            "
            #Write-Host $body
            $response = Invoke-RestMethod 'https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/workitems/$Task?api-version=7.2-preview.3' -Method 'POST' -Headers $headers -Body $body
        }
        # $response | ConvertTo-Json
    }
}


try
{
    $id,$title,$url,$areaPath,$userId = Get-WorkItem $parentid
    if($url -and $url -ne "")
    {
        Write-Host "Found parent bug url :$url"
        Create-SubTasks $title $url $areaPath $userId
    }
    else
    {
        Write-Host "Work item could not be fetched for id $parentid"
    }
}
catch {
    Write-Host "StatusCode:" $_.Exception
}
