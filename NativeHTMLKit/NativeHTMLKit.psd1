@{
    RootModule = 'NativeHTMLKit.psm1'
    ModuleVersion = '0.1.2'
    GUID = 'e847e31c-4103-4872-a815-c1ec197a13fc'
    Author = 'NativeHTMLKit contributors'
    CompanyName = 'NativeHTMLKit'
    Copyright = '(c) 2026 NativeHTMLKit contributors. MIT license.'
    Description = 'Native desktop HTML/CSS applications with PowerShell on Linux and Windows. No browser, JavaScript or web server. Quick start: Install-Module NativeHTMLKit -Scope CurrentUser. Tutorials and examples: https://github.com/nativehtmlkit/nativehtmlkit . Full SDK API: https://github.com/nativehtmlkit/nativehtmlkit-powershell .'
    PowerShellVersion = '5.1'
    DotNetFrameworkVersion = '4.7.2'
    CompatiblePSEditions = @('Desktop','Core')
    NestedModules = @()
    RequiredAssemblies = @()
    FunctionsToExport = @(
        'Connect-NativeHTMLKit', 'Close-NativeHTMLKit', 'Wait-NativeHTMLKit', 'Invoke-NativeHTMLKitRpc',
        'Send-NativeHTMLKitNotification', 'Start-NativeHTMLKitRpc', 'Wait-NativeHTMLKitRpc', 'Stop-NativeHTMLKitRpc',
        'New-NativeHTMLKitWindow', 'Set-NativeHTMLKitWindow', 'Get-NativeHTMLKitWindow', 'Get-NativeHTMLKitWindowList',
        'Close-NativeHTMLKitWindow', 'Request-NativeHTMLKitAttention', 'Set-NativeHTMLKitBeforeClose', 'Set-NativeHTMLKitBeforeQuit',
        'Set-NativeHTMLKitReady', 'Request-NativeHTMLKitQuit', 'Register-NativeHTMLKitNotification', 'Open-NativeHTMLKitHtml',
        'Open-NativeHTMLKitFile', 'Remove-NativeHTMLKitDocument', 'Register-NativeHTMLKitDocumentEvent', 'Unregister-NativeHTMLKitDocumentEvent',
        'Invoke-NativeHTMLKitDocumentCommand', 'Invoke-NativeHTMLKitBatch', 'Get-NativeHTMLKitDocumentText', 'Set-NativeHTMLKitDocumentText',
        'Get-NativeHTMLKitValue', 'Set-NativeHTMLKitDocumentValue', 'Get-NativeHTMLKitChecked', 'Set-NativeHTMLKitChecked',
        'Set-NativeHTMLKitDocumentAttribute', 'Set-NativeHTMLKitClass', 'Set-NativeHTMLKitDocumentHtml', 'Remove-NativeHTMLKitElement',
        'Find-NativeHTMLKitElement', 'Add-NativeHTMLKitStylesheet', 'Get-NativeHTMLKitStylesheets', 'Set-NativeHTMLKitStylesheet',
        'Get-NativeHTMLKitComputedStyle', 'Get-NativeHTMLKitEnvironment', 'Set-NativeHTMLKitEnvironment', 'Get-NativeHTMLKitScroll',
        'Set-NativeHTMLKitScroll', 'Get-NativeHTMLKitFocusedElement', 'Set-NativeHTMLKitFocus', 'Get-NativeHTMLKitSelection',
        'Set-NativeHTMLKitSelection', 'Invoke-NativeHTMLKitEditCommand', 'Get-NativeHTMLKitFormData', 'Submit-NativeHTMLKitForm',
        'Reset-NativeHTMLKitForm', 'Get-NativeHTMLKitSelectOptions', 'Set-NativeHTMLKitSelectedValues', 'Show-NativeHTMLKitPopover',
        'Show-NativeHTMLKitHtmlDialog', 'Set-NativeHTMLKitPreventDefault', 'Get-NativeHTMLKitDiagnostics', 'Get-NativeHTMLKitResourceStats',
        'Clear-NativeHTMLKitUnusedResources', 'Register-NativeHTMLKitResources', 'Unregister-NativeHTMLKitResources', 'Get-NativeHTMLKitNode',
        'Get-NativeHTMLKitNodes', 'Get-NativeHTMLKitNodeInfo', 'Get-NativeHTMLKitNodeChildren', 'Invoke-NativeHTMLKitNodeBatch',
        'Invoke-NativeHTMLKitNodeOperation', 'Get-NativeHTMLKitCapabilities', 'Get-NativeHTMLKitPreferences', 'Get-NativeHTMLKitClipboard',
        'Set-NativeHTMLKitClipboard', 'Open-NativeHTMLKitExternal', 'Show-NativeHTMLKitFileDialog', 'New-NativeHTMLKitLiveBitmap',
        'Send-NativeHTMLKitLiveBitmap', 'Remove-NativeHTMLKitLiveBitmap', 'Get-NativeHTMLKitHostPath', 'Start-NativeHTMLKitHost', 'Start-NativeHTMLKitScript',
        'New-NativeHTMLKitProject', 'Install-NativeHTMLKitSkill', 'Start-NativeHTMLKitTask', 'Receive-NativeHTMLKitTask', 'Stop-NativeHTMLKitTask', 'Export-NativeHTMLKitSupportBundle', 'Get-NativeHTMLKitDiagnosticReport'
    )
    CmdletsToExport = @()
    AliasesToExport = @(
        'Add-NHKStylesheet', 'Clear-NHKUnusedResources', 'Close-NHK', 'Close-NHKWindow', 'Connect-NHK', 'Export-NHKSupportBundle',
        'Find-NHKElement', 'Get-NHKCapabilities', 'Get-NHKChecked', 'Get-NHKClipboard', 'Get-NHKComputedStyle', 'Get-NHKDiagnosticReport',
        'Get-NHKDiagnostics', 'Get-NHKDocumentText', 'Get-NHKEnvironment', 'Get-NHKFocusedElement', 'Get-NHKFormData', 'Get-NHKHostPath',
        'Get-NHKNode', 'Get-NHKNodeChildren', 'Get-NHKNodeInfo', 'Get-NHKNodes', 'Get-NHKPreferences', 'Get-NHKResourceStats',
        'Get-NHKScroll', 'Get-NHKSelectOptions', 'Get-NHKSelection', 'Get-NHKStylesheets', 'Get-NHKValue', 'Get-NHKWindow',
        'Get-NHKWindowList', 'Install-NHKSkill', 'Invoke-NHKBatch', 'Invoke-NHKDocumentCommand', 'Invoke-NHKEditCommand', 'Invoke-NHKNodeBatch',
        'Invoke-NHKNodeOperation', 'Invoke-NHKRpc', 'New-NHKLiveBitmap', 'New-NHKProject', 'New-NHKWindow', 'Open-NHKExternal',
        'Open-NHKFile', 'Open-NHKHtml', 'Receive-NHKTask', 'Register-NHKDocumentEvent', 'Register-NHKNotification', 'Register-NHKResources',
        'Remove-NHKDocument', 'Remove-NHKElement', 'Remove-NHKLiveBitmap', 'Request-NHKAttention', 'Request-NHKQuit', 'Reset-NHKForm',
        'Send-NHKLiveBitmap', 'Send-NHKNotification', 'Set-NHKBeforeClose', 'Set-NHKBeforeQuit', 'Set-NHKChecked', 'Set-NHKClass',
        'Set-NHKClipboard', 'Set-NHKDocumentAttribute', 'Set-NHKDocumentHtml', 'Set-NHKDocumentText', 'Set-NHKDocumentValue', 'Set-NHKEnvironment',
        'Set-NHKFocus', 'Set-NHKPreventDefault', 'Set-NHKReady', 'Set-NHKScroll', 'Set-NHKSelectedValues', 'Set-NHKSelection',
        'Set-NHKStylesheet', 'Set-NHKWindow', 'Show-NHKFileDialog', 'Show-NHKHtmlDialog', 'Show-NHKPopover', 'Start-NHKHost',
        'Start-NHKRpc', 'Start-NHKScript', 'Start-NHKTask', 'Stop-NHKTask', 'Stop-NHKRpc', 'Submit-NHKForm',
        'Unregister-NHKDocumentEvent', 'Unregister-NHKResources', 'Wait-NHK', 'Wait-NHKRpc'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('UI','GUI','HTML','CSS','Native','Desktop','Linux','Windows','Wayland','PowerShell','Rust','PSEdition_Desktop','PSEdition_Core')
            LicenseUri = 'https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/LICENSE'
            ProjectUri = 'https://github.com/nativehtmlkit/nativehtmlkit-powershell'
            ReleaseNotes = '0.1.2: documentation and marketplace onboarding refresh. Rust Core 1.0.3 host and public wire v1; no new SDK feature claims. See documentation and verified release artifacts for qualifications.'
        }
    }
}
