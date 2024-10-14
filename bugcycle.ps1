param([string]$queryId)
if ( $queryId -eq "" -or $queryId -eq $null )
{
    write-host "Learn query id is mandatory"
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

# predefined bug and task states.
$bugAndTaskStates = [System.Collections.Generic.Dictionary[string,[System.Collections.Generic.List[String]]]]::new([StringComparer]::OrdinalIgnoreCase)

$bugAndTaskStates.Add("In Progress",@("Replication","RCA","Code fix","Unit test","BDD"));
$bugAndTaskStates.Add("In Review",@("PR review"));
$bugAndTaskStates.Add("Branch testing",@("Branch testing","BDD"));
$bugAndTaskStates.Add("Awaiting DoD",@("DoD"));
$bugAndTaskStates.Add("In testing",@("PMV","Backport"));

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

function Get-RESTAPI($url,$headers)
{
    $attempts = 0;
    $response = $null
    do 
    {
        try {
            $response = Invoke-RestMethod $url -Method 'GET' -Headers $headers -StatusCodeVariable 'statusCode'
            if( $statusCode -ne 200 )
            {
                Write-Host "Could not login using the personal access token provided. Please check the token or recreate it"
                exit;
            }
        } catch{
            $msg = $_.Exception.Message;
            Write-Host "Retrying after exception $msg"
        }
        $attempts += $attempts;
    } while($attempts -lt 5 -and $response -eq $null)
    return $response;
}

#Gets the bugs currently in progress.
function Get-BugsInProgress()
{
    $url = 'https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/wiql/{0}?api-version=5.0' -f $queryId
    write-host $url
    $headers = Create-Headers
    $response = Get-RESTAPI $url $headers
    #Invoke-RestMethod $url -Method 'GET' -Headers $headers -StatusCodeVariable 'statusCode'
    return $response.workItems.id
}

#Gets the REST api response for the method GET with the url passed.
function Get-ApiResponse($url)
{
    $headers = Create-Headers

    $response = Get-RESTAPI $url $headers
    #Invoke-RestMethod $url -Method 'GET' -Headers $headers -StatusCodeVariable 'statusCode'
    return $response;
}

# Gets the ado work item with all its relations
function Get-WorkItem($id)
{
    $url = 'https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/workitems/{0}?api-version=6.0&$expand=relations' -f $id
    $response = Get-ApiResponse $url 
    return $response.fields."System.Title",$response.fields."System.AssignedTo".displayName,$response.fields."System.State",
        $response.relations
}

#Gets the work item versions
function Get-WorkItemUpdates($id)
{
    $url = 'https://dev.azure.com/AnthologyInc-01/Learn/_apis/wit/workitems/{0}/updates?api-version=5.1' -f $id
    $response = Get-ApiResponse $url 
    return $response;
}

function Get-Bug2TaskState($bugState, [System.Collections.Generic.Dictionary[string,string]]$taskStates)
{
    $taskType = $null;
    $states = $bugAndTaskStates[$bugState];
    #write-host $taskStates
    foreach( $val in $states )
    {
        # find the correct task state.
        $currentState = $taskStates[$val];
        #write-host "Task type:$val, Current State:$currentState"
        if( $currentState -eq "In Progress" )
        {
            $taskType = $val;
            break;
        }
    }
    #write-host "Bug state:$bugState, Task type:$taskType"
    return $taskType;
}

#Enumerates all child tasks and derive the duration and transition times.
function Enum-ChildTasks($bugId,$title,$user,$bugState,$relations)
{
    # enum tasks
    $dict = [System.Collections.Generic.Dictionary[string,object]]::new()
    foreach($rel in $relations)
    {
        if($rel.rel -eq "System.LinkTypes.Hierarchy-Forward")
        {
            $child = Split-Path $rel.url -Leaf
            $versions = Get-WorkItemUpdates $child
            # Task goes thru Ready to Start, In Progress and Closed workflow.
            $tag = $versions.value.fields."System.Tags".newValue
            $tag = if( $tag -is [Array] ) {$tag[1]} else {$tag}
            #write-host "Tag :'$tag'"
            # task could be cancelled.
            if( $tag -ne "" -and $tag -ne $null )
            {
                $tag = $tag.Trim();
                $ret1 = $dict.Add($tag, $versions);
            }
        }
    }
    if( $dict.Count -gt 0 )
    {
        $tasksList = [System.Collections.ArrayList]::new()
        $taskStates = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        #write-host $dict
        foreach( $type in $task_types)
        {
            $value = $dict[$type];
            #write-host "Type :$type, Value:$value"

            $numOfAttempts,$timeTaken,$state,$workflow = Calc-CycleTime $value
            $taskItem = @{
                Type = $type
                Attempts = $numOfAttempts
                TotalTime = $timeTaken
                State = $state
                Workflow = $workflow
            }
            $ret = $tasksList.Add($taskItem);
            $ret = $taskStates.Add($type,$state);
        }
        # check bug state with task state.
        $tasktype = Get-Bug2TaskState $bugState $taskStates
        $mismatch = $bugState -ne "Closed" -and ($taskType -eq $null -or $taskType -eq "")
        $bug = @{
            Id = $bugId
            Title = $title
            AssignedTo = $user
            State = $bugState
            StateMismatch = $mismatch
            MatchingTaskType = $taskType
            Tasks = $tasksList.ToArray()
        }
        $ret = $bugsList.Add($bug)
    }
}

function Get-TimeDiff($start, $end)
{
    # assume morning 9 AM to 7 PM.
    $totalTime = $null
    for($d = $start.Date;$d -le $end;$d = $d.AddDays(1))
    {
        $dow = $d.DayOfWeek
        $dt = $d.ToString("yyyy-MM-dd")
        $startTime = Get-Date -Date "$dt 09:00:00"
        $endTime = Get-Date -Date "$dt 19:00:00"
        if ($dow -notmatch "Sunday|Saturday") 
        {
            $diff = $null
            $s = $null; $e = $null;

            if( $d.Date -eq $start.Date )
            {
                $diff = New-TimeSpan -End $endTime -Start $start
            }
            elseif( $d.Date -eq $end.Date )
            {
                $diff = New-TimeSpan -End $end -Start $startTime
            }
            else 
            {
                $diff = New-TimeSpan -End $endTime -Start $startTime
            }
            
            $totalTime += $diff.Duration()
        }
    }
    return $totalTime;
}

function Calc-CycleTime($json)
{
    # test from json file.
    #$jsonFile = "./content.json"
    #$json = Get-Content $jsonFile | Out-String | ConvertFrom-Json
    $values = $json.value;
    $sb = $null;

    # In Progress -> Closed.
    $startDate = $null; $closedDate = $null; $total = $null; $numOfAttempts = 0; $lastState = $null;
    $readyToStartDate = $null;
    for($i = 0; $i -le $json.count; $i++)
    {
        $content = $values | Where-Object id -eq $i
        $state = $content.fields."System.State".newValue
        
        if ( $state -ne "" -and $state -ne $null )
        {
            if( $i -ne 0 -and $sb -ne $null )
            {
                $sb += " -> ";
            }
            $sb += $state;

            $dt = $content.fields."System.ChangedDate".newValue
            if($state -eq "Ready to Start")
            {
                $readyToStartDate = $dt;
            }
            elseif($state -eq "In Progress")
            {
                $startDate = $dt;
            }
            elseif($startDate -ne $null -and ($state -eq "Closed" -or $state -eq "Ready to Start"))
            {
                $closedDate = $dt;
                $numOfAttempts = $numOfAttempts + 1;

                if ($startDate -ne $null )
                {
                    $diff = Get-TimeDiff $startDate.ToLocalTime() $closedDate.ToLocalTime()
                    $total = $total + $diff;
                    $startDate = $null;
                    $closedDate = $null;
                }
            }
            $lastState = $state;
        }
    }
    if($startDate -ne $null -and $readyToStartDate -ne $null)
    {
        $diff = Get-TimeDiff $readyToStartDate.ToLocalTime() $startDate.ToLocalTime()
        $total = $total + $diff;
    }
    #Write-Host "Workflow: $sb"
    return $numOfAttempts,$total,$lastState,$sb
}

#global list to store bugs
$bugsList = [System.Collections.ArrayList]::new()
$closedBugs = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)

if( Test-Path 'Tasks.json' )
{
    $jsonArray = Get-Content -Raw 'Tasks.json' | ConvertFrom-Json #-AsHashtable
    foreach( $entry in $jsonArray )
    {
        if($entry.State -eq "Closed" )
        {
            $tasksList = [System.Collections.ArrayList]::new()
            foreach( $task in $entry.Tasks )
            {
                $taskItem = @{
                    Type = $task.Type
                    Attempts = $task.Attempts
                    TotalTime = $task.TotalTime
                    State = $task.State
                    Workflow = $task.Workflow
                }
                $ret = $tasksList.Add($taskItem);
                #write-host $taskItem
            }

            $bug = @{
                Id = $entry.Id
                Title = $entry.Title
                AssignedTo = $entry.AssignedTo
                State = $entry.State
                StateMismatch = $entry.StateMismatch
                MatchingTaskType = $entry.MatchingTaskType
                Tasks = $tasksList.ToArray()
            }
            $closedBugs.Add($entry.Id,$bug);
            #write-host $bug
        }
    }
}

try
{
    $wids = Get-BugsInProgress
    #$wids = @("2398093") # 2158194
    write-host "Total Bugs:" $wids.Length
    $count = 0

    foreach( $id in $wids )
    {
        if($closedBugs.ContainsKey($id))
        {
            $bug = $closedBugs[$id]
            Write-Host "$count - Bug $id, Skipping it..."
            $ret = $bugsList.Add($bug)
        }
        else
        {
            $title,$user,$state,$relations = Get-WorkItem $id
            if($relations -ne $null)
            {
                Write-Host "$count - Bug $id, State:$state, Title:$title"
                Enum-ChildTasks $id $title $user $state $relations
            }
        }
        $count += 1;
    }
    $json = $bugsList | ConvertTo-Json -Depth 15
    $json | Out-File -FilePath 'Tasks.json'
    #Write-Host $json
}
catch {
    Write-Host "StatusCode:" $_.Exception
}
