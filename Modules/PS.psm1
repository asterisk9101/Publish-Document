function PS {
    param($Exports = $null, $Arguments = $null)
    Write-Host "PS Module!"
    $Arguments.keys | % {
        Write-Output "$_ : $($Arguments[$_])"
    }
}
Export-ModuleMember -Function PS
