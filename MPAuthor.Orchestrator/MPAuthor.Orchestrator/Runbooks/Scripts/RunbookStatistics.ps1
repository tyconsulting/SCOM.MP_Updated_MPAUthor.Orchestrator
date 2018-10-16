param($webServer, $debug)

$SCRIPT_NAME = 'RunbookStatistics.ps1'

$EVENT_LEVEL_ERROR 		= 1
$VENT_LEVEL_WARNING 	= 2
$EVENT_LEVEL_INFO 		= 4

# Constants
# Web service returns max of 50 resource records per page
[int] $c_RecordsPerPage = 50

function Get-OrchestratorServiceUrl
{
    ######################################################################################################################
    # Get-OrchestratorServiceUrl
    #
    # Create a complete URL for the Orchestrator web service.
    #
    # Usage:
    #   Get-OrchestratorServiceUrl -Server <string> [-Port <string>] [-Version <string>] [-Query <string>] [-UseSSL]
    ######################################################################################################################

    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [String] $Server,
        
        [Parameter(Mandatory=$false)]
        [String] $Port = "81",
                
        [Parameter(Mandatory=$false)]
        [String] $Version = "Orchestrator2012", 
        
        [Parameter(Mandatory=$false)]
        [String] $Query = "",
        
        [Parameter(Mandatory=$false)]
        [Switch] $UseSSL
    )
    
    #determine the protocol
    $protocol = $( if ($UseSSL) {"https"} else {"http"} )
        
    if ($Query -ne "")
    {
        #assure $Query doesn't start with /
        $Query = $Query.Trim()
        if ($Query.StartsWith('/') -or $Query.StartsWith('\')) {$Query = $Query.Substring(1)} 
    }

    return -join ($protocol,"://",$Server,":",$Port,"/",$Version,"/Orchestrator.svc/",$Query)
}


function Get-OrchestratorJob
{
    ######################################################################################################################
    # Get-OrchestratorJob
    #
    # Get a Job or collection of Jobs.
    # Each Job is a custom PS object that represents a Job entity.
    #
    # Usage:
    #   Get-OrchestratorJob -ServiceUrl <string> [-JobId <guid>] [-Page <int>] [-MaxPages <int>] [-Credentials <credential>]
    #   Get-OrchestratorJob -ServiceUrl <string> [-ServerId <guid>] [-Status <csv string>] [-Page <int>] [-MaxPages <int>] [-Credentials <credential>]
    #   Get-OrchestratorJob -ServiceUrl <string> [-RunbookId <guid>] [-Status <csv string>] [-Page <int>] [-MaxPages <int>] [-Credentials <credential>]
    #   Get-OrchestratorJob -ServiceUrl <string> [-Status <csv string>] [-Page <int>] [-MaxPages <int>] [-Credentials <credential>]
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [String] $ServiceUrl,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials,
            
            [Parameter(Mandatory=$false)]
            [System.Guid] $JobId,
            
            [Parameter(Mandatory=$false)]
            [System.Guid] $RunbookId,
            
            [Parameter(Mandatory=$false)]
            [System.Guid] $ServerId,
            
            [Parameter(Mandatory=$false)]
            [String] $Status,
            
            [Parameter(Mandatory=$false)]
            [Int] $Page = 0,
            
            [Parameter(Mandatory=$false)]
            [Int] $MaxPages = 10
    )
    
    # Create the Status part of the query
    $statusquery = ""
    if (-not [string]::IsNullOrEmpty($Status)) {
        $temparray = $Status -split ","
        
        for ($i = 0; $i -lt $temparray.Count; $i++) {
            if ($i -gt 0) { $statusquery += "%20or%20"}
            $statusquery += "Status%20eq%20'" + $temparray[$i] + "'"
        }
    }
  
    # Create the full query
    if ($JobId -ne $null)
    {
        # get a specific Job
        $query = -join ("Jobs(guid'",$JobId.ToString(),"')")
    }
    elseif ($ServerId -ne $null)
    {
        # get all Jobs on a specific runbook server [with specific status]
        $query = -join ("Jobs()?`$filter=RunbookServerId%20eq%20guid'",$ServerId.ToString(),"'")
        if (-not [string]::IsNullOrEmpty($statusquery)) {
            $query = -join ($query,"%20and%20(",$statusquery,")")
        }
    }
    elseif ($RunbookId -ne $null)
    {
        # get all Jobs for a specific runbook [with specific status]
        $query = -join ("Jobs()?`$filter=RunbookId%20eq%20guid'",$RunbookId.ToString(),"'")
        if (-not [string]::IsNullOrEmpty($statusquery)) {
            $query = -join ($query,"%20and%20(",$statusquery,")")
        }
    }
    else
    {
        # get all Jobs in the system [with specific status]
        $query = "Jobs()"
        if (-not [string]::IsNullOrEmpty($statusquery)) {
            $query = -join ($query,"?`$filter=",$statusquery)
        }
    }

    # Create the full url
    $url = $ServiceUrl + $query

    $jobarray = $null
    if ($Page -eq 0)
    {
        # Get Jobs in all pages up to MaxPages
        for ($pg = 1; $pg -le $MaxPages; $pg++)
        {
            $a = getOrchestratorJobPage -Url $url -Page $pg -Credentials $Credentials
            $jobarray += $a[0]
            $maxjobs = $a[1]

            $lastRecord = $pg * $c_RecordsPerPage
            if ($lastRecord -ge $maxjobs) { break; } # No more jobs to get, so exit the for loop
        }
        
    }
    elseif ($Page -ge 1)
    {
        # Get Jobs in a specific page
        $a = getOrchestratorJobPage -Url $url -Page $Page -Credentials $Credentials
        $jobarray = $a[0]
    }
    
    # Return the array of Job objects
    return $jobarray
}

function getOrchestratorJobPage
{
    ######################################################################################################################
    # getOrchestratorJobPage
    #
    # Get a Job or collection of Jobs for the particular page.
    #
    # Usage:
    #   getOrchestratorJobPage -Url <string> -Page <int> [-Credentials <credential>]
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [String] $Url,
            
            [Parameter(Mandatory=$true)]
            [Int] $Page,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials
    )

    # Is this request for single job?
    [bool] $isSingleJob = $Url.Contains("Jobs(guid")

    if (-not $isSingleJob)
    {
        # Add the page query to the url
        $joinchar = $( if ($Url.EndsWith("Jobs()")) {"?"} else {"&"} )
        $Url = -join ($Url,$joinchar,$(getPageQuery $Page))
    }
    
    # Call the service and get the xml doc with Job information
    [xml] $xmlDoc = sendHttpGetRequest -Url $Url -credentials $Credentials
    
    # How many total jobs are there (all pages)
    $jobscounttotal = $( if ($isSingleJob) {1} else {getResourceCount($xmlDoc)} )
  
    $jobarray = $null
    if ( ((($Page - 1) * $c_RecordsPerPage) -lt $jobscounttotal) -or ($isSingleJob))
    {
        # This page is within range
        
        # Get the collection of Job nodes
        $jobnodes = getEntryNodes $xmlDoc
        
        # Create a custom PSObject for each Job and add each Job to an array
        $jobarray = @()
        foreach ($jobnode in $jobnodes)
        {
            # Create a Job object and add it to the array
            $jobarray += getJobObject -JobNode $jobnode
        }
        if ($jobarray.Length -eq 0) { $jobarray = $null }
    }
    
    # Return the array of Job objects and the count of total Job objects possible for all pages
    return @($jobarray,$jobscounttotal)
}

function getJobObject
{
    ##############################################################################
    # getJobObject
    #
    # From an "entry" node for a Job construct a PS custom object
    ##############################################################################
    
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement] $JobNode
    )
    
    # Get the links to related entities
    $servicebaseurl = getBaseServiceUrl $JobNode
    $linknodes = $JobNode.link
    foreach ($linknode in $linknodes)
    {
        switch($linknode.title)
        {
            "Runbook" {$runbookurl = $servicebaseurl + $linknode.href; break}
            "Instances" {$instancesurl = $servicebaseurl + $linknode.href; break}
            "RunbookServer" {$runbookserverurl = $servicebaseurl + $linknode.href; break}
        }
    }
    
    # Get the runbook parameters
    try
    {
        $parametersxml = [xml] $JobNode.Item("content").Item("m:properties").Item("d:Parameters").InnerText
        $parameternodes = $parametersxml.Item("Data").SelectNodes("Parameter")
        $parameterarray = @()
        
        foreach($pn in $parameternodes)
        {
            $id = $pn.Item("ID").InnerText
            
            $props = @{
                'Name' = $pn.Item("Name").InnerText
                'Id' = $id.SubString(1,$id.Length - 2)
                'Value' = $pn.Item("Value").InnerText
            }

            $parameterarray += New-Object PSObject -Property $props
        }
    }
    catch
    {
        $parameterarray = $null
    }
    
    # Create the properties
    $propnode = $JobNode.Item("content").Item("m:properties")
    $properties = @{
        'Url_Service' = $servicebaseurl
        'Parameters' = $parameterarray
        'Url_Runbook' = $runbookurl
        'Url_RunbookInstances' = $instancesurl
        'Url_RunbookServer' = $runbookserverurl
        'Url' = $JobNode.id
        'Published' = $JobNode.published
        'Updated' = $JobNode.updated
        'Category' = $JobNode.category.term
        'Id' = $propnode.Item("d:Id").InnerText
        'RunbookId' = $propnode.Item("d:RunbookId").InnerText
        'RunbookServers' = $propnode.Item("d:RunbookServers").InnerText
        'RunbookServerId' = $propnode.Item("d:RunbookServerId").InnerText
        'Status' = $propnode.Item("d:Status").InnerText
        'ParentId' = $propnode.Item("d:ParentId").InnerText
        'ParentIsWaiting' = [bool]$propnode.Item("d:ParentIsWaiting").InnerText
        'CreatedBy' = $propnode.Item("d:CreatedBy").InnerText
        'CreationTime' = $propnode.Item("d:CreationTime").InnerText
        'LastModifiedBy' = $propnode.Item("d:LastModifiedBy").InnerText
        'LastModifiedTime' = $propnode.Item("d:LastModifiedTime").InnerText            
    }

    # Return the Job object
    $jobobject = New-Object PSObject -Property $properties
    return $jobobject
}


function Get-OrchestratorRunbookInstance
{
    ######################################################################################################################
    # Get-OrchestratorRunbookInstance
    #
    # Get a RunbookInstance or collection of RunbookInstance associated with a Job.
    # The RunbookInstance is a custom PS object that represents a RunbookInstance resource.
    #
    # Note: No paging enabled; so get up to 50 instances (the web service limit per page).
    #
    # Usage:
    #   Get-OrchestratorRunbookInstance -Job <PSObject> [-Credentials <credential>]
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [PSObject] $Job,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials
    )

    # Call the service and get the xml doc with RunbookInstance information
    [xml] $xmlDoc = sendHttpGetRequest -url $Job.Url_RunbookInstances -credentials $Credentials
    
    # Get the collection of RunbookInstance nodes
    $instancenodes = getEntryNodes $xmlDoc
    
    if ($instancenodes -ne $null)
    {        
        # Create a custom PSObject for each RunbookInstance and add each to an array
        $instancearray = @()
        foreach ($instancenode in $instancenodes)
        {
            # Create a Job object and add it to the array
            $instancearray += getRunbookInstanceObject -InstanceNode $instancenode
        }
       
        # Return the array of Instance objects
        if ($instancearray.Length -eq 0) { $instancearray = $null }
        return $instancearray
    }
    else
    {
        # There are no Instances
        return $null
    }
}

function getRunbookInstanceObject
{
    ##############################################################################
    # getRunbookInstanceObject
    #
    # From an "entry" node for a RunbookInstance construct a PS custom object
    ##############################################################################
    
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement] $InstanceNode
    )
    
    # Get the links to related entities
    $url_service = getBaseServiceUrl $InstanceNode
    $linknodes = $InstanceNode.link
    foreach ($linknode in $linknodes)
    {
        switch($linknode.title)
        {
            "Runbook" {$url_runbook = $url_service + $linknode.href; break}
            "Job" {$url_job = $url_service + $linknode.href; break}
            "Parameters" {$url_parameters = $url_service + $linknode.href; break}
            "ActivityInstances" {$url_activityinstances = $url_service + $linknode.href; break}
            "RunbookServer" {$url_runbookserver = $url_service + $linknode.href; break}
        }
    }
    
    # Create the properties
    $propnode = $InstanceNode.Item("content").Item("m:properties")
    $properties = @{
        'Url_Service' = $url_service
        'Url_Runbook' = $url_runbook
        'Url_Job' = $url_job
        'Url_Parameters' = $url_parameters
        'Url_ActivityInstances' = $url_activityinstances
        'Url_RunbookServer' = $url_runbookserver
        'Url' = $InstanceNode.id
        'Published' = $InstanceNode.published
        'Updated' = $InstanceNode.updated
        'Category' = $InstanceNode.category.term
        'Id' = $propnode.Item("d:Id").InnerText
        'RunbookId' = $propnode.Item("d:RunbookId").InnerText
        'JobId' = $propnode.Item("d:JobId").InnerText
        'RunbookServerId' = $propnode.Item("d:RunbookServerId").InnerText
        'Status' = $propnode.Item("d:Status").InnerText
        'CreationTime' = $propnode.Item("d:CreationTime").InnerText
        'CompletionTime' = $propnode.Item("d:CompletionTime").InnerText            
    }

    # Return the Instance object
    $instanceobject = New-Object PSObject -Property $properties
    return $instanceobject
}


function Get-OrchestratorRunbookInstanceParameter
{
    ######################################################################################################################
    # Get-OrchestratorRunbookInstanceParameter
    #
    # Get a RunbookInstanceParameter or collection of RunbookInstanceParameter associated with a RunbookInstance.
    # The RunbookInstanceParameter is a custom PS object that represents a RunbookInstanceParameter resource.
    #
    # Usage:
    #   Get-OrchestratorRunbookInstanceParameter -RunbookInstance <PSObject> [-Credentials <credential>]
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [PSObject] $RunbookInstance,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials
    )

    # Call the service and get the xml doc with RunbookInstance information
    [xml] $xmlDoc = sendHttpGetRequest -url $RunbookInstance.Url_Parameters -credentials $Credentials
    
    # Get the collection of RunbookInstanceParameter nodes
    $paramnodes = getEntryNodes $xmlDoc
    
    if ($paramnodes -ne $null)
    {        
        # Create a custom PSObject for each RunbookInstance and add each to an array
        $paramarray = @()
        foreach ($paramnode in $paramnodes)
        {
            # Create a Job object and add it to the array
            $paramarray += getRunbookInstanceParameterObject -InstanceParameterNode $paramnode
        }
       
        # Return the array of RunbookInstanceParameter objects
        if ($paramarray.Length -eq 0) { $paramarray = $null }
        return $paramarray
    }
    else
    {
        # There are no RunbookInstanceParameter
        return $null
    }
}

function getRunbookInstanceParameterObject
{
    ##############################################################################
    # getRunbookInstanceParameterObject
    #
    # From an "entry" node for a RunbookInstanceParameter construct a PS custom object
    ##############################################################################
    
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement] $InstanceParameterNode
    )
    
    # Get the links to related entities
    $url_service = getBaseServiceUrl $InstanceParameterNode
    $linknodes = $InstanceParameterNode.link
    foreach ($linknode in $linknodes)
    {
        switch($linknode.title)
        {
            "RunbookInstance" {$url_runbookinstance = $url_service + $linknode.href; break}
            "RunbookParameter" {$url_runbookparameter = $url_service + $linknode.href; break}
        }
    }
    
    # Create the properties
    $propnode = $InstanceParameterNode.Item("content").Item("m:properties")
    $properties = @{
        'Url_Service' = $url_service
        'Url_RunbookInstance' = $url_runbookinstance
        'Url_RunbookParameter' = $url_runbookparameter
        'Url' = $InstanceParameterNode.id
        'Updated' = $InstanceParameterNode.updated
        'Category' = $InstanceParameterNode.category.term
        'Id' = $propnode.Item("d:Id").InnerText
        'RunbookInstanceId' = $propnode.Item("d:RunbookInstanceId").InnerText
        'RunbookParameterId' = $propnode.Item("d:RunbookParameterId").InnerText
        'Name' = $propnode.Item("d:Name").InnerText
        'Value' = $propnode.Item("d:Value").InnerText
        'Direction' = $propnode.Item("d:Direction").InnerText
        'GroupId' = $propnode.Item("d:GroupId").InnerText            
    }

    # Return the Instance object
    $instanceobject = New-Object PSObject -Property $properties
    return $instanceobject
}


function Get-OrchestratorRunbook
{
    ######################################################################################################################
    # Get-OrchestratorRunbook
    #
    # Get a Runbook or collection of Runbooks.
    # Each Runbook is a custom PS object that represents a Runbook entity.
    #
    # Usage:
    #   Get-OrchestratorRunbook -ServiceUrl <string> [-Credentials <credentials>] [-RunbookId <guid>] [-Page <int>] [-MaxPages <int>]
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [String] $ServiceUrl,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials,
            
            [Parameter(Mandatory=$false)]
            [System.Guid] $RunbookId,
            
            [Parameter(Mandatory=$false)]
            [Int] $Page = 0,
            
            [Parameter(Mandatory=$false)]
            [Int] $MaxPages = 10            
    )

    # Is this request for a single runbook?
    [bool] $isSingleRunbook = $($RunbookId -ne $null)
    
    # Form full URL
    if ($isSingleRunbook)
    {
        # Url for a single runbook
        $url = -join ($ServiceUrl,"Runbooks(guid'",$RunbookId.ToString(),"')")
        
        # Page will be 1
        $Page = 1
    }
    else
    {
        # Url for all runbooks
        $url = $ServiceUrl + "Runbooks()"
    }
    
    ### Handle paging
    $rbarray = $null
    if ($Page -eq 0)
    {
        # Get Runbooks in all pages up to MaxPages
        for ($pg = 1; $pg -le $MaxPages; $pg++)
        {
            $a = getOrchestratorRunbookPage -Url $url -Page $pg -Credentials $Credentials
            $rbarray += $a[0]
            $maxrbs = $a[1]

            $lastRecord = $pg * $c_RecordsPerPage
            if ($lastRecord -ge $maxrbs) { break; } # No more jobs to get, so exit the for loop
        } 
    }
    elseif ($Page -ge 1)
    {
        # Get Runbooks in a specific page
        $a = getOrchestratorRunbookPage -Url $url -Page $Page -Credentials $Credentials
        $rbarray = $a[0]
    }
    
    # Return the array of Runbook objects
    return $rbarray
}

function getOrchestratorRunbookPage
{
    ######################################################################################################################
    # getOrchestratorRunbookPage
    #
    # Get a Runbook or collection of Runbooks for a particular page
    #
    # Usage:
    #   getOrchestratorRunbookPage -Url <string> -Page <int> [-Credentials <credentials>]
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [String] $Url,

            [Parameter(Mandatory=$true)]
            [Int] $Page,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials
    )

    # Is this request for single runbook?
    $isSingleRunbook = $Url.Contains("Runbooks(guid")

    if (-not $isSingleRunbook)
    {
        # Add the page query to the url
        $joinchar = $( if ($Url.EndsWith("Runbooks()")) {"?"} else {"&"} )
        $Url = -join ($Url,$joinchar,$(getPageQuery $Page))
    }
    
    # Call the service and get the xml doc with Runbook records
    [xml] $xmlDoc = sendHttpGetRequest -url $Url -credentials $Credentials
    
    # How many total runbooks are there (all pages)
    $rbcounttotal = $( if($isSingleRunbook) {1} else {getResourceCount($xmlDoc)} )

    $rbarray = $null
    if ( ((($Page - 1) * $c_RecordsPerPage) -lt $rbcounttotal) -or $isSingleRunbook )
    {
        # This page is within range
        
        # Get the Runbook nodes
        $rbnodes = getEntryNodes $xmlDoc
        
        # Create a custom PSObject for each Runbook and add each Runbook to an array
        $rbarray = @()
        foreach ($rbnode in $rbnodes)
        {
            # Create a Runbook object and add it to the array
            $rbarray += getRunbookObject $rbnode
        }
        
        if ($rbarray.Length -eq 0) { $rbarray = $null }
    }
    
    # Return the array of Runbook objects and the count of total Runbook objects possible for all pages
    return @($rbarray,$rbcounttotal)
}

function getRunbookObject
{
    ##############################################################################
    # getRunbookObject
    #
    # From an "entry" node for a Runbook construct a PS custom object
    #
    # Usage:
    #   getRunbookObject -RbNode <xmlelement>
    ##############################################################################
    
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement] $RbNode
    )
    
    # Get the links to related entities
    $servicebaseurl = getBaseServiceUrl $RbNode
    $linknodes = $RbNode.link
    foreach ($linknode in $linknodes)
    {
        switch($linknode.title)
        {
            "Folder" {$folderurl = $servicebaseurl + $linknode.href; break}
            "Parameters" {$parametersurl = $servicebaseurl + $linknode.href; break}
            "Activities" {$activitiesurl = $servicebaseurl + $linknode.href; break}
            "Jobs" {$jobsurl = $servicebaseurl + $linknode.href; break}
            "Instances" {$instancesurl = $servicebaseurl + $linknode.href; break}
            "Diagram" {$diagramurl = $servicebaseurl + $linknode.href; break}
        }
    }
    
    # Get the runbook parameters (Name, Id, Type, Description)
    #
    # Call the service to get Parameters info for this runbook
    $pmurl = $parametersurl
    [xml] $xmlDoc = sendHttpGetRequest -url $pmurl

    #
    # Get the Parameter nodes
    $pmnodes = getEntryNodes $xmlDoc
    #
    # If there are parameters then get the info
    if ($pmnodes -ne $null)
    {
        $parameterarray = @()
        foreach($pn in $pmnodes)
        {
            $parameterarray += getRunbookParameterObject $pn
        }
    }
    else
    {
        # No parameters, so set to null
        $parameterarray = $null
    }
    
    $propnode = $RbNode.Item("content").Item("m:properties")
    $properties = @{
        'Url_Service' = $servicebaseurl
        'Parameters' = $parameterarray
        'Url_Folder' = $folderurl
        'Url_Parameters' = $parametersurl
        'Url_Activities' = $activitiesurl
        'Url_Jobs' = $jobsurl
        'Url_Instances' = $instancesurl
        'Url_Diagram' = $diagramurl
        'Url' = $RbNode.id
        'Published' = $RbNode.published
        'Updated' = $RbNode.updated
        'Category' = $RbNode.category.term
        'Name' = $propnode.Item("d:Name").InnerText
        'Id' = $propnode.Item("d:Id").InnerText
        'FolderId' = $propnode.Item("d:FolderId").InnerText
        'Description' = $propnode.Item("d:Description").InnerText
        'CreatedBy' = $propnode.Item("d:CreatedBy").InnerText
        'CreationTime' = $propnode.Item("d:CreationTime").InnerText
        'LastModifiedBy' = $propnode.Item("d:LastModifiedBy").InnerText
        'LastModifiedTime' = $propnode.Item("d:LastModifiedTime").InnerText
        'IsMonitor' = [System.Convert]::ToBoolean($propnode.Item("d:IsMonitor").InnerText)
        'Path' = $propnode.Item("d:Path").InnerText
        'CheckedOutBy' = $propnode.Item("d:CheckedOutBy").InnerText
        'CheckedOutTime' = $propnode.Item("d:CheckedOutTime").InnerText
    }
    
    $rbobject = New-Object PSObject -Property $properties
    return $rbobject
}

function getRunbookParameterObject
{
    ##############################################################################
    # getRunbookParameterObject
    #
    # From an "entry" node for a Runbook Parameter construct a PS custom object
    #
    # Usage:
    #   getRunbookParameterObject -RbParamNode <xmlelement>
    ##############################################################################
    
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement] $RbParamNode
    )
    
    # Get the links to related entities
    $servicebaseurl = getBaseServiceUrl $RbParamNode
    $linknodes = $RbParamNode.link
    foreach ($linknode in $linknodes)
    {
        switch($linknode.title)
        {
            "Runbook" {$runbookurl = $servicebaseurl + $linknode.href; break}
            "Instances" {$instancesurl = $servicebaseurl + $linknode.href; break}
        }
    }
        
    # Create the properties
    $properties = @{
        'RunbookUrl' = $runbookurl
        'InstancesUrl' = $instancesurl
        'Url' = $RbParamNode.id
        'Updated' = $RbParamNode.updated
        'Category' = $RbParamNode.category.term
        'Id' = $RbParamNode.Item("content").Item("m:properties").Item("d:Id").InnerText
        'RunbookId' = $RbParamNode.Item("content").Item("m:properties").Item("d:RunbookId").InnerText
        'Name' = $RbParamNode.Item("content").Item("m:properties").Item("d:Name").InnerText
        'Type' = $RbParamNode.Item("content").Item("m:properties").Item("d:Type").InnerText
        'Description' = $RbParamNode.Item("content").Item("m:properties").Item("d:Description").InnerText
        'Direction' = $RbParamNode.Item("content").Item("m:properties").Item("d:Direction").InnerText            
    }

    # Return the RunbookParameter object
    $rbpobject = New-Object PSObject -Property $properties
    return $rbpobject
}


function Stop-OrchestratorJob
{
    ##############################################################################
    # Stop-OrchestratorJob
    #
    # Stop a Job
    #
    # Usage:
    #   Stop-OrchestratorJob -Job <job> [-Credentials <credentials>]
    ##############################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [PSObject] $Job,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials
    )

    process
    {
        # Continue only if the Job is not already stopped
        if (-not ( ($Job.Status -eq "Pending") -or ($Job.Status -eq "Running") ) )
        {
            return $false
        }
    
        #
        # Create the request object
        #
        $request = [System.Net.HttpWebRequest]::Create($Job.Url)

        # Set the credentials
        if ($Credentials -eq $null)
        {
            $request.UseDefaultCredentials = $true
        }
        else
        {
            $request.Credentials = $Credentials
        }

        $request.Timeout = 36000

        # Build the request header
        $request.Method = "POST"
        $request.UserAgent = getUserAgent
        $request.Accept = "application/atom+xml,application/xml"
        $request.ContentType = "application/atom+xml"
        $request.KeepAlive = $true
        $request.Headers.Add("Accept-Encoding","identity")
        $request.Headers.Add("Accept-Language","en-US")
        $request.Headers.Add("DataServiceVersion","1.0;NetFx")
        $request.Headers.Add("MaxDataServiceVersion","2.0;NetFx")
        $request.Headers.Add("Pragma","no-cache")
        
        # Add header properties specific for Stop Job
        $request.Headers.Add("X-HTTP-Method","MERGE")
        # this is the LastModifiedTime
        $lastmodifiedtime = $Job.LastModifiedTime
        # change ":" to "%3A"
        $lmtime = $lastmodifiedtime.Replace(":","%3A")
        $tempstring = -join ("W/" , '"' , "datetime'" , $lmtime , "'" , '"')
        $request.Headers.Add("If-Match",$tempstring)

        #
        # Build the request body
        #
        # First request the job from the Orchestrator service and get the raw response that we will modify
        # Call the service and get the xml doc with Job information
        [xml] $jobxml = sendHttpGetRequest -url $Job.Url -credentials $credentials    
        
        # Set <published> to CreationTime
        $jobxml.DocumentElement.Item("published").InnerText = $Job.CreationTime + "Z"
        
        # Set <updated> to LastModifiedTime
        $jobxml.DocumentElement.Item("updated").InnerText = $Job.LastModifiedTime  + "Z"
        
        # Set <d:Status> to "Canceled" (this is what stops the Job)
        $jobxml.DocumentElement.Item("content").Item("m:properties").Item("d:Status").InnerText = "Canceled"
        
        # Remove the <link> nodes
        $linknode = $jobxml.DocumentElement.Item("link")
        while ($linknode -ne $null)
        {
            $jobxml.DocumentElement.RemoveChild($linknode)
            $linknode = $jobxml.DocumentElement.Item("link")
        }

        # Execute the service request and get the response
        [System.Net.HttpWebResponse]$response = sendHttpPostRequest -Request $request -RequestBody $jobxml.get_outerxml()

        return ($response.StatusCode -eq "NoContent")
    }
}


function Start-OrchestratorRunbook
{
    ##############################################################################
    # Start-OrchestratorRunbook
    #
    # Start an instance of a runbook
    #
    # Usage:
    #   Start-OrchestratorRunbook -Runbook <runbook> [-Credentials <credentials>] [-Parameters <hashtable>] [-RunbookServers <csv string>]
    ##############################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [PSObject] $Runbook,
            
            [Parameter(Mandatory=$false)]
            [System.Net.NetworkCredential] $Credentials,
            
            [Parameter(Mandatory=$false)]
            [String] $RunbookServers,
            
            [Parameter(Mandatory=$false)]
            [hashtable] $Parameters         
    )
    # If this is monitor runbook, assure it does not already have a job
    if ($Runbook.IsMonitor)
    {
        Write-Host "Runbook.IsMonitor = " $Runbook.IsMonitor
        
        $monjob = Get-OrchestratorJob -runbookid $Runbook.Id -status "Running,Pending" -serviceurl $Runbook.Url_Service -credentials $Credentials 
        if ($monjob -ne $null)
        {
            Write-Host "Monitor already has running job: " $monjob.Id
            return $null
        }        
    }

    # Create the request object
    $request = [System.Net.HttpWebRequest]::Create($Runbook.Url_Service + "Jobs")

    # Set the credentials
    if ($Credentials -eq $null)
    {
        $request.UseDefaultCredentials = $true
    }
    else
    {
        $request.Credentials = $Credentials
    }

    $request.Timeout = 36000

    # Build the request header
    $request.Method = "POST"
    $request.UserAgent = getUserAgent
    $request.Accept = "application/atom+xml,application/xml"
    $request.ContentType = "application/atom+xml"
    $request.KeepAlive = $true
    $request.Headers.Add("Accept-Encoding","identity")
    $request.Headers.Add("Accept-Language","en-US")
    $request.Headers.Add("DataServiceVersion","1.0;NetFx")
    $request.Headers.Add("MaxDataServiceVersion","2.0;NetFx")
    $request.Headers.Add("Pragma","no-cache")

    # Get the RunbookId
    $rbid = $Runbook.Id
    
    # Format the RunbookServers string, if any
    $rbserverstring = ""
    if (-not [string]::IsNullOrEmpty($RunbookServers)) {
        $rbserverstring = -join ("<d:RunbookServers>",$RunbookServers,"</d:RunbookServers>")
    }
        
    # Format the Runbook parameters, if any
    $rbparamstring = ""
    if ($Parameters -ne $null) {
        # Format the param string from the Parameters hashtable
        $rbparamstring = "<d:Parameters>&lt;Data&gt;"
        foreach ($p in $Parameters.GetEnumerator())
        {
            $id = ($Runbook.Parameters | where {$_.Name -eq $p.key}).Id.ToString()
            $rbparamstring = -join ($rbparamstring,"&lt;Parameter&gt;&lt;ID&gt;{",$id,"}&lt;/ID&gt;&lt;Value&gt;",$p.value,"&lt;/Value&gt;&lt;/Parameter&gt;")   

            # $rbparamstring = -join ($rbparamstring,"&lt;Parameter&gt;&lt;ID&gt;{",$p.key,"}&lt;/ID&gt;&lt;Value&gt;",$p.value,"&lt;/Value&gt;&lt;/Parameter&gt;")
        }
        $rbparamstring += "&lt;/Data&gt;</d:Parameters>"
    }
    
    # Build the request body
    $requestBody = @"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<entry xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata" xmlns="http://www.w3.org/2005/Atom">
    <content type="application/xml">
        <m:properties>
            <d:RunbookId m:type="Edm.Guid">$rbid</d:RunbookId>
            $rbserverstring
            $rbparamstring
        </m:properties>
    </content>
</entry>
"@
 
    # Execute the service request and get the response
    $response = sendHttpPostRequest -Request $request -RequestBody $requestBody

    $job = $null
    if ($response -ne $null)
    {
        # Get the response xml with the Job node
        $responseXml = getResponseXml $response
        $response.Close()
        $jobnode = getEntryNodes $responseXml
        
        # Return the Job that was created
        $job = getJobObject $jobnode
    }
    
    return $job
}


function Get-OrchestratorCollection
{
    ######################################################################################################################
    # Get-OrchestratorCollection
    #
    # Get an array list with all of the collections exposed by the Orchestrator OData web service.
    # Each collection object contains the Title and Url properties.
    #
    # Usage:
    #   Get-OrchestratorCollection -ServiceUrl <string> [-Credentials <credentials>]
    ######################################################################################################################

    [CmdletBinding()]
	param (
        [Parameter(Mandatory=$true)]
        [string] $ServiceUrl,
        
        [Parameter(Mandatory=$false)]
        [System.Net.NetworkCredential] $Credentials
	)
    
    # Get the service page xml document from the service
    [xml] $xmlDoc = sendHttpGetRequest -url $ServiceUrl -credentials $Credentials

    # Get the "collection" xml nodes (/service/workspace/collection)
    $collectionnodes = $xmlDoc.service.workspace.collection
    
    if ($collectionnodes -ne $null)
    {
        # Create an array that will hold all the xml collection nodes
        $collectionarray = @()

        # Create a custom PSObject for each collection and add each to the array
        foreach ($collectionnode in $collectionnodes)
        {
            $properties = @{
                'Title' = $collectionnode.title
                'Url' = $ServiceUrl + $collectionnode.href
            }
            
            $collectionarray += New-Object PSObject -Property $properties
        }
       
        # Return the array of collection objects
        return $collectionarray
    }
    else
    {
        # No collections, so return null
        return $null
    }
}


function Get-Credentials
{
    [CmdletBinding()]
	param (
        [Parameter(Mandatory=$true)]
        [string] $Domain,
        
        [Parameter(Mandatory=$true)]
        [string] $Username,
                
        [Parameter(Mandatory=$false)]
        [string] $Password
	)
    
    if (-not([string]::IsNullOrEmpty($Password)))
    {
        return New-Object System.Net.NetworkCredential($Username,$Password,$Domain)  
    }
    else
    {
        $credential = $Domain + "\" + $Username
        return Get-Credential -Credential $credential
    }
}


function getEntryNodes
{
    ######################################################################################################################
    # getEntryNodes
    #
    # Get the "entry" XmlElement or collection of XmlElement from the XML doc returned by the Orchestrator OData web service
    # Returns null if no nodes are found
    #
    # Usage:
    #   getEntryNodes -XmlDoc <xmldoc>
    ######################################################################################################################
    
    [CmdletBinding()]
	param (
        [Parameter(Mandatory=$true)]
        [xml] $XmlDoc
	)
    
    $ns = New-Object Xml.XmlNamespaceManager $XmlDoc.NameTable
    $ns.AddNamespace( "a", "http://www.w3.org/2005/Atom")
    $ns.AddNamespace( "d", "http://schemas.microsoft.com/ado/2007/08/dataservices")
    $ns.AddNamespace( "m", "http://schemas.microsoft.com/ado/2007/08/dataservices/metadata")
    
    $entryNodes = $XmlDoc.SelectNodes("//a:entry",$ns)

    return $entryNodes
}

function getUserAgent
{
    ######################################################################################################################
    # getUserAgent
    #
    # Usage:
    #   getUserAgent
    ######################################################################################################################

    $UserAgent = "PowerShell API Client"
    return $(   
        "{0} (PowerShell {1}; .NET CLR {2}; {3})" -f $UserAgent, $(if($Host.Version){$Host.Version}else{"1.0"}),  
        [Environment]::Version,  
        [Environment]::OSVersion.ToString().Replace("Microsoft Windows ", "Win")  
    )
}

function sendHttpGetRequest
{
    ######################################################################################################################
    # sendHttpGetRequest
    #
    # Make an HTTP Get request to a web site.
    #
    # Usage:
    #   sendHttpGetRequest -Urlstring <string> [-Credentials <credential>]
    ######################################################################################################################

    [CmdletBinding()]
	PARAM (
        [Parameter(Mandatory=$true)]
        [String] $Urlstring,
        
        [Parameter(Mandatory=$false)]
        [System.Net.NetworkCredential] $Credentials
	)

    # Create a request object
    $request = [System.Net.HttpWebRequest]::Create($Urlstring)   

    # Set the credentials
    if ($Credentials -eq $null)
    {
        $request.UseDefaultCredentials = $true
    }
    else
    {
        $request.Credentials = $Credentials
    }

    # Build the User Agent
    $request.UserAgent = getUserAgent
    
    try
    {
        $response = [System.Net.HttpWebResponse] $Request.GetResponse()
    }
    catch [System.Net.WebException]
    {
        Write-Host "Exception occurred in $($MyInvocation.MyCommand): `n$($_.Exception.Message)"
        Write-Host "Response = "
        $response = $($_.Exception.Response)
        
        # Show the response with the error information
        if ($response.ContentLength -gt 0)
        {
            
            $reader = [IO.StreamReader] $response.GetResponseStream()  
            $output = $reader.ReadToEnd()  
            $reader.Close()
            Write-Host $output
            Write-Host ""
        }

        $response = $null
    }
    finally
    {
        $output = $null
        if (($response -ne $null) -and ($response.ContentLength -gt 0))
        {
            $reader = [IO.StreamReader] $response.GetResponseStream()  
            $output = $reader.ReadToEnd()  
            [xml]$output = $output
            $reader.Close()  
        }

        $response.Close()
    }
	return $output
}

function sendHttpPostRequest
{
    ##############################################################################
    # sendHttpPostRequest
    #
    # Usage:
    #   sendHttpPostRequest -Request <HttpWebRequest> -RequestBody <string>
    ##############################################################################

    [CmdletBinding()]
    param 
    (
            [Parameter(Mandatory=$true)]
            [System.Net.HttpWebRequest] $Request,
            
            [Parameter(Mandatory=$true)]
            [string] $RequestBody
    )
                        
    # Add the body to the request
    $requeststream = new-object System.IO.StreamWriter $Request.GetRequestStream()
    
    # The Write method sends the request
    $requeststream.Write($RequestBody)
    $requeststream.Flush()
    $requeststream.Close()
    
    try
    {
        [System.Net.HttpWebResponse] $response = [System.Net.HttpWebResponse] $Request.GetResponse()
    }
    catch [System.Net.WebException]
    {
        Write-Host "Exception occurred in $($MyInvocation.MyCommand): `n$($_.Exception.Message)"
        Write-Host "Response = "
        $response = $($_.Exception.Response)
        
        if ($response.ContentLength -gt 0)
        {
            
            $reader = [IO.StreamReader] $response.GetResponseStream()  
            $output = $reader.ReadToEnd()  
            $reader.Close()
            Write-Host $output
            Write-Host ""
        }

        $response.Close()
        $response = $null
    }
    return $response
}

function getResponseXml
{
    ######################################################################################################################
    # getResponseXml
    ######################################################################################################################

    [CmdletBinding()]
	param (
        [Parameter(Mandatory=$true)]
        [System.Net.HttpWebResponse] $Response
	)
    
    # Write the HttpWebResponse to String
    $responseStream = $Response.GetResponseStream()
    $readStream = new-object System.IO.StreamReader $responseStream
    $responseString = $readStream.ReadToEnd()
    
    # Close the streams
    $readStream.Close()
    $responseStream.Close()

    # Return the response as xml
    return [xml] $responseString
}

function getResourceCount
{
    ######################################################################################################################
    # getResourceCount
    #
    # Get the count of total resources from the XML doc returned by the Orchestrator OData web service
    # Returns null if no count node is found
    #
    # Usage:
    #   getResourceCount -XmlDoc <xmldoc>
    ######################################################################################################################
    
    [CmdletBinding()]
	param (
        [Parameter(Mandatory=$true)]
        [xml] $XmlDoc
	)

    $ns = New-Object Xml.XmlNamespaceManager $XmlDoc.NameTable
    $ns.AddNamespace( "a", "http://www.w3.org/2005/Atom")
    $ns.AddNamespace( "d", "http://schemas.microsoft.com/ado/2007/08/dataservices")
    $ns.AddNamespace( "m", "http://schemas.microsoft.com/ado/2007/08/dataservices/metadata")
    
    $countNode = $XmlDoc.SelectSingleNode("//m:count",$ns)

    $count = $null
    if ($countNode -ne $null)
    {
        $count = $countNode.InnerText
    }
    
    #Write-Host "Count = " $count
    
    return $count
}

function getBaseServiceUrl
{
    ##############################################################################
    # getBaseServiceUrl
    #
    # From an "entry" node get the base service URL
    ##############################################################################
    
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement] $EntryNode
    )
    
    $baseurl = $JobNode.base
    if ($baseurl -eq $null)
    {
        $s = "Orchestrator.svc/"
        $baseurl = $EntryNode.id
        $index = $baseurl.IndexOf($s)
        $baseurl = $baseurl.substring(0,$index + $s.Length)
    }
    
    return $baseurl
}

function getPageQuery
{
    ######################################################################################################################
    # getPageQuery
    #
    # Get a query string for a particular page
    #
    # Usage:
    #   getPageQuery -Page <int>
    ######################################################################################################################

    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [Int] $Page
    )
    
    # Create the page query
    if ($Page -le 0) {$Page = 1}
    $skipcount = ($Page - 1) * $c_RecordsPerPage
    
    return -join ("`$skip=",$skipcount,"&`$top=",$c_RecordsPerPage,"&`$inlinecount=allpages")
}

function Log-DebugEvent
{
	param($eventNo,$message)

	$message = "`n" + $message
	if ($debug -eq $true)
	{
    	$api.LogScriptEvent($SCRIPT_NAME,$eventNo,$EVENT_LEVEL_INFO,$message)
	}
}

function getWebPort
{
	param($webServer)
	$HKLM = [UInt32] "0x80000002"
	$Wow6432regkey = 'SOFTWARE\WOW6432NODE\Microsoft\SystemCenter2012\Orchestrator\Configuration'
	$native32bitregkey = 'SOFTWARE\Microsoft\SystemCenter2012\Orchestrator\Configuration'
	$ValueName = 'WebPort'
	$registry = [WMIClass] "\\$webServer\root\default:StdRegProv"
	try
	{
		$WebPort = [int]$registry.GetStringValue($HKLM, $Wow6432regkey, $valueName).sValue
	} catch {
		$WebPort = [int]$registry.GetStringValue($HKLM, $native32bitregkey, $valueName).sValue
	}
	$WebPort
}

################################################
#
# main
#
################################################

$api = New-Object -comObject 'MOM.ScriptAPI'
$port = getWebPort -webServer $webServer
$url = Get-OrchestratorServiceUrl -Server $webServer -port $port -query 'Runbooks?$filter=IsMonitor eq true'
#$url = $serviceUrl + '/Runbooks?$filter=IsMonitor eq true'
$message =  "Script started." + "`n" + `
			"Web Server: " + $webServer + "`n" + `
			"Port: " + $port + "`n" + `
			"Url: " + $url
Log-DebugEvent -eventNo 301 -message $message


$Page = 0
$MaxPages = 10
    
$rbarray = $null
if ($Page -eq 0)
{
    for ($pg = 1; $pg -le $MaxPages; $pg++)
    {
        $a = getOrchestratorRunbookPage -Url $url -Page $pg -Credentials $Credentials
        $rbarray += $a[0]
        $maxrbs = $a[1]

        $lastRecord = $pg * $c_RecordsPerPage
        if ($lastRecord -ge $maxrbs) { break; } # No more jobs to get, so exit the for loop
    } 
}
elseif ($Page -ge 1)
{
    $a = getOrchestratorRunbookPage -Url $url -Page $Page -Credentials $Credentials
    $rbarray = $a[0]
}

if (($rbarray.count -eq 0) -or ($rbarray -eq $null))
{
	$message =  "No runbooks found at " + $url
	$api.LogScriptEvent($SCRIPT_NAME,325,$EVENT_LEVEL_ERROR,$message)
}
else
{
	foreach ($rb in $rbarray)
	{
		$jobs = Get-OrchestratorJob -ServiceUrl $rb.Url_Service -RunbookId $rb.Id -Status 'Running'
		if ($jobs -is [array])
			{$count = $jobs.count}
		else
		{
			if ($jobs -ne $null)
				{$count = 1}
			else
				{$count = 0}
		}

		$message =  "Id:" + $rb.Id + "`n" + `
					"Name: " + $rb.Name + "`n" + `
					"ActiveJobs: " + $count
		Log-DebugEvent -eventNo 302 -message $message

		$bag = $api.CreatePropertyBag()
		$bag.AddValue("RunbookId",$rb.Id)
		$bag.AddValue("Name",$rb.Name)
		$bag.AddValue("ActiveJobs",$count)
		#$api.return($bag)
		$bag
	}
}

Log-DebugEvent -eventNo 303 -message "Script completed."