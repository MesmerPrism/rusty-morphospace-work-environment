Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-MorphospaceAffectedDependencyBytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function ConvertTo-MorphospaceAffectedDependencyPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = $Path.Replace('\','/')
    if ($normalized -notmatch '^[^/:][^:]*$' -or $normalized -match '(?:^|/)\.\.?/') { throw "Affected dependency path is not canonical: $Path" }
    return $normalized
}

function Get-MorphospaceAffectedDependencyDeclarationKey {
    param(
        [Parameter(Mandatory = $true)][string]$Importer,
        [Parameter(Mandatory = $true)][string]$Variable
    )
    # Repository paths remain ordinal. PowerShell variable identity is
    # case-insensitive, so only the variable component is canonicalized.
    return "$Importer|$($Variable.ToLowerInvariant())"
}

function Get-MorphospaceAffectedDependencyDeclarations {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Declarations)
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($declaration in @($Declarations)) {
        $properties = @($declaration.PSObject.Properties.Name)
        [Array]::Sort($properties,[StringComparer]::Ordinal)
        $targetShape = ($properties -join ',') -ceq 'count,importer,target_paths,variable'
        $classificationShape = ($properties -join ',') -ceq 'classification,count,importer,variable'
        if (-not $targetShape -and -not $classificationShape) { throw 'Affected dependency declaration does not use one closed importer/variable/count/target_paths-or-classification shape.' }
        $importer = ConvertTo-MorphospaceAffectedDependencyPath -Path ([string]$declaration.importer)
        $variable = [string]$declaration.variable
        $identity = "$importer|$variable"
        $key = Get-MorphospaceAffectedDependencyDeclarationKey -Importer $importer -Variable $variable
        if ($importer -cnotmatch '^scripts/.+\.ps(?:m)?1$' -or $variable -cnotmatch '^[A-Za-z_][A-Za-z0-9_:.-]*$' -or [int]$declaration.count -lt 1 -or $map.ContainsKey($key)) { throw "Affected dependency declaration has an invalid or duplicate identity: $identity" }
        if ($targetShape) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $targets = [Collections.Generic.List[string]]::new()
            foreach ($target in @($declaration.target_paths)) {
                $path = ConvertTo-MorphospaceAffectedDependencyPath -Path ([string]$target)
                if ($path -cnotmatch '^scripts/.+\.ps(?:m)?1$' -or -not $seen.Add($path)) { throw "Affected dependency declaration has an invalid or duplicate target: $key" }
            [void]$targets.Add($path)
            }
            if ($targets.Count -eq 0) { throw "Affected dependency declaration has no target: $key" }
            [string[]]$ordered = @($targets.ToArray()); [Array]::Sort($ordered,[StringComparer]::Ordinal)
            $map[$key] = [pscustomobject][ordered]@{importer=$importer;variable=$variable;count=[int]$declaration.count;target_paths=@($ordered)}
        } else {
            if ([string]$declaration.classification -cne 'authenticated-external-command') { throw "Affected dependency declaration has an unsupported classification: $key" }
            $map[$key] = [pscustomobject][ordered]@{importer=$importer;variable=$variable;count=[int]$declaration.count;classification='authenticated-external-command'}
        }
    }
    return $map
}

function Get-MorphospaceAffectedDependencyLexicalScope {
    param([Parameter(Mandatory = $true)][Management.Automation.Language.Ast]$Node)
    $current = $Node.Parent
    if ($Node -is [Management.Automation.Language.ScriptBlockAst] -and $current -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $current = $current.Parent }
    while ($null -ne $current) {
        if ($current -is [Management.Automation.Language.FunctionDefinitionAst]) { return $current }
        if ($current -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $current.ScriptBlock }
        $current = $current.Parent
    }
    $current = $Node
    while ($null -ne $current.Parent) { $current = $current.Parent }
    return $current
}

function Get-MorphospaceAffectedDependencyScopeChain {
    param([Parameter(Mandatory = $true)][object]$Scope)
    $result = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $current = $Scope
    while ($null -ne $current -and $seen.Add($current)) {
        [void]$result.Add($current)
        $next = Get-MorphospaceAffectedDependencyLexicalScope -Node $current
        if ($next -eq $current) { break }
        $current = $next
    }
    return $result.ToArray()
}

function Test-MorphospaceAffectedDependencyAssignmentDefinite {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.Language.AssignmentStatementAst]$Assignment,
        [Parameter(Mandatory = $true)][object]$AssignmentScope,
        [Parameter(Mandatory = $true)][Management.Automation.Language.CommandAst]$Invocation,
        [Parameter(Mandatory = $true)][object]$InvocationScope
    )
    $sameLexicalScope = [object]::ReferenceEquals($AssignmentScope,$InvocationScope)
    $explicitRootScriptScope =
        [string]$Assignment.Left.VariablePath.UserPath -imatch '^script:' -and
        $AssignmentScope -is [Management.Automation.Language.ScriptBlockAst]
    if ((-not $sameLexicalScope -and -not $explicitRootScriptScope) -or [int]$Assignment.Extent.EndOffset -gt [int]$Invocation.Extent.StartOffset) { return $false }

    # PowerShell executes statements in one StatementBlock/NamedBlock in source
    # order. The assignment is therefore definite for a later invocation in
    # that block or any of its nested blocks. An assignment made in a sibling
    # or nested conditional block is not definite for an invocation outside
    # that block and must use a declaration or the conservative fallback.
    $assignmentContainer = $Assignment.Parent
    while ($null -ne $assignmentContainer -and
        $assignmentContainer -isnot [Management.Automation.Language.StatementBlockAst] -and
        $assignmentContainer -isnot [Management.Automation.Language.NamedBlockAst]) {
        $assignmentContainer = $assignmentContainer.Parent
    }
    if ($null -eq $assignmentContainer) { return $false }
    $current = $Invocation
    while ($null -ne $current -and -not [object]::ReferenceEquals($current,$assignmentContainer)) { $current = $current.Parent }
    return $null -ne $current
}

function Get-MorphospaceDataRoleNodes($Ast,[type]$Type){@($Ast.FindAll({param($n)$Type.IsInstanceOfType($n)},$true))}

function Get-MorphospaceDataRoleAssignment($Node){$p=$Node.Parent;while($null-ne$p-and$p-isnot[Management.Automation.Language.AssignmentStatementAst]-and$p-isnot[Management.Automation.Language.ScriptBlockAst]){$p=$p.Parent};if($p-is[Management.Automation.Language.AssignmentStatementAst]){$p}}

function Test-MorphospaceDataRoleStaticParser($Node){$Node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$Node.Static-and$Node.Expression-is[Management.Automation.Language.TypeExpressionAst]-and$Node.Expression.TypeName.FullName-in@('Management.Automation.Language.Parser','System.Management.Automation.Language.Parser')-and$Node.Member-is[Management.Automation.Language.StringConstantExpressionAst]-and$Node.Member.Value-ieq'ParseFile'-and$Node.Arguments.Count-eq3}

function Test-MorphospaceDataRoleSelector($Node){
 if($Node-isnot[Management.Automation.Language.ScriptBlockExpressionAst]){return $false}
 $b=$Node.ScriptBlock
 if(@($b.ParamBlock.Parameters).Count-ne1-or@($b.EndBlock.Statements).Count-ne1-or$null-ne$b.BeginBlock-or$null-ne$b.ProcessBlock){return $false}
 if(@($b.ParamBlock.Parameters[0].Attributes).Count){return $false}
 if(@(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.CommandAst])).Count-or@(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.AssignmentStatementAst])).Count-or@(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.ReturnStatementAst])).Count){return $false}
 $parameter=$b.ParamBlock.Parameters[0].Name.VariablePath.UserPath
 foreach($v in @(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.VariableExpressionAst]))){if($v.VariablePath.UserPath-ine$parameter){return $false}}
 foreach($m in @(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.InvokeMemberExpressionAst]))){
  if($m.Static-or$m.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]){return $false}
  if($m.Member.Value-ieq'GetCommandName'-and$m.Expression-is[Management.Automation.Language.VariableExpressionAst]-and$m.Expression.VariablePath.UserPath-ieq$parameter-and@($m.Arguments|Where-Object{$null-ne$_}).Count-eq0){continue}
  if($m.Member.Value-ieq'Replace'-and$m.Expression.Extent.Text-imatch'\.Extent\.Text$'-and$m.Arguments.Count-eq2-and$m.Arguments[0]-is[Management.Automation.Language.StringConstantExpressionAst]-and$m.Arguments[1]-is[Management.Automation.Language.StringConstantExpressionAst]-and$m.Arguments[0].Value-ceq"`r`n"-and$m.Arguments[1].Value-ceq"`n"){continue}
  return $false
 }
 foreach($member in @(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.MemberExpressionAst]))){if($member-is[Management.Automation.Language.InvokeMemberExpressionAst]){continue};if($member.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$member.Member.Value-inotmatch'^(Name|Value|Extent|Text)$'){return $false};$root=$member.Expression;while($root-is[Management.Automation.Language.MemberExpressionAst]){$root=$root.Expression};if($root-isnot[Management.Automation.Language.VariableExpressionAst]-or$root.VariablePath.UserPath-ine$parameter){return $false}}
 foreach($convert in @(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.ConvertExpressionAst]))){return $false}
 foreach($unary in @(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.UnaryExpressionAst]))){if($unary.TokenKind-notin@('Not','Exclaim')){return $false}}
 foreach($binary in @(Get-MorphospaceDataRoleNodes $b ([Management.Automation.Language.BinaryExpressionAst]))){if($binary.Operator-notin@('And','Or','Ceq','Cne','Ieq','Ine','Is','IsNot')){return $false}}
 return $true
}

function Test-MorphospaceDataRoleSafeUse($Variable,$Taints){
 $p=$Variable.Parent;$cursor=$Variable
 if($Taints[$Variable.VariablePath.UserPath]-ceq'ref'-and$p-is[Management.Automation.Language.MemberExpressionAst]-and($p.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$p.Member.Value-ine'Count')){return $false}
 while($null-ne$p){
  if($p-is[Management.Automation.Language.AssignmentStatementAst]){
   if([object]::ReferenceEquals($p.Left,$Variable)){return $true}
   if($p.Left-is[Management.Automation.Language.VariableExpressionAst]-and$Taints.ContainsKey($p.Left.VariablePath.UserPath)){return $true}
   return $false
  }
  if($p-is[Management.Automation.Language.InvokeMemberExpressionAst]){
   if((Test-MorphospaceDataRoleStaticParser $p)-and$Variable.Parent-is[Management.Automation.Language.ConvertExpressionAst]-and$Variable.Parent.Type.TypeName.FullName-ieq'ref'-and(@($p.Arguments|Select-Object -Skip 1|Where-Object{[object]::ReferenceEquals($_,$Variable.Parent)})).Count-eq1){$cursor=$p;$p=$p.Parent;continue}
   if($p.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]){return $false}
   if($p.Static){if($p.Expression-isnot[Management.Automation.Language.TypeExpressionAst]-or$p.Expression.TypeName.FullName-inotmatch'^(string|System.String)$'-or$p.Member.Value-ine'Equals'-or$p.Arguments.Count-ne3-or$p.Arguments[2].Extent.Text-cne'[StringComparison]::Ordinal'){return $false}}
   elseif($p.Member.Value-ieq'FindAll'){if($p.Arguments.Count-ne2-or-not(Test-MorphospaceDataRoleSelector $p.Arguments[0])-or$p.Arguments[1].Extent.Text-notin@('$true','$false')){return $false}}
   elseif($p.Member.Value-ieq'Replace'){if($p.Arguments.Count-ne2-or$p.Arguments[0]-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$p.Arguments[1]-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$p.Arguments[0].Value-cne"`r`n"-or$p.Arguments[1].Value-cne"`n"){return $false}}
   else{return $false}
  }elseif($p-is[Management.Automation.Language.MemberExpressionAst]){if($p.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$p.Member.Value-inotmatch'^(Count|Extent|Text)$'){return $false}}
  elseif($p-is[Management.Automation.Language.IndexExpressionAst]){if($p.Index-isnot[Management.Automation.Language.ConstantExpressionAst]-or$p.Index.Value-ne0){return $false}}
  elseif($p-is[Management.Automation.Language.IfStatementAst]){return @($p.Clauses|Where-Object{[object]::ReferenceEquals($_.Item1,$cursor)}).Count-eq1}
  elseif($p-is[Management.Automation.Language.ReturnStatementAst]-or$p-is[Management.Automation.Language.CommandAst]-or$p-is[Management.Automation.Language.ScriptBlockAst]){return $false}
  elseif($p-is[Management.Automation.Language.ConvertExpressionAst]){if($p.Type.TypeName.FullName-ieq'ref'-and(Test-MorphospaceDataRoleStaticParser $p.Parent)-and(@($p.Parent.Arguments|Select-Object -Skip 1|Where-Object{[object]::ReferenceEquals($_,$p)})).Count-eq1){}elseif($p.Type.TypeName.FullName-inotmatch'^(string|System.String)$'-or$p.Child.Extent.Text-inotmatch'\.Extent\.Text(?:\.Replace\(.+\))?$'){return $false}}
  elseif($p-is[Management.Automation.Language.UnaryExpressionAst]){if($p.TokenKind-notin@('Not','Exclaim')){return $false}}
  elseif($p-is[Management.Automation.Language.BinaryExpressionAst]){if($p.Operator-notin@('And','Or','Ceq','Cne','Ieq','Ine','Is','IsNot')){return $false}}
  elseif($p-is[Management.Automation.Language.PipelineAst]){if($p.PipelineElements.Count-ne1-or$p.PipelineElements[0]-isnot[Management.Automation.Language.CommandExpressionAst]){return $false}}
  elseif($p-is[Management.Automation.Language.StatementBlockAst]){if($p.Statements.Count-ne1-or$p.Parent-isnot[Management.Automation.Language.ArrayExpressionAst]-and$p.Parent-isnot[Management.Automation.Language.ParenExpressionAst]){return $false}}
  elseif($p-isnot[Management.Automation.Language.CommandExpressionAst]-and$p-isnot[Management.Automation.Language.ArrayExpressionAst]-and$p-isnot[Management.Automation.Language.ParenExpressionAst]){return $false}
  $cursor=$p;$p=$p.Parent
 }
 return $false
}

function Get-MorphospaceDataRoleAnalysis($Function){
 $body=$Function.Body;$reasons=[Collections.Generic.List[string]]::new();$taints=@{};$parseRows=@()
 $methods=@(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.InvokeMemberExpressionAst]))
 $parsers=@($methods|Where-Object{Test-MorphospaceDataRoleStaticParser $_})
 if(-not$parsers.Count){return $null}
 foreach($parse in $parsers){
  $assignment=Get-MorphospaceDataRoleAssignment $parse
  if($null-eq$assignment){$reasons.Add('implicit-AST-output');continue}
  if($assignment.Left-isnot[Management.Automation.Language.VariableExpressionAst]-or$assignment.Operator-ne[Management.Automation.Language.TokenKind]::Equals){$reasons.Add('unsupported-parser-storage');continue}
  $name=$assignment.Left.VariablePath.UserPath
  if($name.Contains(':')){$reasons.Add('scoped-AST-storage');continue}
  if($name-ine'null'){$taints[$name]='AST'}
  foreach($ref in @($parse.Arguments|Select-Object -Skip 1)){
   if($ref-isnot[Management.Automation.Language.ConvertExpressionAst]-or$ref.Type.TypeName.FullName-ine'ref'-or$ref.Child-isnot[Management.Automation.Language.VariableExpressionAst]-or$ref.Child.VariablePath.UserPath.Contains(':')){$reasons.Add('unsupported-ref-storage');continue}
   $taints[$ref.Child.VariablePath.UserPath]='ref'
  }
  $parseRows+=,[ordered]@{line=$parse.Extent.StartLineNumber;storage=$name;path_kind=$parse.Arguments[0].GetType().Name;path=$parse.Arguments[0].Extent.Text;refs=@($parse.Arguments|Select-Object -Skip 1|ForEach-Object{$_.Extent.Text})}
 }
 foreach($method in $methods){if($method.Member-is[Management.Automation.Language.StringConstantExpressionAst]-and$method.Member.Value-ieq'GetScriptBlock'){$reasons.Add('AST-execution-GetScriptBlock')}}
 foreach($command in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.CommandAst]))){if($command.GetCommandName()-imatch'^(Get-Variable|Set-Variable|New-Variable|gv|sv|nv|Invoke-Expression|iex|Start-Process|pwsh|powershell)$'){$reasons.Add('ambient-or-content-execution-command')}}
 if($body.Extent.Text-match'(?i)SessionState|GetType\s*\(|\[scriptblock\]::Create|TypeAccelerators|using\s+(assembly|namespace)|Add-Type'){$reasons.Add('ambient-reflection-or-eval')}
 # Two passes suffice for AST -> directly assigned selected AST arrays.
 foreach($method in $methods){if($method.Expression-is[Management.Automation.Language.VariableExpressionAst]-and$taints.ContainsKey($method.Expression.VariablePath.UserPath)-and$method.Member-is[Management.Automation.Language.StringConstantExpressionAst]-and$method.Member.Value-ieq'FindAll'){
  $assignment=Get-MorphospaceDataRoleAssignment $method
  if($null-eq$assignment-or$assignment.Left-isnot[Management.Automation.Language.VariableExpressionAst]-or$assignment.Left.VariablePath.UserPath.Contains(':')-or-not(Test-MorphospaceDataRoleSelector $method.Arguments[0])){$reasons.Add('unsupported-selector-storage');continue}
  if($method.Expression-is[Management.Automation.Language.VariableExpressionAst]-and$taints[$method.Expression.VariablePath.UserPath]-ceq'AST'){$taints[$assignment.Left.VariablePath.UserPath]='selection'}else{$reasons.Add('selector-receiver-not-parser-AST')}
 }}
 foreach($assignment in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.AssignmentStatementAst]))){if($assignment.Left-is[Management.Automation.Language.VariableExpressionAst]-and$taints.ContainsKey($assignment.Left.VariablePath.UserPath)){
  $writers=@(Get-MorphospaceDataRoleNodes $assignment.Right ([Management.Automation.Language.InvokeMemberExpressionAst])|Where-Object{(Test-MorphospaceDataRoleStaticParser $_)-or($_.Member-is[Management.Automation.Language.StringConstantExpressionAst]-and$_.Member.Value-ieq'FindAll')})
  $isRefInit=$taints[$assignment.Left.VariablePath.UserPath]-ceq'ref'-and$assignment.Right.Extent.Text-ceq'$null'
  $requiredKind=$taints[$assignment.Left.VariablePath.UserPath]
  if($writers.Count-ne1-and-not$isRefInit){$reasons.Add('tainted-storage-writer-not-parser-or-selector')}
  elseif(-not$isRefInit-and$requiredKind-ceq'AST'-and-not(Test-MorphospaceDataRoleStaticParser $writers[0])){$reasons.Add('AST-writer-not-ParseFile')}
 }}
 foreach($variable in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.VariableExpressionAst]))){
  $storage=$variable.VariablePath.UserPath
  if($storage.Contains(':')-and$taints.ContainsKey(($storage.Split(':')[-1]))){$reasons.Add('scoped-tainted-storage-access')}
  if($taints.ContainsKey($storage)-and-not(Test-MorphospaceDataRoleSafeUse $variable $taints)){$reasons.Add("unsafe-taint-use:$($variable.Extent.StartLineNumber):$storage")}
 }
 foreach($assignment in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.AssignmentStatementAst]))){
  if($assignment.Left-is[Management.Automation.Language.VariableExpressionAst]-and$taints.ContainsKey($assignment.Left.VariablePath.UserPath)-and$assignment.Operator-ne[Management.Automation.Language.TokenKind]::Equals){$reasons.Add('compound-tainted-write')}
 }
 foreach($loop in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.ForEachStatementAst]))){if($taints.ContainsKey($loop.Variable.VariablePath.UserPath)){$reasons.Add('foreach-tainted-write')}}
 # Taint analysis is necessary but insufficient: the enclosing closed observer
 # grammar separately closes module setup, paths, storage, refs and output.
 [ordered]@{tainted_storage=@($taints.Keys|Sort-Object);syntactic_taint_use_match=($reasons.Count-eq0);reasons=@($reasons|Select-Object -Unique)}
}

# Finite inert observer grammar. Unsupported syntax retains ordinary execution closure.
function Test-MorphospaceDataObserverStatements($Block){
 foreach($statement in @($Block.Statements)){
  if($statement-is[Management.Automation.Language.AssignmentStatementAst]){
   if($statement.Left-isnot[Management.Automation.Language.VariableExpressionAst]-or$statement.Left.VariablePath.UserPath.Contains(':')-or$statement.Operator-ne[Management.Automation.Language.TokenKind]::Equals){return $false}
   if($statement.Left.VariablePath.UserPath-imatch'^(args|input|this|_|PSItem|true|false|PID|HOME|ExecutionContext|PSVersionTable|PSCmdlet|PSScriptRoot|PSCommandPath|Host|Error|OFS|Matches|LASTEXITCODE|PSBoundParameters|ErrorActionPreference)$'){return $false}
   continue
  }
  if($statement-is[Management.Automation.Language.IfStatementAst]){foreach($clause in $statement.Clauses){if(-not(Test-MorphospaceDataObserverStatements $clause.Item2)){return $false}};if($null-ne$statement.ElseClause-and-not(Test-MorphospaceDataObserverStatements $statement.ElseClause)){return $false};continue}
  if($statement-is[Management.Automation.Language.ThrowStatementAst]-and$null-ne$statement.Pipeline-and$statement.Pipeline.PipelineElements.Count-eq1-and$statement.Pipeline.PipelineElements[0]-is[Management.Automation.Language.CommandExpressionAst]-and$statement.Pipeline.PipelineElements[0].Expression-is[Management.Automation.Language.StringConstantExpressionAst]){continue}
  return $false
 }
 return $true
}
function Get-MorphospaceAffectedDataReferenceOffsets($ImporterAst){
 $offsets=[Collections.Generic.HashSet[int]]::new()
 if($null-ne$ImporterAst.ParamBlock-or@($ImporterAst.Attributes).Count-or$null-ne$ImporterAst.BeginBlock-or$null-ne$ImporterAst.ProcessBlock-or$null-ne$ImporterAst.DynamicParamBlock-or($ImporterAst.PSObject.Properties.Name-ccontains'CleanBlock'-and$null-ne$ImporterAst.CleanBlock)-or$null-ne$ImporterAst.ScriptRequirements){return ,$offsets}
 if($ImporterAst.Extent.Text-match'(?i)TypeAccelerators|using\s+(assembly|namespace)|Add-Type|SessionState'){return ,$offsets}
 if(@(Get-MorphospaceDataRoleNodes $ImporterAst ([Management.Automation.Language.TypeDefinitionAst])).Count){return ,$offsets}
 if(@(Get-MorphospaceDataRoleNodes $ImporterAst ([Management.Automation.Language.UsingStatementAst])).Count){return ,$offsets}
 foreach($setup in @($ImporterAst.EndBlock.Statements)){
  if($setup-is[Management.Automation.Language.FunctionDefinitionAst]){if($setup.Name-imatch'^(?:script:|global:)?(?:Set-StrictMode|Export-ModuleMember|Join-Path)$'){return ,$offsets};continue}
  if($setup-is[Management.Automation.Language.AssignmentStatementAst]-and$setup.Left-is[Management.Automation.Language.VariableExpressionAst]-and$setup.Left.VariablePath.UserPath-ieq'ErrorActionPreference'-and$setup.Right.Extent.Text-ceq"'Stop'"){continue}
  if($setup-is[Management.Automation.Language.PipelineAst]-and$setup.PipelineElements.Count-eq1-and$setup.PipelineElements[0]-is[Management.Automation.Language.CommandAst]){
   $command=$setup.PipelineElements[0]
   $simple=$command.GetCommandName()-in@('Set-StrictMode','Export-ModuleMember')
   foreach($element in @($command.CommandElements|Select-Object -Skip 1)){
    if($element-is[Management.Automation.Language.CommandParameterAst]){if($null-ne$element.Argument){$simple=$false};continue}
    if($element-is[Management.Automation.Language.StringConstantExpressionAst]-or$element-is[Management.Automation.Language.ConstantExpressionAst]){continue}
    if($element-is[Management.Automation.Language.ArrayLiteralAst]-and@($element.Elements|Where-Object{$_-isnot[Management.Automation.Language.StringConstantExpressionAst]-and$_-isnot[Management.Automation.Language.ConstantExpressionAst]}).Count-eq0){continue}
    $simple=$false
   }
   if($simple){continue}
  }
  return ,$offsets
 }
 foreach($function in @(Get-MorphospaceDataRoleNodes $ImporterAst ([Management.Automation.Language.FunctionDefinitionAst]))){
  # A witness requires an actual fixed Parser.ParseFile call. Avoid analyzing
  # unrelated functions without suppressing any ordinary executable graph edge.
  if (@(Get-MorphospaceDataRoleNodes $function.Body ([Management.Automation.Language.InvokeMemberExpressionAst]) | Where-Object { Test-MorphospaceDataRoleStaticParser $_ }).Count -eq 0) { continue }
  $analysis=Get-MorphospaceDataRoleAnalysis $function
  if($null-eq$analysis-or-not$analysis.syntactic_taint_use_match){continue}
  $body=$function.Body;$closed=$true
  if($null-ne$body.BeginBlock-or$null-ne$body.ProcessBlock-or$null-ne$body.DynamicParamBlock-or($body.PSObject.Properties.Name-ccontains'CleanBlock'-and$null-ne$body.CleanBlock)-or@($body.Attributes).Count-or-not(Test-MorphospaceDataObserverStatements $body.EndBlock)){continue}
  $parameters=@($function.Parameters)+@($function.Body.ParamBlock.Parameters)
  foreach($parameter in $parameters){if($null-ne$parameter){
   if($parameter.StaticType-notin@([string],[bool])){$closed=$false}
   if($null-ne$parameter.DefaultValue-and$parameter.DefaultValue-isnot[Management.Automation.Language.StringConstantExpressionAst]-and$parameter.DefaultValue-isnot[Management.Automation.Language.ConstantExpressionAst]-and($parameter.DefaultValue-isnot[Management.Automation.Language.VariableExpressionAst]-or$parameter.DefaultValue.VariablePath.UserPath-inotmatch'^(true|false|null)$')){$closed=$false}
   foreach($attribute in @($parameter.Attributes)){if($attribute-is[Management.Automation.Language.AttributeAst]){if($attribute.TypeName.FullName-inotmatch'^(Parameter|System.Management.Automation.ParameterAttribute)$'){$closed=$false};foreach($arg in @($attribute.NamedArguments)){if($arg.Argument-isnot[Management.Automation.Language.ConstantExpressionAst]-and($arg.Argument-isnot[Management.Automation.Language.VariableExpressionAst]-or$arg.Argument.VariablePath.UserPath-inotmatch'^(true|false)$')){$closed=$false}}}}
  }}
  $locals=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $parameterNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($parameter in $parameters){if($null-ne$parameter){[void]$locals.Add($parameter.Name.VariablePath.UserPath);[void]$parameterNames.Add($parameter.Name.VariablePath.UserPath)}}
  foreach($assignment in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.AssignmentStatementAst]))){
   if($assignment.Left-isnot[Management.Automation.Language.VariableExpressionAst]-or$assignment.Left.VariablePath.UserPath.Contains(':')-or$assignment.Operator-ne[Management.Automation.Language.TokenKind]::Equals){$closed=$false;continue}
   if($assignment.Left.VariablePath.UserPath-imatch'^(args|input|this|_|PSItem|true|false|PID|HOME|ExecutionContext|PSVersionTable|PSCmdlet|PSScriptRoot|PSCommandPath|Host|Error|OFS|Matches|LASTEXITCODE|PSBoundParameters|ErrorActionPreference)$'){$closed=$false;continue}
   # Nested assignment expressions are outside the finite observer grammar.
   if($assignment.Parent-isnot[Management.Automation.Language.StatementBlockAst]-and$assignment.Parent-isnot[Management.Automation.Language.NamedBlockAst]){$closed=$false;continue}
   [void]$locals.Add($assignment.Left.VariablePath.UserPath)
  }
  foreach($variable in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.VariableExpressionAst]))){
   if($variable.VariablePath.UserPath.Contains(':')){$closed=$false;continue}
   if($variable.VariablePath.UserPath-imatch'^(true|false|null)$'-or$parameterNames.Contains($variable.VariablePath.UserPath)){continue}
   if($variable.Parent-is[Management.Automation.Language.AssignmentStatementAst]-and[object]::ReferenceEquals($variable.Parent.Left,$variable)){continue}
   if($locals.Contains($variable.VariablePath.UserPath)){
    $definite=$false
    foreach($writer in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.AssignmentStatementAst]))){
     if($writer.Left-isnot[Management.Automation.Language.VariableExpressionAst]-or$writer.Left.VariablePath.UserPath-ine$variable.VariablePath.UserPath-or$writer.Extent.EndOffset-gt$variable.Extent.StartOffset){continue}
     $container=$writer.Parent;$ancestor=$variable.Parent
     while($null-ne$ancestor){if([object]::ReferenceEquals($ancestor,$container)){$definite=$true;break};$ancestor=$ancestor.Parent}
     if($definite){break}
    }
    if(-not$definite){$closed=$false};continue
   }
   $selector=$variable.Parent;while($null-ne$selector-and$selector-isnot[Management.Automation.Language.ScriptBlockExpressionAst]){$selector=$selector.Parent}
   if($null-eq$selector-or-not(Test-MorphospaceDataRoleSelector $selector)){$closed=$false}
  }
  if(@(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.CommandAst])).Count){continue}
  if(@(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.FunctionDefinitionAst])).Count){continue}
  foreach($kind in @([Management.Automation.Language.ForEachStatementAst],[Management.Automation.Language.ForStatementAst],[Management.Automation.Language.WhileStatementAst],[Management.Automation.Language.DoWhileStatementAst],[Management.Automation.Language.TryStatementAst],[Management.Automation.Language.SwitchStatementAst])){if(@(Get-MorphospaceDataRoleNodes $body $kind).Count){$closed=$false}}
  foreach($convert in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.ConvertExpressionAst]))){if($convert.Type.TypeName.FullName-inotmatch'^(ref|string|System.String)$'){$closed=$false}}
  foreach($unary in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.UnaryExpressionAst]))){if($unary.TokenKind-notin@('Not','Exclaim')){$closed=$false}}
  foreach($binary in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.BinaryExpressionAst]))){if($binary.Operator-notin@('And','Or','Ceq','Cne','Ieq','Ine','Is','IsNot')){$closed=$false}}
  foreach($member in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.MemberExpressionAst]))){
   if($member-is[Management.Automation.Language.InvokeMemberExpressionAst]){continue}
   if($member.Static){if($member.Expression-isnot[Management.Automation.Language.TypeExpressionAst]-or$member.Expression.TypeName.FullName-inotmatch'^(StringComparison|System.StringComparison)$'-or$member.Member.Extent.Text-ine'Ordinal'){$closed=$false};continue}
   $root=$member.Expression;while($root-is[Management.Automation.Language.MemberExpressionAst]){$root=$root.Expression}
   if($root-is[Management.Automation.Language.IndexExpressionAst]){$root=$root.Target}
   if($root-is[Management.Automation.Language.ArrayExpressionAst]-and$root.SubExpression.Statements.Count-eq1-and$root.SubExpression.Statements[0]-is[Management.Automation.Language.PipelineAst]-and$root.SubExpression.Statements[0].PipelineElements.Count-eq1-and$root.SubExpression.Statements[0].PipelineElements[0]-is[Management.Automation.Language.CommandExpressionAst]){$root=$root.SubExpression.Statements[0].PipelineElements[0].Expression}
   if($root-is[Management.Automation.Language.VariableExpressionAst]-and$analysis.tainted_storage-icontains$root.VariablePath.UserPath){continue}
   $selector=$member.Parent;while($null-ne$selector-and$selector-isnot[Management.Automation.Language.ScriptBlockExpressionAst]){$selector=$selector.Parent}
   if($null-eq$selector-or-not(Test-MorphospaceDataRoleSelector $selector)){$closed=$false}
  }
  foreach($method in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.InvokeMemberExpressionAst]))){
   if($method.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]){$closed=$false;continue}
   $name=$method.Member.Value
   if($method.Static){
    if($method.Expression-isnot[Management.Automation.Language.TypeExpressionAst]){$closed=$false;continue}
    $type=$method.Expression.TypeName.FullName
    $key=($type+'::'+$name).ToLowerInvariant()
    if($key-notin@('management.automation.language.parser::parsefile','system.management.automation.language.parser::parsefile','io.path::combine','system.io.path::combine','io.file::readallbytes','system.io.file::readallbytes','security.cryptography.sha256::hashdata','system.security.cryptography.sha256::hashdata','convert::tohexstring','system.convert::tohexstring','string::equals','system.string::equals','string::isnullorempty','system.string::isnullorempty')){$closed=$false}
    if($name-ieq'ParseFile'-and-not(Test-MorphospaceDataRoleStaticParser $method)){$closed=$false}
    if($name-ieq'ParseFile'){
     $refNames=@($method.Arguments|Select-Object -Skip 1|ForEach-Object{if($_-is[Management.Automation.Language.ConvertExpressionAst]-and$_.Type.TypeName.FullName-ieq'ref'-and$_.Child-is[Management.Automation.Language.VariableExpressionAst]-and-not$_.Child.VariablePath.UserPath.Contains(':')){$_.Child.VariablePath.UserPath}})
     if($refNames.Count-ne2-or$refNames[0]-ieq$refNames[1]){$closed=$false}
    }
    if($name-ieq'ReadAllBytes'-and($method.Parent-isnot[Management.Automation.Language.InvokeMemberExpressionAst]-or$method.Parent.Member.Extent.Text-ine'HashData')){$closed=$false}
    if($name-ieq'HashData'-and($method.Parent-isnot[Management.Automation.Language.InvokeMemberExpressionAst]-or$method.Parent.Member.Extent.Text-ine'ToHexString')){$closed=$false}
   }elseif($name-in@('FindAll','Replace','GetCommandName')){
    # Tainted receiver uses/selectors are validated by Get-MorphospaceDataRoleAnalysis. A GetCommandName
    # must occur inside one of those already-validated FindAll selectors.
    if($name-ieq'GetCommandName'){$parent=$method.Parent;while($null-ne$parent-and$parent-isnot[Management.Automation.Language.ScriptBlockExpressionAst]){$parent=$parent.Parent};if($null-eq$parent-or-not(Test-MorphospaceDataRoleSelector $parent)){$closed=$false}}
    if($name-ieq'FindAll'-and($method.Expression-isnot[Management.Automation.Language.VariableExpressionAst]-or$analysis.tainted_storage-inotcontains$method.Expression.VariablePath.UserPath)){$closed=$false}
    if($name-ieq'Replace'-and$method.Expression.Extent.Text-inotmatch'\.Extent\.Text$'){$closed=$false}
   }elseif($name-ieq'ToLowerInvariant'){
    if($method.Expression-isnot[Management.Automation.Language.InvokeMemberExpressionAst]-or-not$method.Expression.Static-or$method.Expression.Member.Extent.Text-ine'ToHexString'){$closed=$false}
   }else{$closed=$false}
  }
  foreach($block in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.ScriptBlockExpressionAst]))){if(-not(Test-MorphospaceDataRoleSelector $block)-or$block.Parent-isnot[Management.Automation.Language.InvokeMemberExpressionAst]-or$block.Parent.Member.Extent.Text-ine'FindAll'){$closed=$false}}
  if(-not$closed){continue}
  foreach($parse in @(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.InvokeMemberExpressionAst])|Where-Object{Test-MorphospaceDataRoleStaticParser $_})){
   $path=$parse.Arguments[0]
   if($path-isnot[Management.Automation.Language.InvokeMemberExpressionAst]-or-not$path.Static-or$path.Expression-isnot[Management.Automation.Language.TypeExpressionAst]-or$path.Expression.TypeName.FullName-inotmatch'^(IO.Path|System.IO.Path)$'-or$path.Member.Extent.Text-ine'Combine'-or$path.Arguments.Count-ne2){continue}
   $root=$path.Arguments[0];$literal=$path.Arguments[1]
   if($root-isnot[Management.Automation.Language.VariableExpressionAst]-or$root.VariablePath.UserPath.Contains(':')-or$literal-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$literal.Value-cnotmatch'^(scripts|tools)/[A-Za-z0-9_./-]+\.ps(?:m)?1$'-or@($literal.Value.Split('/')|Where-Object{$_-in@('.','..','')}).Count){continue}
   $matching=@($parameters|Where-Object{$null-ne$_-and$_.Name.VariablePath.UserPath-ieq$root.VariablePath.UserPath-and$_.StaticType-eq[string]})
   if($matching.Count-ne1){continue}
   $rootWrites=@(Get-MorphospaceDataRoleNodes $body ([Management.Automation.Language.AssignmentStatementAst])|Where-Object{$_.Left-is[Management.Automation.Language.VariableExpressionAst]-and$_.Left.VariablePath.UserPath-ieq$root.VariablePath.UserPath})
   if($rootWrites.Count){continue}
   [void]$offsets.Add($literal.Extent.StartOffset)
  }
 }
 return ,$offsets
}


function Resolve-MorphospaceAffectedCheckDependencyClosure {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Entrypoint,
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DynamicDeclarations
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $trackedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trackedScripts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Inventory.records)) {
        if ([string]$entry.type -cne 'blob' -or @('100644','100755') -cnotcontains [string]$entry.mode) { continue }
        [void]$trackedFiles.Add([string]$entry.path)
        if ([string]$entry.path -match '^(?:scripts|tools)/.+\.ps(?:m)?1$') { [void]$trackedScripts.Add([string]$entry.path) }
    }
    $declarations = Get-MorphospaceAffectedDependencyDeclarations -Declarations @($DynamicDeclarations)
    $observedDeclarations = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $usedDeclarations = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $fallbackReasons = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $nodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    $executionQueued = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $executedSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $parsedSha = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)

    function Add-MorphospaceTrackedDependencyPath([string]$Importer,[string]$Value,[bool]$DataOnly=$false) {
        $normalized = $Value.Replace('\','/')
        $importerDirectory = [IO.Path]::GetDirectoryName((Join-Path $root $Importer))
        $candidates = [Collections.Generic.List[string]]::new()
        if ($normalized -match '^(?:scripts|tools|schemas|manifests|docs|templates|config|skills)/') { [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $root $normalized))) }
        [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $importerDirectory $normalized)))
        [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $root $normalized)))
        if ($normalized -notmatch '/') { foreach ($directory in @('schemas','manifests','config','templates')) { [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $root (Join-Path $directory $normalized)))) } }
        foreach ($absolute in @($candidates)) {
            if (-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = [IO.Path]::GetRelativePath($root,$absolute).Replace('\','/')
            if (-not $trackedFiles.Contains($relative)) { continue }
            [void]$nodes.Add($relative)
            if ($trackedScripts.Contains($relative)) {
                if ($DataOnly) {
                    $raw = Get-MorphospaceAffectedDependencyBytesSha256 -Bytes ([IO.File]::ReadAllBytes($absolute))
                    if ($parsedSha.ContainsKey($relative) -and $parsedSha[$relative] -cne $raw) { throw "Affected dependency data bytes changed during analysis: $relative" }
                    $parsedSha[$relative] = $raw
                } elseif ($executionQueued.Add($relative)) { $pending.Enqueue($relative) }
            }
            return $relative
        }
        return $null
    }
    function Add-MorphospaceFallback([string]$Importer,[string]$Variable,[string]$Kind) {
        $key = "$Importer|$Variable|$Kind"
        if (-not $fallbackReasons.ContainsKey($key)) { $fallbackReasons[$key] = [pscustomobject][ordered]@{importer=$Importer;variable=$Variable;kind=$Kind} }
    }
    function Use-MorphospaceDeclaration(
        [string]$Importer,
        [string]$Variable,
        [AllowEmptyCollection()][string[]]$ObservedBoundPaths = @()
    ) {
        $key = Get-MorphospaceAffectedDependencyDeclarationKey -Importer $Importer -Variable $Variable
        if (-not $declarations.ContainsKey($key)) { return $false }
        $declaration = $declarations[$key]
        if (@($ObservedBoundPaths).Count -ne 0) {
            if ($declaration.PSObject.Properties.Name -cnotcontains 'target_paths') { throw "Affected dependency declaration does not bind observed static targets: $Importer|$Variable" }
            $declaredTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($target in @($declaration.target_paths)) { [void]$declaredTargets.Add([string]$target) }
            foreach ($observed in @($ObservedBoundPaths)) {
                $observedPath = Add-MorphospaceTrackedDependencyPath -Importer $Importer -Value ([string]$observed)
                if ($null -eq $observedPath -or -not $declaredTargets.Contains([string]$observedPath)) { throw "Affected dependency declaration omits observed static target: $Importer|$Variable -> $observed" }
            }
        }
        $observedDeclarations[$key] = 1 + $(if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 })
        $usedDeclarations[$key] = $declaration
        if ($declaration.PSObject.Properties.Name -ccontains 'target_paths') {
            foreach ($target in @($declaration.target_paths)) {
                if ($null -eq (Add-MorphospaceTrackedDependencyPath -Importer $Importer -Value ([string]$target))) { throw "Affected dependency declaration target is absent from the exact head: $key -> $target" }
            }
        }
        return $true
    }

    $entrypointPath = ConvertTo-MorphospaceAffectedDependencyPath -Path $Entrypoint
    if ($null -eq (Add-MorphospaceTrackedDependencyPath -Importer $entrypointPath -Value $entrypointPath) -or -not $trackedScripts.Contains($entrypointPath)) { throw "Affected check entrypoint is not a tracked PowerShell file: $Entrypoint" }
    $fallbackExpanded = $false
    while ($true) {
        while ($pending.Count -gt 0) {
            $importer = $pending.Dequeue()
            $absolute = Join-Path $root $importer
            [byte[]]$beforeBytes = [IO.File]::ReadAllBytes($absolute)
            $beforeSha = Get-MorphospaceAffectedDependencyBytesSha256 -Bytes $beforeBytes
            if ($parsedSha.ContainsKey($importer) -and $parsedSha[$importer] -cne $beforeSha) { throw "Affected dependency data/execution bytes changed during analysis: $importer" }
            $parsedSha[$importer] = $beforeSha
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput(([Text.UTF8Encoding]::new($false,$true).GetString($beforeBytes)),[ref]$tokens,[ref]$errors)
            if (@($errors).Count -ne 0) { throw "Affected check dependency closure could not parse tracked source: $importer" }
            [void]$executedSources.Add($importer)
            $dataOffsets = Get-MorphospaceAffectedDataReferenceOffsets -ImporterAst $ast
            $literalOffsets = [Collections.Generic.HashSet[int]]::new()
            foreach ($literal in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.(?:ps1|psm1|json|jsonl|ya?ml|toml|md)$' },$true))) {
                if ($null -ne (Add-MorphospaceTrackedDependencyPath -Importer $importer -Value ([string]$literal.Value) -DataOnly ($dataOffsets.Contains([int]$literal.Extent.StartOffset))) -and [string]$literal.Value -match '(?i)\.ps(?:m)?1$') { [void]$literalOffsets.Add([int]$literal.Extent.StartOffset) }
            }
            $assignmentsByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            foreach ($assignment in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] },$true))) {
                $variable = [string]$assignment.Left.VariablePath.UserPath
                $scope = Get-MorphospaceAffectedDependencyLexicalScope -Node $assignment
                if (-not $assignmentsByScope.ContainsKey($scope)) { $assignmentsByScope[$scope] = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase) }
                $assignments = $assignmentsByScope[$scope]
                if (-not $assignments.ContainsKey($variable)) { $assignments[$variable] = [Collections.Generic.List[object]]::new() }
                $pathValues = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.ps(?:m)?1$' },$true) | ForEach-Object { [string]$_.Value })
                $rightText = [string]$assignment.Right.Extent.Text
                $nonPath = $rightText -match '(?i)\b(?:Get-Module|Import-Module|Get-Process)\b'
                if (-not $nonPath -and $rightText.Contains('{')) { $nonPath = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true)).Count -ne 0 }
                $unknownVariables = @($assignment.Right.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.VariableExpressionAst] -and
                    @('PSScriptRoot','true','false','null') -inotcontains [string]$node.VariablePath.UserPath
                },$true)).Count -ne 0
                $unknownCommands = $false
                foreach ($rightCommand in @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true))) {
                    $name = [string]$rightCommand.GetCommandName()
                    if ($name -imatch '(?:^|\\)Join-Path$') { continue }
                    if ($name -imatch '(?:^|\\)Get-Command$' -and @($pathValues).Count -ne 0 -and -not $unknownVariables) { continue }
                    $unknownCommands = $true
                }
                $unclassifiedBinding = -not $nonPath -and (@($pathValues).Count -eq 0 -or $unknownVariables -or $unknownCommands)
                $scriptBlockMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($hashtable in @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] },$true))) {
                    foreach ($pair in @($hashtable.KeyValuePairs)) {
                        $memberName = ([string]$pair.Item1.Extent.Text).Trim("'",'"')
                        $valueText = [string]$pair.Item2.Extent.Text
                        if ($valueText.Contains('{') -and @($pair.Item2.FindAll({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true)).Count -eq 1 -and $valueText -notmatch '(?i)\.ps(?:m)?1') { [void]$scriptBlockMembers.Add($memberName) }
                    }
                }
                [void]([Collections.Generic.List[object]]$assignments[$variable]).Add([pscustomobject][ordered]@{ast=$assignment;scope=$scope;paths=$pathValues;non_path=$nonPath;unclassified_binding=$unclassifiedBinding;scriptblock_members=$scriptBlockMembers})
            }
            $typedScriptBlocksByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            $untypedParametersByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            foreach ($parameter in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.ParameterAst] -and $node.StaticType -eq [scriptblock] },$true))) {
                $scope = Get-MorphospaceAffectedDependencyLexicalScope -Node $parameter
                if (-not $typedScriptBlocksByScope.ContainsKey($scope)) { $typedScriptBlocksByScope[$scope] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
                [void]$typedScriptBlocksByScope[$scope].Add([string]$parameter.Name.VariablePath.UserPath)
            }
            foreach ($parameter in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ParameterAst] -and
                @($node.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] }).Count -eq 0
            },$true))) {
                $scope = Get-MorphospaceAffectedDependencyLexicalScope -Node $parameter
                if (-not $untypedParametersByScope.ContainsKey($scope)) { $untypedParametersByScope[$scope] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
                [void]$untypedParametersByScope[$scope].Add([string]$parameter.Name.VariablePath.UserPath)
            }
            foreach ($command in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true))) {
                $commandName = [string]$command.GetCommandName()
                $isImport = $commandName -match '(?i)(?:^|\\)Import-Module$'
                $isInvocation = $command.InvocationOperator -in @([Management.Automation.Language.TokenKind]::Ampersand,[Management.Automation.Language.TokenKind]::Dot)
                # Content-derived execution is never a static dependency edge. Record
                # it explicitly so it receives the same fail-closed expansion as an
                # unknown variable dispatch; declarations only bind identifier targets.
                $isExpressionInvocation = $commandName -match '(?i)(?:^|\\)(?:Invoke-Expression|iex)$' -or [string]$command.Extent.Text -match '(?i)\[scriptblock\]::Create\s*\('
                if ($isExpressionInvocation) {
                    $expression = if ($commandName -match '(?i)(?:^|\\)(?:Invoke-Expression|iex)$' -and @($command.CommandElements).Count -gt 1) { [string]$command.CommandElements[1].Extent.Text } else { '[scriptblock]::Create' }
                    Add-MorphospaceFallback -Importer $importer -Variable $expression -Kind 'unresolved-expression-invocation'
                    continue
                }
                if (-not $isImport -and -not $isInvocation) { continue }
                $elements = @($command.CommandElements); $first = $elements[0]
                $literalSearchRoot = if ($isInvocation) { $first } else { $command }
                $trackedLiteral = @($literalSearchRoot.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $literalOffsets.Contains([int]$node.Extent.StartOffset) },$true)).Count -ne 0
                if ($trackedLiteral) { continue }
                if ($isImport -and @($elements | Select-Object -Skip 1).Count -eq 1 -and $elements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$elements[1].Value -notmatch '[\\/]|(?i)\.psm1$') { continue }
                if ($isInvocation -and ($first -is [Management.Automation.Language.StringConstantExpressionAst] -or $first -is [Management.Automation.Language.ScriptBlockExpressionAst])) { continue }
                $variable = $null
                $memberInvocationUnclassified = $false
                if ($isInvocation -and $first -is [Management.Automation.Language.MemberExpressionAst] -and [string]$first.Extent.Text -match '(?i)\.Source$') {
                    $getCommandNodes = @($first.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -imatch '(?:^|\\)Get-Command$' },$true))
                    if ($getCommandNodes.Count -eq 1) {
                        $variableNodes = @($getCommandNodes[0].FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -ine 'PSScriptRoot' },$true))
                        if ($variableNodes.Count -eq 1) { $variable = [string]$variableNodes[0].VariablePath.UserPath; $memberInvocationUnclassified = $true }
                        elseif ($variableNodes.Count -eq 0 -and @($getCommandNodes[0].FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.ps(?:m)?1$' },$true)).Count -eq 0) { continue }
                    }
                }
                if ($null -eq $variable -and $isInvocation -and $first -is [Management.Automation.Language.MemberExpressionAst] -and $first.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $first.Member -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    $receiverVariable = [string]$first.Expression.VariablePath.UserPath
                    $memberName = [string]$first.Member.Value
                    $memberProven = $false
                    $memberAmbiguous = $false
                    $invocationScope = Get-MorphospaceAffectedDependencyLexicalScope -Node $command
                    foreach ($scope in @(Get-MorphospaceAffectedDependencyScopeChain -Scope $invocationScope)) {
                        if (-not $assignmentsByScope.ContainsKey($scope) -or -not $assignmentsByScope[$scope].ContainsKey($receiverVariable)) { continue }
                        foreach ($record in @($assignmentsByScope[$scope][$receiverVariable])) {
                            if (-not (Test-MorphospaceAffectedDependencyAssignmentDefinite -Assignment $record.ast -AssignmentScope $record.scope -Invocation $command -InvocationScope $invocationScope) -or -not $record.scriptblock_members.Contains($memberName)) { $memberAmbiguous = $true }
                            else { $memberProven = $true }
                        }
                    }
                    if ($memberProven -and -not $memberAmbiguous) { continue }
                    $variable = $receiverVariable
                    $memberInvocationUnclassified = $true
                }
                if ($null -eq $variable -and $first -is [Management.Automation.Language.VariableExpressionAst]) { $variable = [string]$first.VariablePath.UserPath }
                elseif ($isImport) {
                    $variableNodes = @($command.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -cne 'PSScriptRoot' },$true))
                    if ($variableNodes.Count -eq 1) { $variable = [string]$variableNodes[0].VariablePath.UserPath }
                }
                if (-not [string]::IsNullOrWhiteSpace($variable)) {
                    $boundPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    $nonPath = $false
                    $unclassifiedBinding = $memberInvocationUnclassified
                    $typedScriptBlock = $false
                    $invocationScope = Get-MorphospaceAffectedDependencyLexicalScope -Node $command
                    foreach ($scope in @(Get-MorphospaceAffectedDependencyScopeChain -Scope $invocationScope)) {
                        if ($assignmentsByScope.ContainsKey($scope)) {
                            $scopeAssignments = $assignmentsByScope[$scope]
                            if ($scopeAssignments.ContainsKey($variable)) {
                                foreach ($record in @($scopeAssignments[$variable])) {
                                    foreach ($value in @($record.paths)) { [void]$boundPaths.Add([string]$value) }
                                    if ([bool]$record.non_path) { $nonPath=$true }
                                    if ([bool]$record.unclassified_binding) { $unclassifiedBinding=$true }
                                    if (-not (Test-MorphospaceAffectedDependencyAssignmentDefinite -Assignment $record.ast -AssignmentScope $record.scope -Invocation $command -InvocationScope $invocationScope)) { $unclassifiedBinding=$true }
                                }
                            }
                        }
                        if ($typedScriptBlocksByScope.ContainsKey($scope) -and $typedScriptBlocksByScope[$scope].Contains($variable)) { $typedScriptBlock=$true }
                        if ($untypedParametersByScope.ContainsKey($scope) -and $untypedParametersByScope[$scope].Contains($variable)) { $unclassifiedBinding=$true }
                    }
                    # A literal assignment cannot make a variable invocation exact when
                    # another applicable assignment has no classified path or callable
                    # shape. A closed declaration may bind that whole dispatch; absent
                    # one, bind every tracked script so reuse cannot omit the unknown
                    # target's imported bytes.
                    if ($unclassifiedBinding) {
                        [string[]]$observedBoundPaths = @($boundPaths | ForEach-Object { [string]$_ })
                        if (Use-MorphospaceDeclaration -Importer $importer -Variable $variable -ObservedBoundPaths $observedBoundPaths) { continue }
                        Add-MorphospaceFallback -Importer $importer -Variable $variable -Kind $(if($boundPaths.Count -eq 0){$(if($isImport){'unresolved-import'}else{'unresolved-invocation'})}else{'ambiguous-static-binding'})
                        continue
                    }
                    if ($boundPaths.Count -eq 1) { [void](Add-MorphospaceTrackedDependencyPath -Importer $importer -Value ([string]@($boundPaths)[0])); continue }
                    if ($boundPaths.Count -gt 1) { Add-MorphospaceFallback -Importer $importer -Variable $variable -Kind 'ambiguous-static-binding'; continue }
                    if ($nonPath -or $typedScriptBlock) { continue }
                    if (Use-MorphospaceDeclaration -Importer $importer -Variable $variable) { continue }
                    Add-MorphospaceFallback -Importer $importer -Variable $variable -Kind $(if($isImport){'unresolved-import'}else{'unresolved-invocation'})
                    continue
                }
                Add-MorphospaceFallback -Importer $importer -Variable ([string]$first.Extent.Text) -Kind $(if($isImport){'unresolved-import'}else{'unresolved-invocation'})
            }
            # ScriptBlock invocation methods are expression ASTs rather than command
            # ASTs. They may execute content constructed at runtime, so do not let
            # them retain an exact dependency closure merely because no '&' appears.
            foreach ($memberInvocation in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
            },$true))) {
                $memberName = if ($memberInvocation.Member -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$memberInvocation.Member.Value } else { '' }
                if ($memberInvocation.Static -and $memberInvocation.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $memberInvocation.Expression.TypeName.FullName -imatch '^(?:System\.Management\.Automation\.)?ScriptBlock$') {
                    Add-MorphospaceFallback -Importer $importer -Variable $(if($memberName){'scriptblock-method:'+$memberName}else{'scriptblock-method:dynamic'}) -Kind 'unresolved-expression-invocation'
                }
                if ($memberName -match '^(?:Invoke(?:ReturnAsIs|WithContext)?|DynamicInvoke|GetScriptBlock)$') {
                    Add-MorphospaceFallback -Importer $importer -Variable ("scriptblock-method:" + $memberName) -Kind 'unresolved-expression-invocation'
                }
            }
            [byte[]]$afterBytes = [IO.File]::ReadAllBytes($absolute)
            if ((Get-MorphospaceAffectedDependencyBytesSha256 -Bytes $afterBytes) -cne $beforeSha) { throw "Affected dependency source bytes changed during analysis: $importer" }
        }
        if ($fallbackReasons.Count -eq 0 -or $fallbackExpanded) { break }
        $fallbackExpanded = $true
        # Unknown dispatch remains fail-closed by binding and inspecting every
        # tracked script. This also retains non-script inputs named by any
        # possible target; declared consume path sets remain an independent
        # exact input boundary rather than a substitute for dynamic closure.
        foreach ($path in @($trackedScripts)) { [void]$nodes.Add([string]$path); if ($executionQueued.Add([string]$path)) { $pending.Enqueue([string]$path) } }
    }
    foreach ($key in @($declarations.Keys)) {
        $declaration = $declarations[$key]
        if (-not $executedSources.Contains([string]$declaration.importer)) { continue }
        $expected = [int]$declaration.count
        $observed = if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 }
        if ($observed -ne $expected) { throw "Affected dependency declaration count changed: $key expected=$expected observed=$observed" }
        $usedDeclarations[$key] = $declaration
    }
    foreach ($path in @($parsedSha.Keys)) {
        $current = Get-MorphospaceAffectedDependencyBytesSha256 -Bytes ([IO.File]::ReadAllBytes((Join-Path $root $path)) )
        if ($current -cne [string]$parsedSha[$path]) { throw "Affected dependency source bytes changed after analysis: $path" }
    }
    [string[]]$orderedPaths = @($nodes); [Array]::Sort($orderedPaths,[StringComparer]::Ordinal)
    [object[]]$orderedDeclarations = @($usedDeclarations.Values)
    if ($orderedDeclarations.Count -gt 1) { [Array]::Sort($orderedDeclarations,[Collections.Generic.Comparer[object]]::Create({param($l,$r)[StringComparer]::Ordinal.Compare("$($l.importer)|$($l.variable)","$($r.importer)|$($r.variable)" )})) }
    [object[]]$orderedReasons = @($fallbackReasons.Values)
    if ($orderedReasons.Count -gt 1) { [Array]::Sort($orderedReasons,[Collections.Generic.Comparer[object]]::Create({param($l,$r)[StringComparer]::Ordinal.Compare("$($l.importer)|$($l.variable)|$($l.kind)","$($r.importer)|$($r.variable)|$($r.kind)")})) }
    return [pscustomobject][ordered]@{
        paths=@($orderedPaths)
        resolution=[pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.affected_validation_dependency_resolution.v1'
            algorithm='indexed-static-closure-v1'
            mode=$(if($fallbackReasons.Count -eq 0){'exact'}else{'all-tracked-scripts-fallback'})
            entrypoint=$entrypointPath
            used_declarations=@($orderedDeclarations)
            fallback_reasons=@($orderedReasons)
        }
    }
}

Export-ModuleMember -Function Resolve-MorphospaceAffectedCheckDependencyClosure
