#requires -version 2.0
# ALSO REQUIRES Autoload for some functionality (Latest version: http://poshcode.org/3173)
# You should create a Reflection.psd1 with the contents: 
#    @{ ModuleToProcess="Reflection.psm1"; RequiredModules = @("Autoload"); GUID="64b5f609-970f-4e65-b02f-93ccf3e60cbb"; ModuleVersion="4.5.0.0" }
#History:
# 1.0  - First public release (March 19, 2010)
# 2.0  - Private Build
#      - Included the Accelerator function inline
#      - Added a few default aliases
# 3.0  - September 3, 2010
#      - Included the New-ConstructorFunction feature (ripped from PowerBoots to serve a more generic and powerful purpose!)
#      - New-ConstructorFunction and Import-ConstructorFunctions depend on the Autoload Module: http://poshcode.org/2312
# 3.5  - January 28, 2011
#      - Fixed several bugs in Add-Assembly, Get-Assembly, Get-MemberSignature
#      - Fixed alias exporting so aliases will show up now
#      - Added New-ModuleManifestFromSnapin to create module manifests from snapin assemblies
# 3.6  - January 28, 2011
#      - Added *basic* support for CustomPSSnapin to New-ModuleManifestFromSnapin
# 3.7  - February 1, 2001 - NOT RELEASED
#      - Added [TransformAttribute] type
# 3.8  - May 4, 2011 - NOT RELEASED
#      - Huge rewrite of Invoke-Generic (also published separately: http://poshcode.org/2649)
# 3.9  - May 25, 2011 - NOT RELEASED
#      - Added "Interface" parameter to Get-Type
# 4.0  - Sept 27, 2011
#      - Fix conflicts with PowerShell 3
# 4.1  - Oct 27, 2011
#      - Fix PowerShell 3 changes so they don't break PowerShell 2 (huy!)
# 4.2  - Added Add-Enum and Add-Struct -- even though they're really more CodeGen than reflection
#
# 4.5  - March 2, 2013
#      - Added Test-AssignableToGeneric and Get-ExtensionMethod
#      - Updated Read-Choice from the standalone script I use.

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Management.Automation;
using System.Collections.ObjectModel;

[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public class TransformAttribute : ArgumentTransformationAttribute {
   private ScriptBlock _scriptblock;
   private string _noOutputMessage = "Transform Script had no output.";

   public override string ToString() {
      return string.Format("[Transform(Script='{{{0}}}')]", Script);
   }

   public override Object Transform( EngineIntrinsics engine, Object inputData) {
      try {
         Collection<PSObject> output = 
            engine.InvokeCommand.InvokeScript( engine.SessionState, Script, inputData );
         
         if(output.Count > 1) {
            Object[] transformed = new Object[output.Count];
            for(int i =0; i < output.Count;i++) {
               transformed[i] = output[i].BaseObject;
            }
            return transformed;
         } else if(output.Count == 1) {
            return output[0].BaseObject;
         } else {
            throw new ArgumentTransformationMetadataException(NoOutputMessage);
         }
      } catch (ArgumentTransformationMetadataException) {
         throw;
      } catch (Exception e) {
         throw new ArgumentTransformationMetadataException(string.Format("Transform Script threw an exception ('{0}'). See `$Error[0].Exception.InnerException.InnerException for more details.",e.Message), e);
      }
   }
   
   public TransformAttribute() {
      this.Script = ScriptBlock.Create("{`$args}");
   }
   
   public TransformAttribute( ScriptBlock Script ) {
      this.Script = Script;
   }

   public ScriptBlock Script {
      get { return _scriptblock; }
      set { _scriptblock = value; }
   }
   
   public string NoOutputMessage {
      get { return _noOutputMessage; }
      set { _noOutputMessage = value; }
   }   
}
"@ 



function Get-Type {
   <#
      .Synopsis
         Gets the types that are currenty loaded in .NET, or gets information about a specific type
      .Description
         Gets information about one or more loaded types, or gets the possible values for an enumerated type or value.    
      .Example
         Get-Type
          
         Gets all loaded types (takes a VERY long time to print out)
      .Example
         Get-Type -Assembly ([PSObject].Assembly)
          
         Gets types from System.Management.Automation
      .Example
         [Threading.Thread]::CurrentThread.ApartmentState | Get-Type
          
         Gets all of the possible values for the ApartmentState property
      .Example
         [Threading.ApartmentState] | Get-Type
          
         Gets all of the possible values for an apartmentstate
   #>
   [CmdletBinding(DefaultParameterSetName="Assembly")]   
   param(
      # The Assemblies to search for types.
      # Can be an actual Assembly object or a regex to pass to Get-Assembly.
      [Parameter(ValueFromPipeline=$true)]
      [PsObject[]]$Assembly,

      # The type name(s) to search for (wildcard patterns allowed).
      [Parameter(Mandatory=$false,Position=0)]
      [SupportsWildCards()]
      [String[]]$TypeName,

      # A namespace to restrict where we selsect types from (wildcard patterns allowed).
      [Parameter(Mandatory=$false)]
      [SupportsWildCards()]
      [String[]]$Namespace,

      # A Base type they should derive from (wildcard patterns allowed).
      [Parameter(Mandatory=$false)]
      [SupportsWildCards()]
      [String[]]$BaseType,

      # An interface they should implement (wildcard patterns allowed).
      [Parameter(Mandatory=$false)]
      [SupportsWildCards()]
      [String[]]$Interface,

      # An Custom Attribute which should decorate the class
      [Parameter(Mandatory=$false)]
      [SupportsWildCards()]
      [String[]]$Attribute,


      # The enumerated value to get all of the possible values of
      [Parameter(ParameterSetName="Enum")]
      [PSObject]$Enum, 

      # Causes Private types to be included
      [Parameter()][Alias("Private","ShowPrivate")]
      [Switch]$Force
   )

   process {
      if($psCmdlet.ParameterSetName -eq 'Enum') {
         if($Enum -is [Enum]) {
            [Enum]::GetValues($enum.GetType())
         } elseif($Enum -is [Type] -and $Enum.IsEnum) {
            [Enum]::GetValues($enum)
         } else {
            throw "Specified Enum is neither an enum value nor an enumerable type"
         }
      }
      else {
         if($Assembly -as [Reflection.Assembly[]]) { 
            ## This is what we expected, move along
         } elseif($Assembly -as [String[]]) {
            $Assembly = Get-Assembly $Assembly
         } elseif(!$Assembly) {
            $Assembly = [AppDomain]::CurrentDomain.GetAssemblies()
         }

         :asm foreach ($asm in $assembly) {
            Write-Verbose "Testing Types from Assembly: $($asm.Location)"
            if ($asm) { 
               trap {
                  if( $_.Exception.LoaderExceptions -and $_.Exception.LoaderExceptions[0] -is [System.IO.FileNotFoundException] ) {
                     $PSCmdlet.WriteWarning( "Unable to load some types from $($asm.Location), required assemblies were not found. Use -Debug to see more detail")
                     continue asm
                  }
                  Write-Error "Unable to load some types from $($asm.Location). Try with -Debug to see more detail"
                  Write-Debug $( $_.Exception.LoaderExceptions | Out-String )
                  continue asm
               }
               $asm.GetTypes() | Where {
                  ( $Force -or $_.IsPublic ) -AND
                  ( !$Namespace -or $( foreach($n in $Namespace) { $_.Namespace -like $n  } ) ) -AND
                  ( !$TypeName -or $( foreach($n in $TypeName) { $_.Name -like $n -or $_.FullName -like $n } ) -contains $True ) -AND
                  ( !$Attribute -or $( foreach($n in $Attribute) { $_.CustomAttributes | ForEach { $_.AttributeType.Name -like $n -or $_.AttributeType.FullName -like $n } } ) -contains $True ) -AND
                  ( !$BaseType -or $( foreach($n in $BaseType) { $_.BaseType -like $n } ) -contains $True ) -AND
                  ( !$Interface -or @( foreach($n in $Interface) { $_.GetInterfaces() -like $n } ).Count -gt 0 )
               }
            }
         }
      }
   }
}

function Add-Assembly {
   #.Synopsis
   #  Load assemblies 
   #.Description
   #  Load assemblies from a folder
   #.Parameter Path
   #  Specifies a path to one or more locations. Wildcards are permitted. The default location is the current directory (.).
   #.Parameter Passthru
   #  Returns System.Runtime objects that represent the types that were added. By default, this cmdlet does not generate any output.
   #  Aliased to -Types
   #.Parameter Recurse
   #  Gets the items in the specified locations and in all child items of the locations.
   # 
   #  Recurse works only when the path points to a container that has child items, such as C:\Windows or C:\Windows\*, and not when it points to items that do not have child items, such as C:\Windows\*.dll
   [CmdletBinding()]
   param(
      [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true, Position=0)]
      [Alias("PSPath")]
      [string[]]$Path = ".",

      [Alias("Types")]
      [Switch]$Passthru,

      [Switch]$Recurse
   )
   process {
      foreach($file in Get-ChildItem $Path -Filter *.dll -Recurse:$Recurse) {
         Add-Type -Path $file.FullName -Passthru:$Passthru | Where { $_.IsPublic }
      }
   }
}

function Get-Assembly {
   <#
   .Synopsis 
      Get a list of assemblies available in the runspace
   .Description
      Returns AssemblyInfo for all the assemblies available in the current AppDomain, optionally filtered by partial name match
   .Parameter Name
      A regex to filter the returned assemblies. This is matched against the .FullName or Location (path) of the assembly.
   #>
   [CmdletBinding()]
   param(
      [Parameter(ValueFromPipeline=$true, Position=0)]
      [string[]]$Name = ''
   )
   process {
      [appdomain]::CurrentDomain.GetAssemblies() | Where {
         $Assembly = $_
         if($Name){ 
            $(
               foreach($n in $Name){
                  if(Resolve-Path $n -ErrorAction 0) {
                     $n = [Regex]::Escape( (Resolve-Path $n).Path )
                  }
                  $Assembly.FullName -match $n -or $Assembly.Location -match $n -or ($Assembly.Location -and (Split-Path $Assembly.Location) -match $n)
               }
            ) -contains $True 
         } else { $true }
      }         
   }
}

function Update-PSBoundParameters { 
   #.Synopsis
   #  Ensure a parameter value is set
   #.Description
   #  Update-PSBoundParameters takes the name of a parameter, a default value, and optionally a min and max value, and ensures that PSBoundParameters has a value for it.
   #.Parameter Name
   #  The name (key) of the parameter you want to set in PSBoundParameters
   #.Parameter Default
   #  A Default value for the parameter, in case it's not already set
   #.Parameter Min
   #  The Minimum allowed value for the parameter
   #.Parameter Max
   #  The Maximum allowed value for the parameter
   #.Parameter PSBoundParameters
   #  The PSBoundParameters you want to affect (this picks the local PSBoundParameters object, so you shouldn't have to set it)
   Param(
      [Parameter(Mandatory=$true,  Position=0)]
      [String]$Name,

      [Parameter(Mandatory=$false, Position=1)]
      $Default,

      [Parameter()]
      $Min,

      [Parameter()]
      $Max,

      [Parameter(Mandatory=$true, Position=99)]
      $PSBoundParameters=$PSBoundParameters
   )
   end {
      $outBuffer = $null
      ## If it's not set, and you passed a default, we set it to the default
      if($Default) {
         if (!$PSBoundParameters.TryGetValue($Name, [ref]$outBuffer))
         {
            $PSBoundParameters[$Name] = $Default
         }
      }
      ## If you passed a $max, and it's set greater than $max, we set it to $max
      if($Max) {
         if ($PSBoundParameters.TryGetValue($Name, [ref]$outBuffer) -and $outBuffer -gt $Max)
         {
            $PSBoundParameters[$Name] = $Max
         }
      }
      ## If you passed a $min, and it's set less than $min, we set it to $min
      if($Min) {
         if ($PSBoundParameters.TryGetValue($Name, [ref]$outBuffer) -and $outBuffer -lt $Min)
         {
            $PSBoundParameters[$Name] = $Min
         }
      }
      $PSBoundParameters
   }
}

function Get-Constructor {
   <#
   .Synopsis 
      Returns RuntimeConstructorInfo for the (public) constructor methods of the specified Type.
   .Description
      Get the RuntimeConstructorInfo for a type and add members "Syntax," "SimpleSyntax," and "Definition" to each one containing the syntax information that can use to call that constructor.
   .Parameter Type
      The type to get the constructor for
   .Parameter Force
      Force inclusion of Private and Static constructors which are hidden by default.
   .Parameter NoWarn
      Serves as the replacement for the broken -WarningAction. If specified, no warnings will be written for types without public constructors.
   .Example
      Get-Constructor System.IO.FileInfo
      
      Description
      -----------
      Gets all the information about the single constructor for a FileInfo object. 
   .Example
      Get-Type System.IO.*info mscorlib | Get-Constructor -NoWarn | Select Syntax
      
      Description
      -----------
      Displays the constructor syntax for all of the *Info objects in the System.IO namespace. 
      Using -NoWarn supresses the warning about System.IO.FileSystemInfo not having constructors.
     
   .Example
      $path = $pwd
      $driveName = $pwd.Drive
      $fileName = "$Profile"
      Get-Type System.IO.*info mscorlib | Get-Constructor -NoWarn | ForEach-Object { Invoke-Expression $_.Syntax }
      
      Description
      -----------
      Finds and invokes the constructors for DirectoryInfo, DriveInfo, and FileInfo.
      Note that we pre-set the parameters for the constructors, otherwise they would fail with null arguments, so this example isn't really very practical.


   #>
   [CmdletBinding()]
   param( 
      [Parameter(Mandatory=$true, ValueFromPipeline=$True, ValueFromPipelineByPropertyName=$true, Position=0)]
      [Alias("ParameterType")]
      [Type]$Type,
      [Switch]$Force,
      [Switch]$NoWarn
   )
   process { 
      $type.GetConstructors() | Where-Object { $Force -or $_.IsPublic -and -not $_.IsStatic } -OutVariable ctor 
      if(!$ctor -and !$NoWarn) { Write-Warning "There are no public constructors for $($type.FullName)" }
   }
}

function Get-ExtensionMethod {
   <#
      .Synopsis
         Finds Extension Methods which target the specified type
      .Example
         Get-ExtensionMethod String

         Finds all extension methods which target strings
   #>
   [CmdletBinding()]
   param(
      # The type name to find Extension Methods for
      [Parameter(Mandatory=$false,Position=0)]
      [SupportsWildCards()]
      [String[]]$TargetTypeName,

      # A filter for the Extension Method name 
      [Parameter(Mandatory=$false)]
      [SupportsWildCards()]
      [String[]]$Name = "*",

      # The type to search for Extension Methods (defaults to search all types)
      [Parameter(Mandatory=$false,Position=99)]
      [SupportsWildCards()]
      [String[]]$TypeName = "*"
   )
   process {
      Get-Type -TypeName $TypeName -Attribute ExtensionAttribute | 
         Get-Method -Name $Name -BindingFlags "Static,Public,NonPublic" -Attribute ExtensionAttribute |
         ForEach-Object { 
            $Method = $_
            $ParameterType = $_.GetParameters()[0].ParameterType

            ForEach($T in $TargetTypeName) {
               Write-Verbose "Is '$T' a '$ParameterType'?"
               if($ParameterType.Name -like $T -or $ParameterType.FullName -like $T) {
                  Write-Verbose "The name '$T' matches '$ParameterType'"
                  Add-Member -Input $Method -Type NoteProperty -Name ParamBlock -Value (Get-MemberSignature $Method -ParamBlock) -Force
                  Write-Output $Method
                  continue
               }
               
               if($ParameterType.IsGenericType) {
                  $interface = $null
                  if(Test-AssignableToGeneric $T $ParameterType -interface ([ref]$interface)) {
                  # if([GenericHelper]::IsAssignableToGenericType( $T, $ParameterType )) {
                     Write-Verbose "'$T' is a generic that's assignable to '$ParameterType'"
                     Add-Member -Input $Method -Type NoteProperty -Name Extends -Value $interface.Value -Force
                     Add-Member -Input $Method -Type NoteProperty -Name ParamBlock -Value (Get-MemberSignature $Method -GenericArguments $interface.GetGenericArguments() -ParamBlock) -Force
                     Write-Output $Method
                     continue
                  }
               } else {
                  if($ParameterType.IsAssignableFrom($T)) {
                     Write-Verbose "'$ParameterType' is assignable from '$T'"
                     Add-Member -Input $Method -Type NoteProperty -Name ParamBlock -Value (Get-MemberSignature $Method -ParamBlock) -Force
                     Write-Output $Method
                     continue
                  }     
               }
            }
         }
   }
}

function Test-AssignableToGeneric { 
   <#
      .Synopsis
         Determine if a specific type can be cast to the given generic type
   #>
   param(
      # The concrete type you want to test generics against
      [Parameter(Position=0, Mandatory = $true)]
      [Type]$type,

      # A Generic Type to test 
      [Parameter(ValueFromPipeline=$true, Position=1, Mandatory = $true)]
      [Type]$genericType,

      # Check the GenericTypeDefinition of the GenericType (in case it's typed)
      [Switch]$force,

      # If the type is assignable because of an interface, return that interface here
      [Parameter(Position=2)]
      [ref]$interface = [ref]$null
   )

   process {
      $interfaces = $type.GetInterfaces()
      if($type.IsGenericType -and ($type.GetGenericTypeDefinition().equals($genericType))) {
         return $true
      }

      foreach($i in $interfaces) 
      { 
         if($i.IsGenericType -and $i.GetGenericTypeDefinition().Equals($genericType)) {
            $interface.Value = $i
            return $true
         }
         if($i.IsGenericType -and $i.GetGenericTypeDefinition().Equals($genericType.GetGenericTypeDefinition())) {
            $genericTypeArgs = @($genericType.GetGenericArguments())[0]
            if(($genericTypeArgs.IsGenericParameter -and 
                $genericTypeArgs.BaseType.IsAssignableFrom( @($i.GetGenericArguments())[0] ) ) -or 
               $genericTypeArgs.IsAssignableFrom( @($i.GetGenericArguments())[0] )) {
               
               $interface.Value = $i
               return $true
            }
         }
      }
      if($force -and $genericType -ne $genericType.GetGenericTypeDefinition()) {
         if(Test-AssignableToGeneric $type $genericType.GetGenericTypeDefinition()) {
            return $true
         }
      }

      $base = $type.BaseType
      if(!$base) { return $false }

      Test-AssignableToGeneric $base $genericType
   }
}

function Get-Method {
   <#
   .Synopsis 
      Returns MethodInfo for the (public) methods of the specified Type.
   .Description
      Get the MethodInfo for a type and add members "Syntax," "SimpleSyntax," and "Definition" to each one containing the syntax information that can use to call that method.
   .Parameter Type
   .Parameter Name
      
   .Parameter Force
   #>
   [CmdletBinding(DefaultParameterSetName="Type")]
   param( 
      # The type to get methods from
      [Parameter(ParameterSetName="Type", Mandatory=$true, ValueFromPipeline=$True, ValueFromPipelineByPropertyName=$true, Position=0)]
      [Type]$Type,
      # The name(s) of the method(s) you want to retrieve (Accepts Wildcard Patterns)
      [Parameter(Mandatory=$false, Position=1)]
      [SupportsWildCards()]
      [PSDefaultValue(Help='*')]
      [String[]]$Name ="*",
      # Force inclusion of Private methods and property accessors which are hidden by default.
      [Switch]$Force,
      # The Binding Flags filter the output. defaults to returning all methods, static or instance
      [PSDefaultValue(Help='Instance,Static,Public')]
      [System.Reflection.BindingFlags]$BindingFlags = $(if($Force){"Instance,Static,Public,NonPublic"} else {"Instance,Static,Public"}),

      # An Custom Attribute which should decorate the class
      [Parameter(Mandatory=$false)]
      [SupportsWildCards()]
      [String[]]$Attribute

   )
   process {
      Write-Verbose "[$($type.FullName)].GetMethods(`"$BindingFlags`")"
      Write-Verbose "[$($type.FullName)].GetConstructors(`"$BindingFlags`")"
      Write-Verbose "Filter by Name -like '$Name'"

      
      $Type.GetMethods($BindingFlags) + $type.GetConstructors($BindingFlags) | Where-Object {
         # Hide the Property accessor methods
         ($Force -or !$_.IsSpecialName -or $_.Name -notmatch "^get_|^set_") -AND 
         # And Filter by Name, if necessary 
         ($Name -eq "*" -or ($( foreach($n in $Name) { $_.Name -like $n } ) -contains $True)) -AND
         (!$Attribute -or $( foreach($n in $Attribute) { $_.CustomAttributes | ForEach { $_.AttributeType.Name -like $n -or $_.AttributeType.FullName -like $n } } ) -contains $True ) 
      }
   }
}




if(!($RMI = Get-TypeData System.Reflection.RuntimeMethodInfo) -or !$RMI.Members.ContainsKey("TypeName")) {
   Update-TypeData -TypeName System.Reflection.RuntimeMethodInfo -MemberName "TypeName" -MemberType ScriptProperty -Value { $this.ReflectedType.FullName }
   Update-TypeData -TypeName System.Reflection.RuntimeMethodInfo -MemberName "Definition" -MemberType ScriptProperty -Value { Get-MemberSignature $this -Simple }
   Update-TypeData -TypeName System.Reflection.RuntimeMethodInfo -MemberName "Syntax" -MemberType AliasProperty -Value "Definition"
   Update-TypeData -TypeName System.Reflection.RuntimeMethodInfo -MemberName "SafeSyntax" -MemberType ScriptProperty -Value { Get-MemberSignature $this }
}

function Get-MemberSignature {
   <#
      .Synopsis
         Get the powershell signature for calling a member.
   #>
   [CmdletBinding(DefaultParameterSetName="CallSignature")]
   param(
      # The Method we're getting the signature for
      [Parameter(ValueFromPipeline=$true,Mandatory=$true,Position=0)]
      [System.Reflection.MethodBase]$MethodBase,

      [Parameter(Mandatory=$false, Position=1)]
      [Type[]]$GenericArguments,
      
      # Return the simplified markup
      [Parameter(ParameterSetName="CallSignature")]
      [Switch]$Simple,
      
      # Return a param block
      [Parameter(ParameterSetName="ParamBlock")]
      [Switch]$ParamBlock
   )
   process {
      if($PSCmdlet.ParameterSetName -eq "ParamBlock") { $Simple = $true }

      $parameters = $(
         foreach($param in $MethodBase.GetParameters()) {
            # Write-Host $param.ParameterType.FullName.TrimEnd('&'), $param.Name -fore cyan
   		   # Write-Verbose "$($param.ParameterType.UnderlyingSystemType.FullName) - $($param.ParameterType)"
            $paramType = $param.ParameterType

            Write-Verbose "$(if($paramType.IsGenericType){'Generic: '})$($GenericArguments)"
            if($paramType.IsGenericType -and $GenericArguments) {
               try {
                  $paramType = $paramType.GetGenericTypeDefinition().MakeGenericType( $GenericArguments )
               } catch { continue }
            }
         
            if($paramType.Name.EndsWith('&')) { $ref = '[ref]' } else { $ref = '' }
            if($paramType.IsArray) { $array = ',' } else { $array = '' }
            if($ParamBlock) { 
               '[Parameter(Mandatory=$true)]{0}[{1}]${2}' -f $ref, $paramType.ToString().TrimEnd('&'), $param.Name
            } elseif($Simple) { 
               '[{0}] {2}' -f $paramType.ToString().TrimEnd('&'), $param.Name
            } else {
               '{0}({1}[{2}]${3})' -f $ref, $array, $paramType.ToString().TrimEnd('&'), $param.Name
            }
         }
      )
      if($PSCmdlet.ParameterSetName -eq "ParamBlock") {
         $parameters -join ', '
      } elseif($MethodBase.IsConstructor) {
         "New-Object $($MethodBase.ReflectedType.FullName) $($parameters -join ', ')"
      } elseif($Simple) {
         "$($MethodBase.ReturnType.FullName) $($MethodBase.Name)($($parameters -join ', '))"
      } elseif($MethodBase.IsStatic) {
         "[$($MethodBase.ReturnType.FullName)] [$($MethodBase.ReflectedType.FullName)]::$($MethodBase.Name)($($parameters -join ', '))"
      } else {
         "[$($MethodBase.ReturnType.FullName)] `$$($MethodBase.ReflectedType.Name)Object.$($MethodBase.Name)($($parameters -join ', '))"
      }
   }
}

function Read-Choice {
   [CmdletBinding()]
   param(
      [Parameter(Mandatory=$true, ValueFromRemainingArguments=$true)]
      [hashtable[]]$Choices,

      [Parameter(Mandatory=$False)]
      [string]$Caption = "Please choose!",

      [Parameter(Mandatory=$False)]
      [string]$Message = "Choose one of the following options:",

      [Parameter(Mandatory=$False)]
      [int[]]$Default  = 0,

      [Switch]$MultipleChoice,

      [Switch]$Passthru
   )
   begin {
      [System.Collections.DictionaryEntry[]]$choices = $choices | % { $_.GetEnumerator() }
   }
   process {
      $Descriptions = [System.Management.Automation.Host.ChoiceDescription[]]( $(
                        foreach($choice in $choices) {
                           New-Object System.Management.Automation.Host.ChoiceDescription $choice.Key,$choice.Value
                        } 
                      ) )

      if(!$MultipleChoice) { [int]$Default = $Default[0] }

      [int[]]$Answer = $Host.UI.PromptForChoice($Caption,$Message,$Descriptions,$Default)

      if($Passthru) {
         Write-Verbose "$Answer"
         Write-Output  $Descriptions[$Answer]
      } else {
         Write-Output $Answer
      }
   }
}

function Read-Choice {
   <#
      .Synopsis
        Prompt the user for a choice, and return the (0-based) index of the selected item
      .Parameter Message
        This is the prompt that will be presented to the user. Basically, the question you're asking.
      .Parameter Choices
        An array of strings representing the choices (or menu items), with optional ampersands (&) in them to mark (unique) characters which can be used to select each item.
      .Parameter ChoicesWithHelp
        A Hashtable where the keys represent the choices (or menu items), with optional ampersands (&) in them to mark (unique) characters which can be used to select each item, and the values represent help text to be displayed to the user when they ask for help making their decision.
      .Parameter Default
        The (0-based) index of the menu item to select by default (defaults to zero).
      .Parameter MultipleChoice
        Prompt the user to select more than one option. This changes the prompt display for the default PowerShell.exe host to show the options in a column and allows them to choose multiple times.
        Note: when you specify MultipleChoice you may also specify multiple options as the default!
      .Parameter Caption
        An additional caption that can be displayed (usually above the Message) as part of the prompt
      .Parameter Passthru
        Causes the Choices objects to be output instead of just the indexes
      .Example
        Read-Choice "WEBPAGE BUILDER MENU"  "&Create Webpage","&View HTML code","&Publish Webpage","&Remove Webpage","E&xit"
      .Example
        [bool](Read-Choice "Do you really want to do this?" "&No","&Yes" -Default 1)
        
        This example takes advantage of the 0-based index to convert No (0) to False, and Yes (1) to True. It also specifies YES as the default, since that's the norm in PowerShell.
      .Example
        Read-Choice "Do you really want to delete them all?" @{"&No"="Do not delete all files. You will be prompted to delete each file individually."; "&Yes"="Confirm that you want to delete all of the files"}
        
        Note that with hashtables, order is not guaranteed, so "Yes" will probably be the first item in the prompt, and thus will output as index 0.  Because of thise, when a hashtable is passed in, we default to Passthru output.
   #>
   [CmdletBinding(DefaultParameterSetName="HashtableWithHelp")]
   param(
      [Parameter(Mandatory=$true, Position = 10, ParameterSetName="HashtableWithHelp")]
      [Hashtable]$ChoicesWithHelp
   ,   
      [Parameter(Mandatory=$true, Position = 10, ParameterSetName="StringArray")]
      [String[]]$Choices
   ,
      [Parameter(Mandatory=$False)]
      [string]$Caption = "Please choose!"
   ,  
      [Parameter(Mandatory=$False, Position=0)]
      [string]$Message = "Choose one of the following options:"
   ,  
      [Parameter(Mandatory=$False)]
      [int[]]$Default  = 0
   ,  
      [Switch]$MultipleChoice
   ,
      [Switch]$Passthru
   )
   begin {
      if($ChoicesWithHelp) { 
         [System.Collections.DictionaryEntry[]]$choices = $ChoicesWithHelp.GetEnumerator() | %{$_}
      }
   }
   process {
      $Descriptions = [System.Management.Automation.Host.ChoiceDescription[]]( $(
                        if($choices -is [String[]]) {
                           foreach($choice in $choices) {
                              New-Object System.Management.Automation.Host.ChoiceDescription $choice
                           } 
                        } else {
                           foreach($choice in $choices) {
                              New-Object System.Management.Automation.Host.ChoiceDescription $choice.Key, $choice.Value
                           } 
                        }
                      ) )
                      
      # Passing an array as the $Default triggers multiple choice prompting.
      if(!$MultipleChoice) { [int]$Default = $Default[0] }

      [int[]]$Answer = $Host.UI.PromptForChoice($Caption,$Message,$Descriptions,$Default)

      if($Passthru -or !($choices -is [String[]])) {
         Write-Verbose "$Answer"
         Write-Output  $Descriptions[$Answer]
      } else {
         Write-Output $Answer
      }
   }

}

function Get-Argument {
   param(
      [Type]$Target,
        [ref]$Method,
        [Array]$Arguments
   )
   end {
      trap {
         write-error $_
         break
      }

      $flags = [System.Reflection.BindingFlags]"public,ignorecase,invokemethod,instance"

      [Type[]]$Types = @(
         foreach($arg in $Arguments) {
            if($arg -is [type]) { 
               $arg 
            }
            else {
               $arg.GetType()
            }
         } 
      )
      try {
         Write-Verbose "[$($Target.FullName)].GetMethod('$($Method.Value)', [$($Flags.GetType())]'$flags', `$null, ([Type[]]($(@($Types|%{$_.Name}) -join ','))), `$null)"
         $MethodBase = $Target.GetMethod($($Method.Value), $flags, $null, $types, $null)
         $Arguments
         if($MethodBase) {
            $Method.Value = $MethodBase.Name
         }
      } catch { }
      
      if(!$MethodBase) {
         Write-Verbose "Try again to get $($Method.Value) Method on $($Target.FullName):"
         $MethodBase = Get-Method $target $($Method.Value)
         if(@($MethodBase).Count -gt 1) {
            $i = 0
            $i = Read-Choice -Choices $(foreach($mb in $MethodBase) { @{ "$($mb.SafeSyntax) &$($i = $i+1;$i)`b`n" =  $mb.SafeSyntax } }) -Default ($MethodBase.Count-1) -Caption "Choose a Method." -Message "Please choose which method overload to invoke:"
            [System.Reflection.MethodBase]$MethodBase = $MethodBase[$i]
         }
         
         
         ForEach($parameter in $MethodBase.GetParameters()) {
            $found = $false
            For($a =0;$a -lt $Arguments.Count;$a++) {
               if($argument[$a] -as $parameter.ParameterType) {
                  Write-Output $argument[$a]
                  if($a -gt 0 -and $a -lt $Arguments.Count) {
                     $Arguments = $Arguments | Select -First ($a-1) -Last ($Arguments.Count -$a)
                  } elseif($a -eq 0) {
                     $Arguments = $Arguments | Select -Last ($Arguments.Count - 1)
                  } else { # a -eq count
                     $Arguments = $Arguments | Select -First ($Arguments.Count - 1)
                  }
                  $found = $true
                  break
               }
            }
            if(!$Found) {
               $userInput = Read-Host "Please enter a [$($parameter.ParameterType.FullName)] value for $($parameter.Name)"
               if($userInput -match '^{.*}$' -and !($userInput -as $parameter.ParameterType)) {
                  Write-Output ((Invoke-Expression $userInput) -as $parameter.ParameterType)
               } else {
                  Write-Output ($userInput -as $parameter.ParameterType)
               }
            }
         }
      }
   }
}

function Invoke-Member {
   [CmdletBinding()]
   param(        
      [parameter(position=10, valuefrompipeline=$true, mandatory=$true)]
      [allowemptystring()]
      $InputObject,

      [parameter(position=0, mandatory=$true)]
      [validatenotnullorempty()]
      $Member,

      [parameter(position=1, valuefromremainingarguments=$true)]
      [allowemptycollection()]
      $Arguments,

      [parameter()]
      [switch]$Static
   )
   #  begin {
      #  if(!(get-member SafeSyntax -input $Member -type Property)){
         #  if(get-member Name -inpup $Member -Type Property) {
            #  $Member = Get-Method $InputObject $Member.Name
         #  } else {
            #  $Member = Get-Method $InputObject $Member
         #  }
      #  }
      #  $SafeSyntax = [ScriptBlock]::Create( $Member.SafeSyntax )
   #  }
   process {
      #  if ($InputObject) 
      #  {
         #  if ($InputObject | Get-Member $Member -static:$static) 
         #  {

            if ($InputObject -is [type]) {
                $target = $InputObject
            } else {
                $target = $InputObject.GetType()
            }
         
            if(Get-Member $Member -InputObject $InputObject -Type Properties) {
               $_.$Member
            } 
            elseif($Member -match "ctor|constructor") {
               $Member = ".ctor"
               [System.Reflection.BindingFlags]$flags = "CreateInstance"
               $InputObject = $Null
            } 
            else {
               [System.Reflection.BindingFlags]$flags = "IgnoreCase,Public,InvokeMethod"
               if($Static) { $flags = "$Flags,Static" } else { $flags = "$Flags,Instance" }
            }
            [ref]$Member = $Member
            [Object[]]$Parameters = Get-Argument $Target $Member $Arguments
            [string]$Member = $Member.Value

            Write-Verbose $(($Parameters | %{ '[' + $_.GetType().FullName + ']' + $_ }) -Join ", ")

            try {
               Write-Verbose "Invoking $Member on [$target]$InputObject with [$($Flags.GetType())]'$flags' and [$($Parameters.GetType())]($($Parameters -join ','))"
               Write-Verbose "[$($target.FullName)].InvokeMember('$Member', [System.Reflection.BindingFlags]'$flags', `$null, '$InputObject', ([object[]]($(($Parameters | %{ '[' + $_.GetType().FullName + ']''' + $_ + ''''}) -join', '))))"
               $target.InvokeMember($Member, [System.Reflection.BindingFlags]"$flags", $null, $InputObject, $Parameters)
            } catch {
               Write-Warning $_.Exception
                if ($_.Exception.Innerexception -is [MissingMethodException]) {
                    write-warning "Method argument count (or type) mismatch."
                }
            }
         #  } else {
            #  write-warning "Method $Member not found."
         #  }
      #  }
   }
}

function Invoke-Generic {
   #.Synopsis
   #  Invoke Generic method definitions via reflection:
   [CmdletBinding()]
   param( 
      [Parameter(Position=0,Mandatory=$true,ValueFromPipelineByPropertyName=$true)]
      [Alias('On')]
      $InputObject,

      [Parameter(Position=1,ValueFromPipelineByPropertyName=$true)]
      [Alias('Named')]
      [string]$MethodName,

      [Parameter(Position=2)]
      [Alias("Types")]
      [Type[]]$ParameterTypes,

      [Parameter(Position=4, ValueFromRemainingArguments=$true, ValueFromPipelineByPropertyName=$true)]
      [Object[]]$WithArgs,

      [Switch]$Static
   )
   begin {
      if($Static) {
         $BindingFlags = [System.Reflection.BindingFlags]"IgnoreCase,Public,Static"
      } else {
         $BindingFlags = [System.Reflection.BindingFlags]"IgnoreCase,Public,Instance"
      }
   }
   process {
      $Type = $InputObject -as [Type]
      if(!$Type) { $Type = $InputObject.GetType() }
      
      if($WithArgs -and -not $ParameterTypes) {
         $ParameterTypes = $withArgs | % { $_.GetType() }
      } elseif(!$ParameterTypes) {
         $ParameterTypes = [Type]::EmptyTypes
      }   
      
      
      trap { continue }
      $MemberInfo = $Type.GetMethod($MethodName, $BindingFlags)
      if(!$MemberInfo) {
         $MemberInfo = $Type.GetMethod($MethodName, $BindingFlags, $null, $NonGenericArgumentTypes, $null)
      }
      if(!$MemberInfo) {
         $MemberInfo = $Type.GetMethods($BindingFlags) | Where-Object {
            $MI = $_
            [bool]$Accept = $MI.Name -eq $MethodName
            if($Accept){
            Write-Verbose "$Accept = $($MI.Name) -eq $($MethodName)"
               [Array]$GenericTypes = @($MI.GetGenericArguments() | Select -Expand Name)
               [Array]$Parameters = @($MI.GetParameters() | Add-Member ScriptProperty -Name IsGeneric -Value { 
                                          $GenericTypes -Contains $this.ParameterType 
                                       } -Passthru)

                                       $Accept = $ParameterTypes.Count -eq $Parameters.Count
               Write-Verbose "  $Accept = $($Parameters.Count) Arguments"
               if($Accept) {
                  for($i=0;$i -lt $Parameters.Count;$i++) {
                     $Accept = $Accept -and ( $Parameters[$i].IsGeneric -or ($ParameterTypes[$i] -eq $Parameters[$i].ParameterType))
                     Write-Verbose "   $Accept =$(if($Parameters[$i].IsGeneric){' GENERIC or'}) $($ParameterTypes[$i]) -eq $($Parameters[$i].ParameterType)"
                  }
               }
            }
            return $Accept
         } | Sort { @($_.GetGenericArguments()).Count } | Select -First 1
      }
      Write-Verbose "Time to make generic methods."
      Write-Verbose $MemberInfo
      [Type[]]$GenericParameters = @()
      [Array]$ConcreteTypes = @($MemberInfo.GetParameters() | Select -Expand ParameterType)
      for($i=0;$i -lt $ParameterTypes.Count;$i++){
         Write-Verbose "$($ParameterTypes[$i]) ? $($ConcreteTypes[$i] -eq $ParameterTypes[$i])"
         if($ConcreteTypes[$i] -ne $ParameterTypes[$i]) {
            $GenericParameters += $ParameterTypes[$i]
         }
         $ParameterTypes[$i] = Add-Member -in $ParameterTypes[$i] -Type NoteProperty -Name IsGeneric -Value $($ConcreteTypes[$i] -ne $ParameterTypes[$i]) -Passthru
      }

       $ParameterTypes | Where-Object { $_.IsGeneric }
      Write-Verbose "$($GenericParameters -join ', ') generic parameters"

      $MemberInfo = $MemberInfo.MakeGenericMethod( $GenericParameters )
      Write-Verbose $MemberInfo

      if($WithArgs) {
         [Object[]]$Arguments = $withArgs | %{ $_.PSObject.BaseObject }
         Write-Verbose "Arguments: $(($Arguments | %{ $_.GetType().Name }) -Join ', ')"
         $MemberInfo.Invoke( $InputObject, $Arguments )
      } else {
         $MemberInfo.Invoke( $InputObject )
      }
   } 
}

# get a reference to the Type   
$xlr8r = [psobject].assembly.gettype("System.Management.Automation.TypeAccelerators")

function Import-Namespace {
   [CmdletBinding()]
   param(
      [Parameter(ValueFromPipeline=$true)]
      [string]$Namespace,

      [Switch]$Force
   )
   end {
     Get-Type -Namespace $Namespace -Force:$Force | Add-Accelerator
   }
}

function Add-Accelerator {
   <#
      .Synopsis
         Add a type accelerator to the current session
      .Description
         The Add-Accelerator function allows you to add a simple type accelerator (like [regex]) for a longer type (like [System.Text.RegularExpressions.Regex]).
      .Example
         Add-Accelerator list System.Collections.Generic.List``1
         $list = New-Object list[string]
         
         Creates an accelerator for the generic List[T] collection type, and then creates a list of strings.
      .Example
         Add-Accelerator "List T", "GList" System.Collections.Generic.List``1
         $list = New-Object "list t[string]"
         
         Creates two accelerators for the Generic List[T] collection type.
      .Parameter Accelerator
         The short form accelerator should be just the name you want to use (without square brackets).
      .Parameter Type
         The type you want the accelerator to accelerate (without square brackets)
      .Notes
         When specifying multiple values for a parameter, use commas to separate the values. 
         For example, "-Accelerator string, regex".
         
         PowerShell requires arguments that are "types" to NOT have the square bracket type notation, because of the way the parsing engine works.  You can either just type in the type as System.Int64, or you can put parentheses around it to help the parser out: ([System.Int64])

         Also see the help for Get-Accelerator and Remove-Accelerator
      .Link
         http://huddledmasses.org/powershell-2-ctp3-custom-accelerators-finally/
   #>
   [CmdletBinding()]
   param(
      [Parameter(Position=0,ValueFromPipelineByPropertyName=$true)]
      [Alias("Key","Name")]
      [string[]]$Accelerator,

      [Parameter(Position=1,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
      [Alias("Value","FullName")]
      [type]$Type
   )
   process {
      # add a user-defined accelerator  
      foreach($a in $Accelerator) { 
         if($xlr8r::AddReplace) { 
            $xlr8r::AddReplace( $a, $Type) 
         } else {
            $null = $xlr8r::Remove( $a )
            $xlr8r::Add( $a, $Type)
         }
         trap [System.Management.Automation.MethodInvocationException] {
            if($xlr8r::get.keys -contains $a) {
               if($xlr8r::get[$a] -ne $Type) {
                  Write-Error "Cannot add accelerator [$a] for [$($Type.FullName)]`n                  [$a] is already defined as [$($xlr8r::get[$a].FullName)]"
               }
               Continue;
            } 
            throw
         }
      }
   }
}

function Get-Accelerator {
   <#
      .Synopsis
         Get one or more type accelerator definitions
      .Description
         The Get-Accelerator function allows you to look up the type accelerators (like [regex]) defined on your system by their short form or by type
      .Example
         Get-Accelerator System.String
         
         Returns the KeyValue pair for the [System.String] accelerator(s)
      .Example
         Get-Accelerator ps*,wmi*
         
         Returns the KeyValue pairs for the matching accelerator definition(s)
      .Parameter Accelerator
         One or more short form accelerators to search for (Accept wildcard characters).
      .Parameter Type
         One or more types to search for.
      .Notes
         When specifying multiple values for a parameter, use commas to separate the values. 
         For example, "-Accelerator string, regex".
         
         Also see the help for Add-Accelerator and Remove-Accelerator
      .Link
         http://huddledmasses.org/powershell-2-ctp3-custom-accelerators-finally/
   #>
   [CmdletBinding(DefaultParameterSetName="ByType")]
   param(
      [Parameter(Position=0, ParameterSetName="ByAccelerator", ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
      [Alias("Key","Name")]
      [string[]]$Accelerator,

      [Parameter(Position=0, ParameterSetName="ByType", ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
      [Alias("Value","FullName")]
      [type[]]$Type
   )
   process {
      # add a user-defined accelerator  
      switch($PSCmdlet.ParameterSetName) {
         "ByAccelerator" { 
            $xlr8r::get.GetEnumerator() | % {
               foreach($a in $Accelerator) {
                  if($_.Key -like $a) { $_ }
               }
            }
            break
         }
         "ByType" { 
            if($Type -and $Type.Count) {
               $xlr8r::get.GetEnumerator() | ? { $Type -contains $_.Value }
            }
            else {
               $xlr8r::get.GetEnumerator() | %{ $_ }
            }
            break
         }
      }
   }
}

function Remove-Accelerator {
   <#
      .Synopsis
         Remove a type accelerator from the current session
      .Description
         The Remove-Accelerator function allows you to remove a simple type accelerator (like [regex]) from the current session. You can pass one or more accelerators, and even wildcards, but you should be aware that you can remove even the built-in accelerators.

      .Example
         Remove-Accelerator int
         Add-Accelerator int Int64

         Removes the "int" accelerator for Int32 and adds a new one for Int64. I can't recommend doing this, but it's pretty cool that it works:

         So now, "$(([int]3.4).GetType().FullName)" would return "System.Int64"
      .Example
         Get-Accelerator System.Single | Remove-Accelerator

         Removes both of the default accelerators for System.Single: [float] and [single]
      .Example
         Get-Accelerator System.Single | Remove-Accelerator -WhatIf

         Demonstrates that Remove-Accelerator supports -Confirm and -Whatif. Will Print:
            What if: Removes the alias [float] for type [System.Single]
            What if: Removes the alias [single] for type [System.Single]
      .Parameter Accelerator
         The short form accelerator that you want to remove (Accept wildcard characters).
      .Notes
         When specifying multiple values for a parameter, use commas to separate the values. 
         For example, "-Accel string, regex".

         Also see the help for Add-Accelerator and Get-Accelerator
      .Link
         http://huddledmasses.org/powershell-2-ctp3-custom-accelerators-finally/
   #>
   [CmdletBinding(SupportsShouldProcess=$true)]
   param(
      [Parameter(Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
      [Alias("Key","FullName")]
      [string[]]$Accelerator
   )
   process {
      foreach($a in $Accelerator) {
         foreach($key in $xlr8r::Get.Keys -like $a) { 
            if($PSCmdlet.ShouldProcess( "Removes the alias [$($Key)] for type [$($xlr8r::Get[$key].FullName)]",
                                        "Remove the alias [$($Key)] for type [$($xlr8r::Get[$key].FullName)]?",
                                        "Removing Type Accelerator" )) {
               # remove a user-defined accelerator
               $xlr8r::remove($key)   
            }
         }
      }
   }
}

###############################################################################
##### Imported from PowerBoots

$Script:CodeGenContentProperties = 'Content','Child','Children','Frames','Items','Pages','Blocks','Inlines','GradientStops','Source','DataPoints', 'Series', 'VisualTree'
$DependencyProperties = @{}
if(Test-Path $PSScriptRoot\DependencyPropertyCache.xml) {
	#$DependencyProperties = [System.Windows.Markup.XamlReader]::Parse( (gc $PSScriptRoot\DependencyPropertyCache.xml) )
	$DependencyProperties = Import-CliXml  $PSScriptRoot\DependencyPropertyCache.xml 
}

function Get-ReflectionModule { $executioncontext.sessionstate.module }

function Set-ObjectProperties {
[CmdletBinding()]
param( $Parameters, [ref]$DObject )

   if($DObject.Value -is [System.ComponentModel.ISupportInitialize]) { $DObject.Value.BeginInit() }

   if($DebugPreference -ne "SilentlyContinue") { Write-Host; Write-Host ">>>> $($Dobject.Value.GetType().FullName)" -fore Black -back White }
   foreach ($param in $Parameters) {
      if($DebugPreference -ne "SilentlyContinue") { Write-Host "Processing Param: $($param|Out-String )" }
      ## INGORE DEPENDENCY PROPERTIES FOR NOW :)
      if($param.Key -eq "DependencyProps") {
      ## HANDLE EVENTS ....
      }
      elseif ($param.Key.StartsWith("On_")) {
         $EventName = $param.Key.SubString(3)
         if($DebugPreference -ne "SilentlyContinue") { Write-Host "Event handler $($param.Key) Type: $(@($param.Value)[0].GetType().FullName)" }
         $sb = $param.Value -as [ScriptBlock]
         if(!$sb) {
            $sb = (Get-Command $param.Value -CommandType Function,ExternalScript).ScriptBlock
         }
         $Dobject.Value."Add_$EventName".Invoke( $sb );
         # $Dobject.Value."Add_$EventName".Invoke( ($sb.GetNewClosure()) );

         # $Dobject.Value."Add_$EventName".Invoke( $PSCmdlet.MyInvocation.MyCommand.Module.NewBoundScriptBlock( $sb.GetNewClosure() ) );


      } ## HANDLE PROPERTIES ....
      else { 
         try {
            ## TODO: File a BUG because Write-DEBUG and Write-VERBOSE die here.
            if($DebugPreference -ne "SilentlyContinue") {
               Write-Host "Setting $($param.Key) of $($Dobject.Value.GetType().Name) to $($param.Value.GetType().FullName): $($param.Value)" -fore Gray
            }
            if(@(foreach($sb in $param.Value) { $sb -is [ScriptBlock] }) -contains $true) {
               $Values = @()
               foreach($sb in $param.Value) {
                  $Values += & (Get-ReflectionModule) $sb
               }
            } else {
               $Values = $param.Value
            }

            if($DebugPreference -ne "SilentlyContinue") { Write-Host ([System.Windows.Markup.XamlWriter]::Save( $Dobject.Value )) -foreground green }
            if($DebugPreference -ne "SilentlyContinue") { Write-Host ([System.Windows.Markup.XamlWriter]::Save( @($Values)[0] )) -foreground green }

            Set-Property $Dobject $Param.Key $Values

            if($DebugPreference -ne "SilentlyContinue") { Write-Host ([System.Windows.Markup.XamlWriter]::Save( $Dobject.Value )) -foreground magenta }

            if($DebugPreference -ne "SilentlyContinue") {
               if( $Dobject.Value.$($param.Key) -ne $null ) {
                  Write-Host $Dobject.Value.$($param.Key).GetType().FullName -fore Green
               }
            }
         }
         catch [Exception]
         {
            Write-Host "COUGHT AN EXCEPTION" -fore Red
            Write-Host $_ -fore Red
            Write-Host $this -fore DarkRed
         }
      }

      while($DependencyProps) {
         $name, $value, $DependencyProps = $DependencyProps
         $name = ([string]@($name)[0]).Trim("-")
         if($name -and $value) {
            Set-DependencyProperty -Element $Dobject.Value -Property $name -Value $Value
         }
      }
   }
   if($DebugPreference -ne "SilentlyContinue") { Write-Host "<<<< $($Dobject.Value.GetType().FullName)" -fore Black -back White; Write-Host }

   if($DObject.Value -is [System.ComponentModel.ISupportInitialize]) { $DObject.Value.EndInit() }

}

function Set-Property {
PARAM([ref]$TheObject, $Name, $Values)
   $DObject = $TheObject.Value

   if($DebugPreference -ne "SilentlyContinue") { Write-Host ([System.Windows.Markup.XamlWriter]::Save( $DObject )) -foreground DarkMagenta }
   if($DebugPreference -ne "SilentlyContinue") { Write-Host ([System.Windows.Markup.XamlWriter]::Save( @($Values)[0] )) -foreground DarkMagenta }

   $PropertyType = $DObject.GetType().GetProperty($Name).PropertyType
   if('System.Windows.FrameworkElementFactory' -as [Type] -and $PropertyType -eq [System.Windows.FrameworkElementFactory] -and $DObject -is [System.Windows.FrameworkTemplate]) {
      if($DebugPreference -ne "SilentlyContinue") { Write-Host "Loading a FrameworkElementFactory" -foreground Green}

      # [Xml]$Template = [PoshWpf.XamlHelper]::ConvertToXaml( $DObject )
      # [Xml]$Content = [PoshWpf.XamlHelper]::ConvertToXaml( (@($Values)[0]) )
      # In .Net 3.5 the recommended way to programmatically create a template is to load XAML from a string or a memory stream using the Load method of the XamlReader class.
      [Xml]$Template = [System.Windows.Markup.XamlWriter]::Save( $DObject )
      [Xml]$Content = [System.Windows.Markup.XamlWriter]::Save( (@($Values)[0]) )

      $Template.DocumentElement.PrependChild( $Template.ImportNode($Content.DocumentElement, $true) ) | Out-Null

      $TheObject.Value = [System.Windows.Markup.XamlReader]::Parse( $Template.get_OuterXml() )
   }
   elseif('System.Windows.Data.Binding' -as [Type] -and @($Values)[0] -is [System.Windows.Data.Binding] -and !$PropertyType.IsAssignableFrom([System.Windows.Data.BindingBase])) {
      $Binding = @($Values)[0];
      if($DebugPreference -ne "SilentlyContinue") { Write-Host "$($DObject.GetType())::$Name is $PropertyType and the value is a Binding: $Binding" -fore Cyan}

      if(!$Binding.Source -and !$Binding.ElementName) {
         $Binding.Source = $DObject.DataContext
      }
      if($DependencyProperties.ContainsKey($Name)) {
         $field = @($DependencyProperties.$Name.Keys | Where { $DObject -is $_ -and $PropertyType -eq ([type]$DependencyProperties.$Name.$_.PropertyType)})[0] #  -or -like "*$Class" -and ($Param1.Value -as ([type]$_.PropertyType)
         if($field) { 
            if($DebugPreference -ne "SilentlyContinue") { Write-Host "$($field)" -fore Blue }
            if($DebugPreference -ne "SilentlyContinue") { Write-Host "Binding: ($field)::`"$($DependencyProperties.$Name.$field.Name)`" to $Binding" -fore Blue}

            $DObject.SetBinding( ([type]$field)::"$($DependencyProperties.$Name.$field.Name)", $Binding ) | Out-Null
         } else {
            throw "Couldn't figure out $( @($DependencyProperties.$Name.Keys) -join ', ' )"
         }
      } else {
         if($DebugPreference -ne "SilentlyContinue") { 
            Write-Host "But $($DObject.GetType())::${Name}Property is not a Dependency Property, so it probably can't be bound?" -fore Cyan
         }
         try {

            $DObject.SetBinding( ($DObject.GetType()::"${Name}Property"), $Binding ) | Out-Null

            if($DebugPreference -ne "SilentlyContinue") { 
               Write-Host ([System.Windows.Markup.XamlWriter]::Save( $Dobject )) -foreground yellow
            }
         } catch {
            Write-Host "Nope, was not able to set it." -fore Red
            Write-Host $_ -fore Red
            Write-Host $this -fore DarkRed
         }
      }
   }
   elseif($PropertyType -ne [Object] -and $PropertyType.IsAssignableFrom( [System.Collections.IEnumerable] ) -and ($DObject.$($Name) -eq $null)) {
      if($Values -is [System.Collections.IEnumerable]) {
         if($DebugPreference -ne "SilentlyContinue") { Write-Host "$Name is $PropertyType which is IEnumerable, and the value is too!" -fore Cyan }
         $DObject.$($Name) = $Values
      } else { 
         if($DebugPreference -ne "SilentlyContinue") { Write-Host "$Name is $PropertyType which is IEnumerable, but the value is not." -fore Cyan }
         $DObject.$($Name) = new-object "System.Collections.ObjectModel.ObservableCollection[$(@($Values)[0].GetType().FullName)]"
         $DObject.$($Name).Add($Values)
      }
   }
   elseif($DObject.$($Name) -is [System.Collections.IList]) {
      foreach ($value in @($Values)) {
         try {
            $null = $DObject.$($Name).Add($value)
         }
         catch
         {
            # Write-Host "CAUGHT array problem" -fore Red
            if($_.Exception.Message -match "Invalid cast from 'System.String' to 'System.Windows.UIElement'.") {
               $null = $DObject.$($Name).Add( (New-System.Windows.Controls.TextBlock $value) )
            } else {
               Write-Error $_.Exception
            throw
            }
         }
      }
   }
   else {
      ## If they pass an array of 1 when we only want one, we just use the first value
      if($Values -is [System.Collections.IList] -and $Values.Count -eq 1) {
         if($DebugPreference -ne "SilentlyContinue") { Write-Host "Value is an IList ($($Values.GetType().FullName))" -fore Cyan}
         if($DebugPreference -ne "SilentlyContinue") { Write-Host "But we'll just use the first ($($Values[0].GetType().FullName))" -fore Cyan}

         if($DebugPreference -ne "SilentlyContinue") { Write-Host ([System.Windows.Markup.XamlWriter]::Save( $Values[0] )) -foreground White}
         try {
            $DObject.$($Name) = $Values[0]
         }
         catch [Exception]
         {
            # Write-Host "CAUGHT collection value problem" -fore Red
            if($_.Exception.Message -match "Invalid cast from 'System.String' to 'System.Windows.UIElement'.") {
               $null = $DObject.$($Name).Add( (TextBlock $Values[0]) )
            }else { 
               throw
            }
         }
      }
      else ## If they pass an array when we only want one, we try to use it, and failing that, cast it to strings
      {
         if($DebugPreference -ne "SilentlyContinue") { Write-Host "Value is just $Values" -fore Cyan}
         try {
            $DObject.$($Name) = $Values
         } catch [Exception]
         {
            # Write-Host "CAUGHT value problem" -fore Red
            if($_.Exception.Message -match "Invalid cast from 'System.String' to 'System.Windows.UIElement'.") {
               $null = $DObject.$($Name).Add( (TextBlock $values) )
            }else { 
               throw
            }
         }
      }
   }
}

function Set-DependencyProperty {
[CmdletBinding()]
PARAM(
   [Parameter(Position=0,Mandatory=$true)]
   $Property,

   [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
   $Element,

   [Parameter()]
   [Switch]$Passthru
)

DYNAMICPARAM {
   $paramDictionary = new-object System.Management.Automation.RuntimeDefinedParameterDictionary
   $Param1 = new-object System.Management.Automation.RuntimeDefinedParameter
   $Param1.Name = "Value"
   # $Param1.Attributes.Add( (New-ParameterAttribute -Position 1) )
   $Param1.Attributes.Add( (New-Object System.Management.Automation.ParameterAttribute -Property @{ Position = 1 }) )

   if( $Property ) {
      if($Property.GetType() -eq ([System.Windows.DependencyProperty]) -or
         $Property.GetType().IsSubclassOf(([System.Windows.DependencyProperty]))) 
      {
         $Param1.ParameterType = $Property.PropertyType
      } 
      elseif($Property -is [string] -and $Property.Contains(".")) {
         $Class,$Property = $Property.Split(".")
         if($DependencyProperties.ContainsKey($Property)){
            $type = $DependencyProperties.$Property.Keys -like "*$Class"
            if($type) { 
               $Param1.ParameterType = [type]@($DependencyProperties.$Property.$type)[0].PropertyType
            }
         }

      } elseif($DependencyProperties.ContainsKey($Property)){
         if($Element) {
            if($DependencyProperties.$Property.ContainsKey( $element.GetType().FullName )) { 
               $Param1.ParameterType = [type]$DependencyProperties.$Property.($element.GetType().FullName).PropertyType
            }
         } else {
            $Param1.ParameterType = [type]$DependencyProperties.$Property.Values[0].PropertyType
         }
      }
      else 
      {
         $Param1.ParameterType = [PSObject]
      }
   }
   else 
   {
      $Param1.ParameterType = [PSObject]
   }
   $paramDictionary.Add("Value", $Param1)
   return $paramDictionary
}
PROCESS {
   trap { 
      Write-Host "ERROR Setting Dependency Property" -Fore Red
      Write-Host "Trying to set $Property to $($Param1.Value)" -Fore Red
      continue
   }
   if($Property.GetType() -eq ([System.Windows.DependencyProperty]) -or
      $Property.GetType().IsSubclassOf(([System.Windows.DependencyProperty]))
   ){
      trap { 
         Write-Host "ERROR Setting Dependency Property" -Fore Red
         Write-Host "Trying to set $($Property.FullName) to $($Param1.Value)" -Fore Red
         continue
      }
      $Element.SetValue($Property, ($Param1.Value -as $Property.PropertyType))
   } 
	else {
      if("$Property".Contains(".")) {
         $Class,$Property = "$Property".Split(".")
      }

      if( $DependencyProperties.ContainsKey("$Property" ) ) {
         $fields = @( $DependencyProperties.$Property.Keys -like "*$Class" | ? { $Param1.Value -as ([type]$DependencyProperties.$Property.$_.PropertyType) } )
			if($fields.Count -eq 0 ) { 
            $fields = @($DependencyProperties.$Property.Keys -like "*$Class" )
         }			
         if($fields.Count) {
            $success = $false
            foreach($field in $fields) {
               trap { 
                  Write-Host "ERROR Setting Dependency Property" -Fore Red
                  Write-Host "Trying to set $($field)::$($DependencyProperties.$Property.$field.Name) to $($Param1.Value) -as $($DependencyProperties.$Property.$field.PropertyType)" -Fore Red
                  continue
               }
               $Element.SetValue( ([type]$field)::"$($DependencyProperties.$Property.$field.Name)", ($Param1.Value -as ([type]$DependencyProperties.$Property.$field.PropertyType)))
               if($?) { $success = $true; break }
            }
				
            if(!$success) { 
					throw "food" 
				}				
         } else {
            Write-Host "Couldn't find the right property: $Class.$Property on $( $Element.GetType().Name ) of type $( $Param1.Value.GetType().FullName )" -Fore Red
         }
		}
		else {
         Write-Host "Unknown Dependency Property Key: $Property on $($Element.GetType().Name)" -Fore Red
      }
   }
	
   if( $Passthru ) { $Element }
}
}

function Add-Struct {
   #.Synopsis
   #   Creates Struct types from a list of types and properties
   #.Description
   #   Add-Struct is a wrapper for Add-Type to create struct types.
   #.Example
   #   New-Struct Song { 
   #   [string]$Artist
   #   [string]$Album
   #   [string]$Name
   #   [TimeSpan]$Length
   #   } -CreateConstructorFunction
   #
   #   Description
   #   -----------
   #   Creates a "Song" type with strongly typed Artist, Album, Name, and Length properties, with a simple constructor and a constructor function
   #.Example
   #   New-Struct @{
   #   >> Product  = { [string]$Name; [double]$Price; }
   #   >> Order    = { [Guid]$Id; [Product]$Product; [int]$Quantity }
   #   >> Customer = { 
   #   >>   [string]$FirstName
   #   >>   [string]$LastName
   #   >>   [int]$Age
   #   >>   [Order[]]$OrderHistory
   #   >> }
   #   >> }
   #   >>
   #
   #   Description
   #   -----------
   #   To create a series of related struct types (where one type is a property of another type), you need to use the -Types hashtable parameter set.  That way, all of the types will compiled together at once, so the compiler will be able to find them all.
   #
   [CmdletBinding(DefaultParameterSetName="Multiple")]
   param(
       # The name of the TYPE you are creating. Must be unique per PowerShell session.
       [ValidateScript({
           if($_ -notmatch '^[a-z][a-z1-9_]*$') {
               throw "'$_' is invalid. A valid name identifier must start with a letter, and contain only alpha-numeric or the underscore (_)."
           }
           return $true             
       })]
       [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true, ParameterSetName = "Single")]
       [string]$Name,

       # A Scriptblock full of "[Type]$Name" definitions to show what properties you want on your Struct type
       [Parameter(Position=1, Mandatory=$true, ValueFromPipelineByPropertyName=$true, ParameterSetName = "Single")]
       [ScriptBlock]$Property,

       # A Hashtable in the form @{Name={Properties}} with multiple Names and Property Scriptblocks to define related structs (see example 2).
       [Parameter(Position=0, Mandatory=$true, ParameterSetName = "Multiple")]
       [HashTable]$Types,

       # Generate a New-StructName shortcut function for each New-Object StructName
       [Alias("CTorFunction","ConstructorFunction")]
       [Switch]$CreateConstructorFunction,

       # Output the defined type(s)
       [Switch]$PassThru
   )
   begin {
       if($PSCmdlet.ParameterSetName -eq "Multiple") {
           $Structs = foreach($key in $Types.Keys) {
               New-Object PSObject -Property @{Name=$key;Property=$Types.$key}
           }
           Write-Verbose ($Structs | Out-String)
           $Structs | New-Struct -Passthru:$Passthru -CreateConstructorFunction:$CreateConstructorFunction
       } else {
       $code = "using System;`nusing System.Collections;`nusing System.Management.Automation;`n"
       $function = ""
       }
   }
process {
if($PSCmdlet.ParameterSetName -ne "Multiple") {
$parserrors = $null
$tokens = [PSParser]::Tokenize( $Property, [ref]$parserrors ) | Where-Object { "Newline","StatementSeparator" -notcontains $_.Type }

# CODE GENERATION MAGIKS!
$Name = $Name.ToUpper()[0] + $Name.SubString(1)
$ctor = @()
$setr = @()
$prop = @()
$parm = @()
$cast = @()
$hash = @()
$2Str = @()

$(while($typeToken,$varToken,$tokens = $tokens) {
    if($typeToken.Type -ne "Type") {
        throw "Error on line $($typeToken.StartLine) Column $($typeToken.Start). The Struct Properties block must contain only statements of the form: [Type]`$Name, see Get-Help New-Struct -Parameter Properties"
    } elseif($varToken.Type -ne "Variable") {
        throw "Error on line $($varToken.StartLine) Column $($varToken.Start). The Struct Properties block must contain only statements of the form: [Type]`$Name, see Get-Help New-Struct -Parameter Properties"
    }

    $varName = $varToken.Content.ToUpper()[0] + $varToken.Content.SubString(1)
    $varNameLower = $varName.ToLower()[0] + $varName.SubString(1)
    try {
        $typeName = Invoke-Expression "[$($typeToken.Content)].FullName"
    } catch {
        $typeName = $typeToken.Content
    }
    
    $prop += '   public {0} {1};' -f $typeName,$varName
    $setr += '      {0} = {1};' -f $varName,$varNameLower
    $ctor += '{0} {1}' -f $typeName,$varNameLower
    $cast += '      if(input.Properties["{0}"] != null){{ output.{0} = ({1})input.Properties["{0}"].Value; }}' -f $varName,$typeName
    $hash += '      if(hash.ContainsKey("{0}")){{ output.{0} = ({1})hash["{0}"]; }}' -f $varName,$typeName
    $2Str += '"{0} = [{1}]\"" + {0}.ToString() + "\""' -f $varName, $typeName
    if($CreateConstructorFunction) {
        $parm += '[{0}]${1}' -f $typeName,$varName
    }
})

$code += @"
public struct $Name {
$($prop -join "`n")
   public $Name ($( $ctor -join ","))
   {
$($setr -join "`n")
   }
   public static implicit operator $Name(Hashtable hash)
   {
      $Name output = new $Name();
$($hash -join "`n")
      return output;
   }
   public static implicit operator $Name(PSObject input)
   {
      $Name output = new $Name();
$($cast -join "`n")
      return output;
   }
   
   public override string ToString()
   {
      return "@{" + $($2Str -join ' + "; " + ') + "}";
   }
}

"@

if($CreateConstructorFunction) {
$function += @"
   Function global:New-$Name {
   [CmdletBinding()]
   param(
   $( $parm -join ",`n" )
   )
   New-Object $Name -Property `$PSBoundParameters
   }

"@
}

}
}
end {
   if($PSCmdlet.ParameterSetName -ne "Multiple") {
       Write-Verbose "C# Code:`n$code"
       Write-Verbose "PowerShell Code:`n$function"

       Add-Type -TypeDefinition $code -PassThru:$Passthru -ErrorAction Stop
       if($CreateConstructorFunction) {
           Invoke-Expression $function
       }
   }
}
}

function Add-Enum {
#.Synopsis
#   Generates an enumerable type
#.Description
#   Add-Enum is a wrapper for Add-Type to create Enums that can be used as parameters for functions. It includes the ability to create Flag enums, and automatically generates integer values (optionally adding a "None" (zero) value with the name you specify).
#.Example
#	 Add-Enum SpecialFolders Desktop Programs Personal MyDocuments
#.Example
#   get-content FolderPerLine.txt | New-Enum "SpecialFolders"
   [CmdletBinding(DefaultParameterSetName="Simple")]
   PARAM (
      # The name of the enum type. 
      # Note: To avoid collisions, this type will reside in the "PowerEnums" namespace, but we'll generate an alias for it so you can use just the name.
      [Parameter(Position=0,Mandatory=$true)]
      [String]$Name,

      # The values in the enum
      [Parameter(Position=1,Mandatory=$true,ValueFromPipeline=$true,ValueFromRemainingArguments=$true)]
      [String[]]$Members,

      # Controls whether the enum is generated as a [Flags] enum (meaning that combinations of the enumerations are valid)
      [Parameter(ParameterSetName="Flags",Mandatory=$true)]
      [Switch]$Flags,
      
      # Sets the name for the "None" (zero) value in a flags enum
      [Parameter(ParameterSetName="Flags")]
      [String]$ZeroValue,
      
      # If set, the type will be output
      [Switch]$Passthru
   )
   BEGIN {
      $AllMembers = New-Object System.Collections.Generic.List[String]
      $xlr8r = [psobject].assembly.gettype("System.Management.Automation.TypeAccelerators")
   }
   PROCESS {
      $AllMembers += $Members
   }
   END {
      $Members = foreach($m in $AllMembers -Split " ") { $m.Trim() -replace "^.", $m.Trim()[0].ToString().ToUpper() } 
      $Members = $Members | Select -Unique
      if($Flags) {
         $Value = 1
         $Members = foreach($m in $Members) {
            "$m = $Value"
            $Value += $Value
         }
         if($ZeroValue) {
            $Members = @("$ZeroValue = 0,`n") + $Members
         }
      }
      
      $Type = Add-Type -TypeDefinition @"
namespace PowerEnums {
   $(if($Flags){"[System.Flags]"})
   public enum $Name {
      $($Members -Join ",`n")
   }
}
"@ -Passthru

      if($Type) {
         if($xlr8r::AddReplace) { 
            $xlr8r::AddReplace( $Name, $Type) 
         } else {
            $null = $xlr8r::Remove( $Name )
            $xlr8r::Add( $Name, $Type)
         }
         
         if($Passthru) {
            $Type
         }
      }
   }
}

Add-Type -Assembly WindowsBase
function Add-ConstructorFunction {
   <#
      .Synopsis
         Add support for a new class by creating the dynamic constructor function(s).
      .Description
         Creates a New-Namespace.Type function for each type passed in, as well as a short form "Type" alias.

         Exposes all of the properties and events of the type as perameters to the function. 

         NOTE: The Type MUST have a default parameterless constructor.
      .Parameter Assembly
      	The Assembly you want to generate constructors for. All public types within it will be generated if possible.
      .Parameter Type
         The type you want to create a constructor function for.  It must have a default parameterless constructor.
      .Example
         Add-ConstructorFunction System.Windows.Controls.Button

         Creates a new function for the Button control.

      .Example
         [Reflection.Assembly]::LoadWithPartialName( "PresentationFramework" ).GetTypes() | Add-ConstructorFunction

         Will create constructor functions for all the WPF components in the PresentationFramework assembly.  Note that you could also load that assembly using GetAssembly( "System.Windows.Controls.Button" ) or Load( "PresentationFramework, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" )

      .Example
         Add-ConstructorFunction -Assembly PresentationFramework

         Will create constructor functions for all the WPF components in the PresentationFramework assembly.

      .Links 
         http://HuddledMasses.org/powerboots
      .ReturnValue
         The name(s) of the function(s) created -- so you can export them, if necessary.
      .Notes
         AUTHOR:    Joel Bennett http://HuddledMasses.org
         LASTEDIT:  2009-01-13 16:35:23
   #>
[CmdletBinding(DefaultParameterSetName="FromType")]
PARAM(
   [Parameter(Position=0,ValueFromPipeline=$true,ParameterSetName="FromType",Mandatory=$true)]
   [type[]]$type,

   [Alias("FullName")]
   [Parameter(Position=0,ValueFromPipelineByPropertyName=$true,ParameterSetName="FromAssembly",Mandatory=$true)]
   [string[]]$Assembly,

   [Parameter()]
	[string]$Path = "$PSScriptRoot\Types_Generated",

   [switch]$Force,

   [switch]$ShortAliases,

   [Switch]$Quiet
)
BEGIN {
   [Type[]]$Empty=@()
   if(!(Test-Path $Path)) {
      MkDir $Path
   }
   $ErrorList = @()
}
END {
   #Set-Content -Literal $PSScriptRoot\DependencyPropertyCache.xml -Value ([System.Windows.Markup.XamlWriter]::Save( $DependencyProperties ))
	Export-CliXml -Path $PSScriptRoot\DependencyPropertyCache.xml -InputObject $DependencyProperties
	
   if($ErrorList.Count) { Write-Warning "Some New-* functions not aliased." }
   $ErrorList | Write-Error
}
PROCESS {
   if($PSCmdlet.ParameterSetName -eq "FromAssembly") {
      [type[]]$type = @()
      foreach($lib in $Assembly) {
         $asm =  $null
         trap { continue }
         if(Test-Path $lib) {
            $asm =  [Reflection.Assembly]::LoadFrom( (Convert-Path (Resolve-Path $lib -EA "SilentlyContinue") -EA "SilentlyContinue") )
         }
         if(!$asm) {
            ## BUGBUG: LoadWithPartialName is "Obsolete" -- but it still works in 2.0/3.5
            $asm =  [Reflection.Assembly]::LoadWithPartialName( $lib )
         }
         if($asm) {
            $type += $asm.GetTypes() | ?{ $_.IsPublic    -and !$_.IsEnum      -and 
                                         !$_.IsAbstract  -and !$_.IsInterface -and 
                                          $_.GetConstructor( "Instance,Public", $Null, $Empty, @() )}
         } else {
            Write-Error "Can't find the assembly $lib, please check your spelling and try again"
         }
      }
   }

   foreach($T in $type) {
      $TypeName = $T.FullName
      $ScriptPath = Join-Path $Path "New-$TypeName.ps1"
      Write-Verbose $TypeName

      ## Collect all dependency properties ....
      $T.GetFields() |
         Where-Object { $_.FieldType -eq [System.Windows.DependencyProperty] } |
         ForEach-Object { 
            [string]$Field = $_.DeclaringType::"$($_.Name)".Name
            [string]$TypeName = $_.DeclaringType.FullName

            if(!$DependencyProperties.ContainsKey( $Field )) {
               $DependencyProperties.$Field = @{}
            }

            $DependencyProperties.$Field.$TypeName = @{ 
               Name         = [string]$_.Name
               PropertyType = [string]$_.DeclaringType::"$($_.Name)".PropertyType.FullName
            }
         }

		if(!( Test-Path $ScriptPath ) -OR $Force) {
         $Pipelineable = @();
         ## Get (or generate) a set of parameters based on the the Type Name
         $PropertyNames = New-Object System.Text.StringBuilder "@("

         $Parameters = New-Object System.Text.StringBuilder "[CmdletBinding(DefaultParameterSetName='Default')]`nPARAM(`n"
		 
         ## Add all properties
         $Properties = $T.GetProperties("Public,Instance,FlattenHierarchy") | 
            Where-Object { $_.CanWrite -Or $_.PropertyType.GetInterface([System.Collections.IList]) }
			
         $Properties = ($T.GetEvents("Public,Instance,FlattenHierarchy") + $Properties) | Sort-Object Name -Unique

         foreach ($p in $Properties) {
            $null = $PropertyNames.AppendFormat(",'{0}'",$p.Name)
            switch( $p.MemberType ) {
               Event {
                  $null = $PropertyNames.AppendFormat(",'{0}__'",$p.Name)
                  $null = $Parameters.AppendFormat(@'
	[Parameter()]
	[PSObject]${{On_{0}}},

'@, $p.Name)
               }
               Property {
                  if($p.Name -match "^$($CodeGenContentProperties -Join '$|^')`$") {
                     $null = $Parameters.AppendFormat(@'
	[Parameter(Position=1,ValueFromPipeline=$true)]
	[Object[]]${{{0}}},

'@, $p.Name)
                     $Pipelineable += @(Add-Member -in $p.Name -Type NoteProperty -Name "IsCollection" -Value $($p.PropertyType.GetInterface([System.Collections.IList]) -ne $null) -Passthru)
                  } 
                  elseif($p.PropertyType -eq [System.Boolean]) 
                  {
                     $null = $Parameters.AppendFormat(@'
	[Parameter()]
	[Switch]${{{0}}},

'@, $p.Name)
                  }
                  else 
                  {
                     $null = $Parameters.AppendFormat(@'
	[Parameter()]
	[Object[]]${{{0}}},

'@, $p.Name)
                  }
               }
            }
         }
		$null = $Parameters.Append('	[Parameter(ValueFromRemainingArguments=$true)]
	[string[]]$DependencyProps
)')
		$null = $PropertyNames.Remove(2,1).Append(')')
			
      $collectable = [bool]$(@(foreach($p in @($Pipelineable)){$p.IsCollection}) -contains $true)
      $ofs = "`n";

$function = $(
"
if(!( '$TypeName' -as [Type] )) {
$(
   if( $T.Assembly.GlobalAssemblyCache ) {
"  `$null = [Reflection.Assembly]::Load( '$($T.Assembly.FullName)' ) "
   } else {
"  `$null = [Reflection.Assembly]::LoadFrom( '$($T.Assembly.Location)' ) "
   }
)
}
## if(`$ExecutionContext.SessionState.Module.Guid -ne (Get-ReflectionModule).Guid) {
## 	Write-Warning `"$($T.Name) not invoked in ReflectionModule context. Attempting to reinvoke.`"
##    # `$scriptParam = `$PSBoundParameters
##    # return iex `"& (Get-ReflectionModule) '`$(`$MyInvocation.MyCommand.Path)' ```@PSBoundParameters`"
## }
Write-Verbose ""$($T.Name) in module `$(`$executioncontext.sessionstate.module) context!""

function New-$TypeName {
<#
.Synopsis
   Create a new $($T.Name) object
.Description
   Generates a new $TypeName object, and allows setting all of it's properties.
   (From the $($T.Assembly.GetName().Name) assembly v$($T.Assembly.GetName().Version))
.Notes
 GENERATOR : $((Get-ReflectionModule).Name) v$((Get-ReflectionModule).Version) by Joel Bennett http://HuddledMasses.org
 GENERATED : $(Get-Date)
 ASSEMBLY  : $($T.Assembly.FullName)
 FULLPATH  : $($T.Assembly.Location)
#>
 
$Parameters
BEGIN {
   `$DObject = New-Object $TypeName
   `$All = $PropertyNames
}
PROCESS {
"
if(!$collectable) {
"
   # The content of $TypeName is not a collection
   # So if we're in a pipeline, make a new $($T.Name) each time
   if(`$_) { 
      `$DObject = New-Object $TypeName
   }
"
}
@'
foreach($key in @($PSBoundParameters.Keys) | where { $PSBoundParameters[$_] -is [ScriptBlock] }) {
   $PSBoundParameters[$key] = $PSBoundParameters[$key].GetNewClosure()
}
Set-ObjectProperties @($PSBoundParameters.GetEnumerator() | Where { [Array]::BinarySearch($All,($_.Key -replace "^On_(.*)",'$1__')) -ge 0 } ) ([ref]$DObject)
'@

if(!$collectable) {
@'
   Microsoft.PowerShell.Utility\Write-Output $DObject
} #Process
'@
   } else {
@'
} #Process
END {
   Microsoft.PowerShell.Utility\Write-Output $DObject
}
'@
   }
@"
}
## New-$TypeName `@PSBoundParameters
"@
)

         Set-Content -Path $ScriptPath -Value $Function
      }

      # Note: set the aliases global for now, because it's too late to export them
		# E.g.: New-Button = New-System.Windows.Controls.Button
		Set-Alias -Name "New-$($T.Name)" "New-$TypeName" -ErrorAction SilentlyContinue -ErrorVariable +ErrorList -Scope Global -Passthru:(!$Quiet)
		if($ShortAliases) {
		# E.g.: Button = New-System.Windows.Controls.Button
			Set-Alias -Name $T.Name "New-$TypeName" -ErrorAction SilentlyContinue -ErrorVariable +ErrorList -Scope Global -Passthru:(!$Quiet)
		}
		
      New-AutoLoad -Name $ScriptPath -Alias "New-$TypeName"
   }
}#PROCESS
}

function Import-ConstructorFunctions {
#.Synopsis
#  Autoload pre-generated constructor functions and generate aliases for them.
#.Description
#  Parses the New-* scripts in the specified path, and uses the Autoload module to pre-load them as commands and set up aliases for them, without parsing them into memory.
#.Parameter Path
#  The path to a folder with functions to preload
param(
   [Parameter()]
   [Alias("PSPath")]
	[string[]]$Path = "$PSScriptRoot\Types_Generated"
)
end {
	$Paths = $(foreach($p in $Path) { Join-Path $p "New-*.ps1" })
	Write-Verbose "Importing Constructors from: `n`t$($Paths -join "`n`t")"

	foreach($script in Get-ChildItem $Paths -ErrorAction 0) {
		$TypeName = $script.Name -replace 'New-(.*).ps1','$1'
      $ShortName = ($TypeName -split '\.')[-1]
      Write-Verbose "Importing constructor for type: $TypeName ($ShortName)"
		
      # Note: set the aliases global for now, because it's too late to export them
		# E.g.: New-Button = New-System.Windows.Controls.Button
		Set-Alias -Name "New-$ShortName" "New-$TypeName" -ErrorAction SilentlyContinue -ErrorVariable +ErrorList -Scope Global -Passthru:(!$Quiet)
		if($ShortAliases) {
		# E.g.: Button = New-System.Windows.Controls.Button
			Set-Alias -Name $ShortName "New-$TypeName" -ErrorAction SilentlyContinue -ErrorVariable +ErrorList -Scope Global -Passthru:(!$Quiet)
		}

		New-Autoload -Name $Script.FullName -Alias "New-$TypeName"
		# Write-Host -fore yellow $(Get-Command "New-$TypeName" | Out-String)
		Get-Command "New-$TypeName"
	}
}
}

#.Parameter Snapin
#  The full path to where the snapin .dll is
#.Parameter OutputPath
#  Force the module manifest(s) to output in a different location than where the snapin .dll is
#.Parameter ModuleName
#  Override the snapin name(s) for the module manifest
#.Parameter Author
#  Overrides the Company Name from the manifest when generating the module's "Author" comment
#.Parameter Passthru
#  Returns the ModuleManifest (same as -Passthru on New-ModuleManifest)
#.Example
#  New-ModuleManifestFromSnapin ".\Quest Software\Management Shell for AD" -ModuleName QAD
#
#  Description
#  -----------
#  Generates a new module manifest file: QAD.psd1 in the folder next to the Quest.ActiveRoles.ArsPowerShellSnapIn.dll
#.Example
#  New-ModuleManifestFromSnapin "C:\Program Files (x86)\Microsoft SQL Server\100\Tools\Binn\" -Output $pwd
#
#  Description
#  -----------
#  Generates module manifest files for the SqlServer PSSnapins and stores them in the current folder
function New-ModuleManifestFromSnapin {
param( 
   [Parameter(Mandatory=$true, Position="0", ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
   [Alias("FullName")]
   [String[]]$Snapin,

   [Parameter()]
   $OutputPath,

   [Parameter()]
   $ModuleName,

   [Parameter()]
   [String]$Author,

   [Switch]$Passthru
) 

# $SnapinPath = $(Get-ChildItem $SnapinPath -Filter *.dll)
$EAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
Add-Assembly $Snapin 
$ErrorActionPreference = $EAP

$SnapinTypes = Get-Assembly $Snapin | Get-Type -BaseType System.Management.Automation.PSSnapIn, System.Management.Automation.CustomPSSnapIn -WarningAction SilentlyContinue


foreach($SnapinType in $SnapinTypes) {
   $Installer = New-Object $SnapinType

   if(!$PSBoundParameters.ContainsKey("OutputPath")) {
      $OutputPath = (Split-Path $SnapinType.Assembly.Location)
   }

   if(!$PSBoundParameters.ContainsKey("ModuleName")) {
      $ModuleName = $Installer.Vendor
   }
   if(!$PSBoundParameters.ContainsKey("Author")) {
      $Author = $Installer.Name
   }
   $ManifestPath = (Join-Path $OutputPath "$ModuleName.psd1")

   Write-Verbose "Creating Module Manifest: $ManifestPath"

   $RequiredAssemblies = @( $SnapinType.Assembly.GetReferencedAssemblies() | Get-Assembly | Where-Object { (Split-Path $_.Location) -eq (Split-Path $SnapinType.Assembly.Location) } | Select-Object -Expand Location | Resolve-Path -ErrorAction Continue)

   # New-ModuleManifest has a bad bug -- it makes paths relative to the current location (and it does it wrong).
   Push-Location $OutputPath

   if($Installer -is [System.Management.Automation.CustomPSSnapIn]) {
      $Cmdlets = $Installer.Cmdlets | Select-Object -Expand Name
      $Types = $Installer.Types | Select-Object -Expand FileName | %{ $path = Resolve-Path $_ -ErrorAction Continue; if(!$path){ $_ } else { $path } }
      $Formats = $Installer.Formats | Select-Object -Expand FileName | %{ $path = Resolve-Path $_ -ErrorAction Continue; if(!$path){ $_ } else { $path } }
   } else {
      $Types = $Installer.Types |  %{ $path = Resolve-Path $_ -ErrorAction Continue; if(!$path){ $_ } else { $path } }
      $Formats = $Installer.Formats |  %{ $path = Resolve-Path $_ -ErrorAction Continue; if(!$path){ $_ } else { $path } }
   }
   if(!$Cmdlets) { $Cmdlets = "*" }
   if(!$Types) { $Types = @() }
   if(!$Formats) { $Formats = @() }

   New-ModuleManifest -Path $ManifestPath -Author $Author -Company $Installer.Vendor -Description $Installer.Description `
                      -ModuleToProcess $SnapinType.Assembly.Location -Types $Types -Formats $Formats -Cmdlets $Cmdlets `
                      -RequiredAssemblies $RequiredAssemblies  -Passthru:$Passthru `
                      -NestedModules @() -Copyright $Installer.Vendor -FileList @()
   Pop-Location
}
}


Add-Accelerator list System.Collections.Generic.List``1
Add-Accelerator dictionary System.Collections.Generic.Dictionary``2

Set-Alias aasm Add-Assembly
Set-Alias gt Get-Type
Set-Alias gasm Get-Assembly
Set-Alias gctor Get-Constructor

# SIG # Begin signature block
# MIIfIAYJKoZIhvcNAQcCoIIfETCCHw0CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUWMPcmsXk509Itl7MMfH7CJPF
# JwqgghpSMIID7jCCA1egAwIBAgIQfpPr+3zGTlnqS5p31Ab8OzANBgkqhkiG9w0B
# AQUFADCBizELMAkGA1UEBhMCWkExFTATBgNVBAgTDFdlc3Rlcm4gQ2FwZTEUMBIG
# A1UEBxMLRHVyYmFudmlsbGUxDzANBgNVBAoTBlRoYXd0ZTEdMBsGA1UECxMUVGhh
# d3RlIENlcnRpZmljYXRpb24xHzAdBgNVBAMTFlRoYXd0ZSBUaW1lc3RhbXBpbmcg
# Q0EwHhcNMTIxMjIxMDAwMDAwWhcNMjAxMjMwMjM1OTU5WjBeMQswCQYDVQQGEwJV
# UzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xMDAuBgNVBAMTJ1N5bWFu
# dGVjIFRpbWUgU3RhbXBpbmcgU2VydmljZXMgQ0EgLSBHMjCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBALGss0lUS5ccEgrYJXmRIlcqb9y4JsRDc2vCvy5Q
# WvsUwnaOQwElQ7Sh4kX06Ld7w3TMIte0lAAC903tv7S3RCRrzV9FO9FEzkMScxeC
# i2m0K8uZHqxyGyZNcR+xMd37UWECU6aq9UksBXhFpS+JzueZ5/6M4lc/PcaS3Er4
# ezPkeQr78HWIQZz/xQNRmarXbJ+TaYdlKYOFwmAUxMjJOxTawIHwHw103pIiq8r3
# +3R8J+b3Sht/p8OeLa6K6qbmqicWfWH3mHERvOJQoUvlXfrlDqcsn6plINPYlujI
# fKVOSET/GeJEB5IL12iEgF1qeGRFzWBGflTBE3zFefHJwXECAwEAAaOB+jCB9zAd
# BgNVHQ4EFgQUX5r1blzMzHSa1N197z/b7EyALt0wMgYIKwYBBQUHAQEEJjAkMCIG
# CCsGAQUFBzABhhZodHRwOi8vb2NzcC50aGF3dGUuY29tMBIGA1UdEwEB/wQIMAYB
# Af8CAQAwPwYDVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NybC50aGF3dGUuY29tL1Ro
# YXd0ZVRpbWVzdGFtcGluZ0NBLmNybDATBgNVHSUEDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCAQYwKAYDVR0RBCEwH6QdMBsxGTAXBgNVBAMTEFRpbWVTdGFtcC0y
# MDQ4LTEwDQYJKoZIhvcNAQEFBQADgYEAAwmbj3nvf1kwqu9otfrjCR27T4IGXTdf
# plKfFo3qHJIJRG71betYfDDo+WmNI3MLEm9Hqa45EfgqsZuwGsOO61mWAK3ODE2y
# 0DGmCFwqevzieh1XTKhlGOl5QGIllm7HxzdqgyEIjkHq3dlXPx13SYcqFgZepjhq
# IhKjURmDfrYwggRPMIIDuKADAgECAgQHJ1g9MA0GCSqGSIb3DQEBBQUAMHUxCzAJ
# BgNVBAYTAlVTMRgwFgYDVQQKEw9HVEUgQ29ycG9yYXRpb24xJzAlBgNVBAsTHkdU
# RSBDeWJlclRydXN0IFNvbHV0aW9ucywgSW5jLjEjMCEGA1UEAxMaR1RFIEN5YmVy
# VHJ1c3QgR2xvYmFsIFJvb3QwHhcNMTAwMTEzMTkyMDMyWhcNMTUwOTMwMTgxOTQ3
# WjBsMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL
# ExB3d3cuZGlnaWNlcnQuY29tMSswKQYDVQQDEyJEaWdpQ2VydCBIaWdoIEFzc3Vy
# YW5jZSBFViBSb290IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
# xszlc+b71LvlLS0ypt/lgT/JzSVJtnEqw9WUNGeiChywX2mmQLHEt7KP0JikqUFZ
# OtPclNY823Q4pErMTSWC90qlUxI47vNJbXGRfmO2q6Zfw6SE+E9iUb74xezbOJLj
# BuUIkQzEKEFV+8taiRV+ceg1v01yCT2+OjhQW3cxG42zxyRFmqesbQAUWgS3uhPr
# UQqYQUEiTmVhh4FBUKZ5XIneGUpX1S7mXRxTLH6YzRoGFqRoc9A0BBNcoXHTWnxV
# 215k4TeHMFYE5RG0KYAS8Xk5iKICEXwnZreIt3jyygqoOKsKZMK/Zl2VhMGhJR6H
# XRpQCyASzEG7bgtROLhLywIDAQABo4IBbzCCAWswEgYDVR0TAQH/BAgwBgEB/wIB
# ATBTBgNVHSAETDBKMEgGCSsGAQQBsT4BADA7MDkGCCsGAQUFBwIBFi1odHRwOi8v
# Y3liZXJ0cnVzdC5vbW5pcm9vdC5jb20vcmVwb3NpdG9yeS5jZm0wDgYDVR0PAQH/
# BAQDAgEGMIGJBgNVHSMEgYEwf6F5pHcwdTELMAkGA1UEBhMCVVMxGDAWBgNVBAoT
# D0dURSBDb3Jwb3JhdGlvbjEnMCUGA1UECxMeR1RFIEN5YmVyVHJ1c3QgU29sdXRp
# b25zLCBJbmMuMSMwIQYDVQQDExpHVEUgQ3liZXJUcnVzdCBHbG9iYWwgUm9vdIIC
# AaUwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL3d3dy5wdWJsaWMtdHJ1c3QuY29t
# L2NnaS1iaW4vQ1JMLzIwMTgvY2RwLmNybDAdBgNVHQ4EFgQUsT7DaQP4v0cB1Jgm
# GggC72NkK8MwDQYJKoZIhvcNAQEFBQADgYEALnaF2TeWba+J8wZ4gjHERgcfZcmO
# s8lUeObRQt91Lh5V6vf6mwTAdXvReTwF7HnEUt2mA9enUJk/BVnaxlX0hpwNZ6NJ
# BJUyHceH7IWvZG7VxV8Jp0B9FrpJDaL99t9VMGzXeMa5z1gpZBZMoyCBR7FEkoQW
# G29KvCHGCj3tM8owggSjMIIDi6ADAgECAhAOz/Q4yP6/NW4E2GqYGxpQMA0GCSqG
# SIb3DQEBBQUAMF4xCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jw
# b3JhdGlvbjEwMC4GA1UEAxMnU3ltYW50ZWMgVGltZSBTdGFtcGluZyBTZXJ2aWNl
# cyBDQSAtIEcyMB4XDTEyMTAxODAwMDAwMFoXDTIwMTIyOTIzNTk1OVowYjELMAkG
# A1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9uMTQwMgYDVQQD
# EytTeW1hbnRlYyBUaW1lIFN0YW1waW5nIFNlcnZpY2VzIFNpZ25lciAtIEc0MIIB
# IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAomMLOUS4uyOnREm7Dv+h8GEK
# U5OwmNutLA9KxW7/hjxTVQ8VzgQ/K/2plpbZvmF5C1vJTIZ25eBDSyKV7sIrQ8Gf
# 2Gi0jkBP7oU4uRHFI/JkWPAVMm9OV6GuiKQC1yoezUvh3WPVF4kyW7BemVqonShQ
# DhfultthO0VRHc8SVguSR/yrrvZmPUescHLnkudfzRC5xINklBm9JYDh6NIipdC6
# Anqhd5NbZcPuF3S8QYYq3AhMjJKMkS2ed0QfaNaodHfbDlsyi1aLM73ZY8hJnTrF
# xeozC9Lxoxv0i77Zs1eLO94Ep3oisiSuLsdwxb5OgyYI+wu9qU+ZCOEQKHKqzQID
# AQABo4IBVzCCAVMwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcD
# CDAOBgNVHQ8BAf8EBAMCB4AwcwYIKwYBBQUHAQEEZzBlMCoGCCsGAQUFBzABhh5o
# dHRwOi8vdHMtb2NzcC53cy5zeW1hbnRlYy5jb20wNwYIKwYBBQUHMAKGK2h0dHA6
# Ly90cy1haWEud3Muc3ltYW50ZWMuY29tL3Rzcy1jYS1nMi5jZXIwPAYDVR0fBDUw
# MzAxoC+gLYYraHR0cDovL3RzLWNybC53cy5zeW1hbnRlYy5jb20vdHNzLWNhLWcy
# LmNybDAoBgNVHREEITAfpB0wGzEZMBcGA1UEAxMQVGltZVN0YW1wLTIwNDgtMjAd
# BgNVHQ4EFgQURsZpow5KFB7VTNpSYxc/Xja8DeYwHwYDVR0jBBgwFoAUX5r1blzM
# zHSa1N197z/b7EyALt0wDQYJKoZIhvcNAQEFBQADggEBAHg7tJEqAEzwj2IwN3ij
# hCcHbxiy3iXcoNSUA6qGTiWfmkADHN3O43nLIWgG2rYytG2/9CwmYzPkSWRtDebD
# Zw73BaQ1bHyJFsbpst+y6d0gxnEPzZV03LZc3r03H0N45ni1zSgEIKOq8UvEiCmR
# DoDREfzdXHZuT14ORUZBbg2w6jiasTraCXEQ/Bx5tIB7rGn0/Zy2DBYr8X9bCT2b
# W+IWyhOBbQAuOA2oKY8s4bL0WqkBrxWcLC9JG9siu8P+eJRRw4axgohd8D20UaF5
# Mysue7ncIAkTcetqGVvP6KUwVyyJST+5z3/Jvz4iaGNTmr1pdKzFHTx/kuDDvBzY
# BHUwggafMIIFh6ADAgECAhAOaQaYwhTIerW2BLkWPNGQMA0GCSqGSIb3DQEBBQUA
# MHMxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xMjAwBgNVBAMTKURpZ2lDZXJ0IEhpZ2ggQXNzdXJh
# bmNlIENvZGUgU2lnbmluZyBDQS0xMB4XDTEyMDMyMDAwMDAwMFoXDTEzMDMyMjEy
# MDAwMFowbTELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRcwFQYDVQQH
# Ew5XZXN0IEhlbnJpZXR0YTEYMBYGA1UEChMPSm9lbCBILiBCZW5uZXR0MRgwFgYD
# VQQDEw9Kb2VsIEguIEJlbm5ldHQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQDaiAYAbz13WMx9Em/Z3dTWUKxbyiTsaSOctgOfTMLUAurXWtY3k1XBVufX
# feL4pXQ7yQzm93YzvETwKdUCDJuOSu9EPYioy2nhKvBC6IaJUaw1VY7e9IsdxaxL
# 8js3RQilLk+FO4UHg9w7L8wdHgXaDoksysC2SlhbFq4AVl8XC4R+bq+pahsdMO3n
# Ab7Oo5PExKLVS8vl8QwOh6MaqquIjHmYoPOu9Rv8As0pnWsY9aVPs7T9QetXlW45
# +CKPhdUoEB1yD0kvGTIAQgn5W9VDYmfeVU40IIdt+7khWF10yu7zVT+/lauPzRmv
# CHZMfbmqVyVQqvp5dEu0/7EWbbcLAgMBAAGjggMzMIIDLzAfBgNVHSMEGDAWgBSX
# SAPrFQhrubJYI8yULvHGZdJkjjAdBgNVHQ4EFgQUmJxEqr9ewFZG4rNTp5NQIEIJ
# TrkwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMGkGA1UdHwRi
# MGAwLqAsoCqGKGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9oYS1jcy0yMDExYS5j
# cmwwLqAsoCqGKGh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9oYS1jcy0yMDExYS5j
# cmwwggHEBgNVHSAEggG7MIIBtzCCAbMGCWCGSAGG/WwDATCCAaQwOgYIKwYBBQUH
# AgEWLmh0dHA6Ly93d3cuZGlnaWNlcnQuY29tL3NzbC1jcHMtcmVwb3NpdG9yeS5o
# dG0wggFkBggrBgEFBQcCAjCCAVYeggFSAEEAbgB5ACAAdQBzAGUAIABvAGYAIAB0
# AGgAaQBzACAAQwBlAHIAdABpAGYAaQBjAGEAdABlACAAYwBvAG4AcwB0AGkAdAB1
# AHQAZQBzACAAYQBjAGMAZQBwAHQAYQBuAGMAZQAgAG8AZgAgAHQAaABlACAARABp
# AGcAaQBDAGUAcgB0ACAAQwBQAC8AQwBQAFMAIABhAG4AZAAgAHQAaABlACAAUgBl
# AGwAeQBpAG4AZwAgAFAAYQByAHQAeQAgAEEAZwByAGUAZQBtAGUAbgB0ACAAdwBo
# AGkAYwBoACAAbABpAG0AaQB0ACAAbABpAGEAYgBpAGwAaQB0AHkAIABhAG4AZAAg
# AGEAcgBlACAAaQBuAGMAbwByAHAAbwByAGEAdABlAGQAIABoAGUAcgBlAGkAbgAg
# AGIAeQAgAHIAZQBmAGUAcgBlAG4AYwBlAC4wgYYGCCsGAQUFBwEBBHoweDAkBggr
# BgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFAGCCsGAQUFBzAChkRo
# dHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRIaWdoQXNzdXJhbmNl
# Q29kZVNpZ25pbmdDQS0xLmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBBQUA
# A4IBAQAch95ik7Qm12L9Olwjp5ZAhhTYAs7zjtD3WMsTpaJTq7zA3q2QeqB46WzT
# vRINQr4LWtWhcopnQl5zaTV1i6Qo+TJ/epRE/KH9oLeEnRbBuN7t8rv0u31kfAk5
# Gl6wmvBrxPreXeossuU9ohij9uqIyk1lF85yW6QqDaE7rvIxpCXwMQv8PlQ/VdlK
# EXbNtq4frbvMQLkpcZljbJRuZYbY3SgfGv6rgbJ93Qw+1Tlq9Y4gsHRmw35uv5IJ
# VUrqcrNq5cyTgdeYodpftzKyqmZCIVvv8nu09DTfspAocJj9n5+XRqtEKIeKH9D/
# mjC/nVZIo+JpSuQG90nSYpUr4xwfMIIGvzCCBaegAwIBAgIQCBxX7l1w65ugsVIM
# cpwbCTANBgkqhkiG9w0BAQUFADBsMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGln
# aUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSswKQYDVQQDEyJE
# aWdpQ2VydCBIaWdoIEFzc3VyYW5jZSBFViBSb290IENBMB4XDTExMDIxMDEyMDAw
# MFoXDTI2MDIxMDEyMDAwMFowczELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lD
# ZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEyMDAGA1UEAxMpRGln
# aUNlcnQgSGlnaCBBc3N1cmFuY2UgQ29kZSBTaWduaW5nIENBLTEwggEiMA0GCSqG
# SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDF+SPmlCfEgBSkgDJfQKONb3DA5TZxcTp1
# pKoakpSJXqwjcctOZ31BP6rjS7d7vp3BqDiPaS86JOl3WRLHZgRDwg0mgolAGfIs
# 6udM53wFGrj/iAlPJjfvOqT6ImyIyUobYfKuEF5vvNF5m1kYYOXuKbUDKqTO8YMZ
# T2kFcygJ+yIQkyKgkBkaTDHy0yvYhEOvPGP/mNsg0gkrVMHq/WqD5xCjEnH11tfh
# EnrV4FZazuoBW2hlW8E/WFIzqTVhTiLLgco2oxLLBtbPG00YfrmSuRLPQCbYmjaF
# sxWqR5OEawe7vNWz3iUAEYkAaMEpPOo+Le5Qq9ccMAZ4PKUQI2eRAgMBAAGjggNU
# MIIDUDAOBgNVHQ8BAf8EBAMCAQYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwggHDBgNV
# HSAEggG6MIIBtjCCAbIGCGCGSAGG/WwDMIIBpDA6BggrBgEFBQcCARYuaHR0cDov
# L3d3dy5kaWdpY2VydC5jb20vc3NsLWNwcy1yZXBvc2l0b3J5Lmh0bTCCAWQGCCsG
# AQUFBwICMIIBVh6CAVIAQQBuAHkAIAB1AHMAZQAgAG8AZgAgAHQAaABpAHMAIABD
# AGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAG8AbgBzAHQAaQB0AHUAdABlAHMAIABh
# AGMAYwBlAHAAdABhAG4AYwBlACAAbwBmACAAdABoAGUAIABEAGkAZwBpAEMAZQBy
# AHQAIABFAFYAIABDAFAAUwAgAGEAbgBkACAAdABoAGUAIABSAGUAbAB5AGkAbgBn
# ACAAUABhAHIAdAB5ACAAQQBnAHIAZQBlAG0AZQBuAHQAIAB3AGgAaQBjAGgAIABs
# AGkAbQBpAHQAIABsAGkAYQBiAGkAbABpAHQAeQAgAGEAbgBkACAAYQByAGUAIABp
# AG4AYwBvAHIAcABvAHIAYQB0AGUAZAAgAGgAZQByAGUAaQBuACAAYgB5ACAAcgBl
# AGYAZQByAGUAbgBjAGUALjAPBgNVHRMBAf8EBTADAQH/MH8GCCsGAQUFBwEBBHMw
# cTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEkGCCsGAQUF
# BzAChj1odHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRIaWdoQXNz
# dXJhbmNlRVZSb290Q0EuY3J0MIGPBgNVHR8EgYcwgYQwQKA+oDyGOmh0dHA6Ly9j
# cmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEhpZ2hBc3N1cmFuY2VFVlJvb3RDQS5j
# cmwwQKA+oDyGOmh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEhpZ2hB
# c3N1cmFuY2VFVlJvb3RDQS5jcmwwHQYDVR0OBBYEFJdIA+sVCGu5slgjzJQu8cZl
# 0mSOMB8GA1UdIwQYMBaAFLE+w2kD+L9HAdSYJhoIAu9jZCvDMA0GCSqGSIb3DQEB
# BQUAA4IBAQCCBemFr6dMv6/OPbLqYLFo3mfC0ssm4MMvm7VrDlOQhfab4DUC//pp
# g6q0dDIUPC4QTCibCq0ICfnzhBGTj8tgQFbpdy9psoOZVatHJJbLf0uwELSXv8Sl
# mQb+juwUUB5eV5fLR7k02fw6ov9QKcIKYgTu3pY6b6DChQ9v/AjkMnvThK5pYAlG
# Jpzo8P//htnICTpmw6c2jxhP6LGWki5OvgunM5CuvG5P8X6NtEYOZPlZBiIhZABL
# 4noIA+e8iZCeQk8BwLYWf3XqRrKlVC+Mk80RNjRqKFfMlD/pfMgYAwMEfkPa+Zeh
# WUfaEqrgbTgAXTUrxSKGywbKvHpNPSZGMYIEODCCBDQCAQEwgYcwczELMAkGA1UE
# BhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2lj
# ZXJ0LmNvbTEyMDAGA1UEAxMpRGlnaUNlcnQgSGlnaCBBc3N1cmFuY2UgQ29kZSBT
# aWduaW5nIENBLTECEA5pBpjCFMh6tbYEuRY80ZAwCQYFKw4DAhoFAKB4MBgGCisG
# AQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFFeY
# GJIYFx1km74q1US2xm4ljguVMA0GCSqGSIb3DQEBAQUABIIBANpwXpEHmJFh7pc3
# tBL0vOJ1BOi8MO+mFkHJNGmfk0v8z1r3STYrhn1I2DhMBPff791QI1Pu2kXS2f4B
# TBSZhK25fnEUHg0QYKQzTVuMm/GHok86KJBKDCWIb93QU4H/Hoarx1B30ypTWtMq
# vboGCOZjiOA74V8PFUjv2IUqey/pW0vUwmE7Icgc9r6D/emjcyUQg7Rx8YdWK1Md
# BAR/JQnuuUklDau+DEGiqZNqIOI7zQwzqp/9EwwMAYdOnk2od21JGb7tHw+lvYBx
# L8xlhCcBIhk+/lsRqx+MqCjfEzVEZRdbCUXKHdWfiOftCFPJIdXxdfoBIujZKLNG
# yBiESMyhggILMIICBwYJKoZIhvcNAQkGMYIB+DCCAfQCAQEwcjBeMQswCQYDVQQG
# EwJVUzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xMDAuBgNVBAMTJ1N5
# bWFudGVjIFRpbWUgU3RhbXBpbmcgU2VydmljZXMgQ0EgLSBHMgIQDs/0OMj+vzVu
# BNhqmBsaUDAJBgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAc
# BgkqhkiG9w0BCQUxDxcNMTMwMzAyMjEzNzE1WjAjBgkqhkiG9w0BCQQxFgQU9p7o
# KCLLdWxcTFn86+JqIb5V+0QwDQYJKoZIhvcNAQEBBQAEggEASeCrOvaftU83NtWo
# 6QtnVWSqahW+rn6CIxwlv/qGNiUPET3NFPmk41+Yk2tzbLrDj/VZK67KSu5pDsNc
# CwriVhyV79iKwgrdv8vdIsPy2lYBsbE6z0P+2bYiDClYzfh+3tWpFz/9EITNFgVa
# 6eO4J5PJ86ThVurkHpZU4rkzrxy/tDjMI/cGTW8FLgopUN6u/OP09AzSoBoXM7CF
# nBioer7W9ROOZiBa3dhXHcL66y57mqW6ClUzdXAWFF/E3soKGa5zPIWeZBsZgA0h
# idnzAAYqJ0Y1CZLPQMq16YNEgKya9S1fo/3hAhRpVeCC+PygFRjaBCShF9R64YKX
# DMQ9pg==
# SIG # End signature block
