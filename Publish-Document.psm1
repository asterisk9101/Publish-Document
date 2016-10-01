[System.Collections.Stack]$circle   # �O���t�̏z�`�F�b�N�p�X�^�b�N
[System.Collections.Hashtable]$Dependencies # �ˑ��֌W��\���n�b�V���e�[�u��
[System.Collections.Hashtable]$Graph    # �ˑ��֌W�����������O���t�̃m�[�h
[System.Collections.Hashtable]$Exports  # �^�X�N�Ԃ̃f�[�^�����p�R���e�i
[System.Management.Automation.PSCustomObject]$Opts  # �I�v�V������͌��ʂ��i�[����R���e�i

function Get-Graph {
    param($Target)

    # �z�O���t�̓G���[�Ƃ���
    if ($script:circle.Contains($Target)) { throw "circle graph: $Target" }
    $circle.Push($Target) > $null # �z�`�F�b�N

    $root = $script:Dependencies[$Target]
    if ($root -eq $null) {
        # Publish �t�@�C���Ƀ^�[�Q�b�g�������ꍇ
        # $Target �̓t�@�C�����ł���Ɣ��f���āA�V�����m�[�h�����
        $root = New-Object System.Collections.Hashtable
        $root.Add("name", $Target) > $null
    } else {
        # Publish �t�@�C���Ƀ^�[�Q�b�g������ꍇ
        # �^�[�Q�b�g�� Graph �m�[�h�ɒu������
        $root.from | ? { $_ } |
        % BEGIN {
            $children = New-Object System.Collections.ArrayList
        } PROCESS {
            $children.Add((Get-Graph($_))) > $null
        } END {
            $root.from = $children
        }
    }
    $script:circle.Pop() > $null # �z�`�F�b�N
    return $root
}
function Compare-Datetime {
    param($node)
    $date1 = Get-ItemPropertyValue -Name LastWriteTime -Path $node["name"]
    $date2 = $node["from"] |
        ? { $_ } |
        ? { Test-Path $_ } |
        % { Get-ItemPropertyValue -Name LastWriteTime -Path $_ } |
        sort |
        select -last 1

    if ($from -eq $Null) {
        return $False
    } else {
        return $date1 -lt $date2
    }
}
function Invoke-Executor {
     param($cmd)
     if ($cmd.GetType().Name -eq "String") {
         Write-Host (cmd /c "$cmd")
     } else {
         $cmd.keys |
         % {
             Write-Host (& $_ -Exports $Exports -Arguments $cmd[$_])
         }
     }
     return $?
}
function Invoke-Task {
    param($node)
    # ���s�ς݂̃^�X�N�̓X�L�b�v����
    if ($node["state"] -eq "executed") { return }

    if ((Test-Path $node["name"])) {
        # �^�[�Q�b�g�ƂȂ�t�@�C�������݂���Ƃ��A�t�@�C���̍X�V�������r����B

        # �^�[�Q�b�g�̍X�V�������ˑ���̍X�V�������Â��Ƃ��A
        # �ˑ���̃^�X�N�����s����
        Write-Output 1 |
        ? { Compare-Datetime($node) } | 
        % { $node["from"] } |
        ? { $_ } |
        % {
            Invoke-Task($_) > $null
        }
    } else {
        # �^�[�Q�b�g�ƂȂ�t�@�C�������݂��Ȃ��Ƃ��A�ˑ���^�X�N��S�Ď��s����
        $node["from"] | ? { $_ } | 
        % {
            Invoke-Task($_) > $null
        }
    }

    # �^�X�N�̎��s�i���s���ʂ���ł����s�Ȃ�A�^�X�N�̃X�e�[�^�X�͎��s�j
    $result = $node["exec"] | ? { $_ } | % { Invoke-Executor($_) }
    $result = $result | ? { -not $_ } | select -first 1
    if ($result) { $node["result"] = $result } else { $node["result"] = "success" }
    
    # �^�X�N�̃X�e�[�^�X�����s�ς݂ɕύX
    $node["state"] = "executed"

    return $node["result"]
}
function Test-Task {
    param($graph)
    if ($graph.ContainsKey("from")) {
        $graph["from"] | % {
            Test-Task($_)
        }
    }
    $graph.exec | ? { $_ -ne $null } | % {
        if ($_.GetType().Name -eq "String") {
            Write-Output "$_"
        } elseif ($_.GetType().Name -eq "Hashtable") {
            $hash = $_
            $hash.keys | % {
                Write-Output "$_"
                Write-Output $hash[$_]
            }
        } else {
            throw "TypeError"
        }
    }
}
function Show-TaskList {
    param($graph)
    $graph.keys | % {
        $obj = $graph[$_]
        if (-not $obj.hidden) {
            New-Object PSObject |
            Add-Member NoteProperty Name $_ -PassThru |
            Add-Member NoteProperty Description $obj.desc -PassThru 
        }
    }
}
function Publish-Document {
    param(
        $Target = "default",
        $File = ".\Publish",
        [switch]$Test = $false,
        [switch]$List = $false
    )

    # ���W���[���S�̂ŋ��p����ϐ��̏�����
    $script:circle = New-Object System.Collections.Stack

    $script:Opts = New-Object psobject |
        Add-Member -PassThru NoteProperty Test $Test |
        Add-Member -PassThru NoteProperty List $List

    $script:Exports = New-Object System.Collections.Hashtable

    # ���̕ӂ��珈���J�n
    $script:Dependencies = Import-YAML (Resolve-Path $File)

    if ($Opts["List"]) {
        Show-TaskList $script:Dependencies
        return # return
    }

    # �S�Ẵm�[�h�ɋ��ʂ̑�����t�^����
    $script:Dependencies.keys |
    % {
        $script:Dependencies[$_].Add("name", $_) # �^�[�Q�b�g�̖��O�������͐�������t�@�C���̖��O
        $script:Dependencies[$_].Add("state", "wait") # �m�[�h�̏��
        $script:Dependencies[$_].Add("result", "") # ���s����
    }
    $script:Graph = Get-Graph($Target)

    if ($Opts["Test"]) {
        Test-Task $script:Graph
        return # return
    }
    
    Invoke-Task $script:Graph # ���ʂ��o�͂���
}

# ���W���[���̃��[�h
$modules = New-Object PSObject
$moduleRoot = Split-Path -Path $MyInvocation.MyCommand.Path
"$moduleRoot\Modules\*.psm1" |
? { Test-Path -PathType Container -Path $_ } |
Resolve-Path |
? { -not $_.ProviderPath.ToLower().Contains(".tests.")} |
% { Import-Module -Force $_.ProviderPath }

Export-ModuleMember -Function Publish-Document
